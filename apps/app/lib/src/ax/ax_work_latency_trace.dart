import 'package:flutter/foundation.dart';

/// Web-side stages of the Phase 1 latency trace (see
/// `docs/specifications/LATENCY_TRACE_V1.md`). T1 is `web_submitted`, T12 is
/// `web_received`. The rest are auxiliary marks that split the Web-observed
/// time into submit round trip and realtime delivery.
const String axTraceWebSubmitted = 'web_submitted';
const String axTraceWebAccepted = 'web_submit_response';
const String axTraceWebCreatedEvent = 'web_created_event';
const String axTraceWebStartedEvent = 'web_started_event';
const String axTraceWebReceived = 'web_received';

/// Bounded, privacy-safe record of one Work request as seen by the Web client.
/// Only identifiers, status words and millisecond durations are retained; no
/// prompt text, attachments, or idempotency keys.
final class AxWorkLatencyRecord {
  AxWorkLatencyRecord._(this._timer, this.submittedAtUtc);

  final Stopwatch _timer;

  /// Wall-clock time of T1. Used for ordering/joining only; every duration
  /// below comes from a monotonic stopwatch on this device.
  final DateTime submittedAtUtc;

  String? requestId;
  String? terminalStatus;
  final Map<String, int> marksMs = {};

  void _mark(String stage) =>
      marksMs.putIfAbsent(stage, () => _timer.elapsedMilliseconds);

  Map<String, Object?> toJson() => {
        'requestId': requestId,
        'submittedAt': submittedAtUtc.toIso8601String(),
        'terminalStatus': terminalStatus,
        'marksMs': Map<String, int>.of(marksMs),
      };
}

/// Records T1 (submit) and T12 (final update received) per Work request.
/// All methods are synchronous and never throw, so tracing cannot delay or
/// fail a submission or an incoming realtime event.
class AxWorkLatencyTrace {
  AxWorkLatencyTrace({this.maxRecords = 128, this.sink});

  static final AxWorkLatencyTrace instance = AxWorkLatencyTrace(
    sink: (line) => debugPrint(line),
  );

  final int maxRecords;

  /// Receives one `[syntila.latency] {json}` line per completed request.
  final void Function(String line)? sink;

  final Map<String, AxWorkLatencyRecord> _bySubmission = {};
  final Map<String, AxWorkLatencyRecord> _byRequest = {};
  final List<AxWorkLatencyRecord> _completed = [];

  List<Map<String, Object?>> get completed => [
        for (final record in _completed) record.toJson(),
      ];

  /// T1. [submissionId] is the Idempotency-Key of the submit request.
  void submitted(String submissionId) {
    try {
      _evict(_bySubmission);
      _bySubmission[submissionId] =
          AxWorkLatencyRecord._(Stopwatch()..start(), DateTime.now().toUtc())
            .._mark(axTraceWebSubmitted);
    } on Object {
      // Telemetry boundary.
    }
  }

  /// The Cloud accepted the submit and returned [requestId].
  void accepted(String submissionId, String requestId) {
    try {
      final record = _bySubmission[submissionId];
      if (record == null) return;
      record
        ..requestId = requestId
        .._mark(axTraceWebAccepted);
      _evict(_byRequest);
      _byRequest[requestId] = record;
    } on Object {
      // Telemetry boundary.
    }
  }

  /// The submit failed; the trace is dropped.
  void failed(String submissionId) {
    _bySubmission.remove(submissionId);
  }

  /// A realtime `work_request.*` event arrived for [requestId]. Called after
  /// the event passed de-duplication, before the cache is patched, so the mark
  /// reflects network delivery and not UI work.
  void realtimeEvent(String type, String requestId) {
    try {
      final record = _byRequest[requestId];
      if (record == null) return;
      switch (type) {
        case 'work_request.created':
          record._mark(axTraceWebCreatedEvent);
        case 'work_request.started':
          record._mark(axTraceWebStartedEvent);
        case 'work_request.completed':
        case 'work_request.failed':
        case 'work_request.cancelled':
          if (record.marksMs.containsKey(axTraceWebReceived)) return;
          record
            ..terminalStatus = type.substring('work_request.'.length)
            .._mark(axTraceWebReceived);
          _byRequest.remove(requestId);
          _complete(record);
      }
    } on Object {
      // Telemetry boundary.
    }
  }

  void _complete(AxWorkLatencyRecord record) {
    _completed.add(record);
    while (_completed.length > maxRecords) {
      _completed.removeAt(0);
    }
    final emit = sink;
    if (emit != null) emit('[syntila.latency] ${_encode(record.toJson())}');
  }

  void _evict(Map<String, AxWorkLatencyRecord> map) {
    while (map.length >= maxRecords) {
      map.remove(map.keys.first);
    }
  }

  static String _encode(Map<String, Object?> json) {
    final marks = json['marksMs'] as Map<String, int>;
    final buffer = StringBuffer('{')
      ..write('"requestId":"${json['requestId']}"')
      ..write(',"submittedAt":"${json['submittedAt']}"')
      ..write(',"terminalStatus":"${json['terminalStatus']}"')
      ..write(',"marksMs":{')
      ..write(marks.entries.map((e) => '"${e.key}":${e.value}').join(','))
      ..write('}}');
    return buffer.toString();
  }
}

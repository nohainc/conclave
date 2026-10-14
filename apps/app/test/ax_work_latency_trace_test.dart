import 'package:conclave_app/src/ax/ax_work_latency_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('records T1 through T12 for a completed request', () {
    final lines = <String>[];
    final trace = AxWorkLatencyTrace(sink: lines.add);
    trace.submitted('key-1');
    trace.accepted('key-1', 'req-1');
    trace.realtimeEvent('work_request.created', 'req-1');
    trace.realtimeEvent('work_request.started', 'req-1');
    trace.realtimeEvent('work_request.completed', 'req-1');

    final done = trace.completed.single;
    expect(done['requestId'], 'req-1');
    expect(done['terminalStatus'], 'completed');
    final marks = done['marksMs'] as Map<String, int>;
    expect(
        marks.keys,
        containsAll([
          axTraceWebSubmitted,
          axTraceWebAccepted,
          axTraceWebCreatedEvent,
          axTraceWebStartedEvent,
          axTraceWebReceived,
        ]));
    expect(marks[axTraceWebReceived]!,
        greaterThanOrEqualTo(marks[axTraceWebSubmitted]!));
    expect(lines.single, startsWith('[conclave.latency] {'));
    expect(lines.single, isNot(contains('key-1')));
  });

  test('ignores unknown requests, duplicates and failed submits', () {
    final trace = AxWorkLatencyTrace();
    trace.realtimeEvent('work_request.completed', 'unknown');
    trace.submitted('key-2');
    trace.failed('key-2');
    trace.accepted('key-2', 'req-2');
    trace.realtimeEvent('work_request.completed', 'req-2');
    expect(trace.completed, isEmpty);

    trace.submitted('key-3');
    trace.accepted('key-3', 'req-3');
    trace.realtimeEvent('work_request.failed', 'req-3');
    trace.realtimeEvent('work_request.failed', 'req-3');
    expect(trace.completed, hasLength(1));
    expect(trace.completed.single['terminalStatus'], 'failed');
  });

  test('keeps at most maxRecords completed records', () {
    final trace = AxWorkLatencyTrace(maxRecords: 3);
    for (var i = 0; i < 6; i++) {
      trace.submitted('k$i');
      trace.accepted('k$i', 'r$i');
      trace.realtimeEvent('work_request.completed', 'r$i');
    }
    expect(trace.completed.map((r) => r['requestId']), ['r3', 'r4', 'r5']);
  });
}

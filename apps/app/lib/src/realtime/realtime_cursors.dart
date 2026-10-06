import 'dart:convert';
import 'package:conclave_protocol/conclave_protocol.dart';

/// Transport cursors are independent of navigation and execution ownership.
class RealtimeCursors {
  final _legacy = <String, int>{};
  final _streams = <String, int>{};

  void record(Map<String, dynamic> frame) {
    final sequence = frame['sequence'] ?? frame['nextSequence'];
    if (sequence is! int || sequence < 0) return;
    final stream = frame['stream'];
    if (stream is Map &&
        realtimeStreamKinds.contains(stream['kind']) &&
        stream['id'] is String &&
        (stream['id'] as String).isNotEmpty) {
      final key = jsonEncode([stream['kind'], stream['id']]);
      _streams[key] =
          sequence > (_streams[key] ?? -1) ? sequence : _streams[key]!;
      if (stream['kind'] == 'execution_workspace') {
        _recordLegacy(stream['id'] as String, sequence);
      }
    } else if (frame['workspaceId'] is String) {
      _recordLegacy(frame['workspaceId'] as String, sequence);
    }
  }

  void _recordLegacy(String id, int sequence) {
    _legacy[id] = sequence > (_legacy[id] ?? -1) ? sequence : _legacy[id]!;
    final key = jsonEncode(['execution_workspace', id]);
    _streams[key] = _legacy[id]!;
  }

  Map<String, dynamic> hello() => {
        'type': 'realtime.hello',
        if (_legacy.isNotEmpty)
          'lastDurableSequences': Map<String, int>.of(_legacy),
        if (_streams.isNotEmpty)
          'lastDurableStreamSequences': Map<String, int>.of(_streams),
      };
}

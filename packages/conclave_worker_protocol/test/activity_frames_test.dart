import 'dart:convert';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips an activity without a percentage', () {
    final frame = WorkerActivity(
      requestId: 'request-1',
      assignmentId: 'assignment-1',
      executionId: 'execution-1',
      workerId: 'chatgpt',
      eventId: 'event-1',
      sequence: 1,
      timestamp: '2026-10-12T18:00:00Z',
      eventType: 'model.status',
      status: 'updated',
      title: 'Reading files',
      durationMs: 1200,
      toolId: 'tool-1',
      toolName: 'shell',
      details: const {'fileCount': 3, 'safe': true},
    );
    final decoded = decodeWorkerFrame(frame.encode()) as WorkerActivity;
    expect(decoded.percentage, isNull);
    expect(decoded.durationMs, 1200);
    expect(decoded.toolId, 'tool-1');
    expect(decoded.toolName, 'shell');
    expect(decoded.details, {'fileCount': 3, 'safe': true});
  });

  test('permits repeated activity identifiers and preserves sequence', () {
    WorkerActivity build(
            int sequence, String eventId, String eventType, String status) =>
        WorkerActivity(
          requestId: 'request-1',
          assignmentId: 'assignment-1',
          executionId: 'execution-1',
          workerId: 'gemini',
          eventId: eventId,
          sequence: sequence,
          timestamp: '2026-10-12T18:00:00Z',
          eventType: eventType,
          status: status,
          title: 'Tool',
          activityId: 'same-tool-id',
        );
    expect(
        jsonDecode(build(4, 'event-1', 'tool.started', 'running').encode())[
            'sequence'],
        4);
    expect(
        jsonDecode(build(5, 'event-2', 'tool.completed', 'completed').encode())[
            'sequence'],
        5);
  });

  test('rejects invalid event and detail values', () {
    final base = <String, Object?>{
      'type': 'activity',
      'requestId': 'request-1',
      'assignmentId': 'assignment-1',
      'executionId': 'execution-1',
      'workerId': 'chatgpt',
      'eventId': 'event-1',
      'sequence': 1,
      'timestamp': '2026-10-12T18:00:00Z',
      'eventType': 'tool.started',
      'status': 'running',
      'title': 'Running tool',
    };
    expect(() => WorkerActivity.fromJson({...base, 'sequence': 0}),
        throwsFormatException);
    expect(
        () =>
            WorkerActivity.fromJson({...base, 'eventType': 'provider.unknown'}),
        throwsFormatException);
    expect(
        () => WorkerActivity.fromJson({
              ...base,
              'details': {'unsafe': DateTime.now()}
            }),
        throwsFormatException);
    expect(() => WorkerActivity.fromJson({...base, 'unexpected': true}),
        throwsFormatException);
  });
}

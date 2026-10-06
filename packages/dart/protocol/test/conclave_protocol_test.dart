import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('maps unknown execution errors to the generic failure code', () {
    expect(canonicalExecutionErrorCode('unknown'), equals('execution_failed'));
    expect(executionErrorMessage('timeout'), isNotEmpty);
  });

  test('collaboration streams accept 1.1 without an execution Workspace', () {
    final event = RealtimeEvent.parse({
      'eventId': 'e',
      'type': 'discussion.created',
      'version': '1.1',
      'timestamp': '2026-10-06T00:00:00.000Z',
      'sequence': 1,
      'stream': {'kind': 'project', 'id': 'same'},
      'projectId': 'same',
      'workstreamId': 'W',
      'payload': {'entityId': 'm', 'workstreamId': 'W'},
    });
    expect(event.workspaceId, isNull);
    expect(event.streamKey, '["project","same"]');
    expect(RealtimeEvent.parse(event.encode()).payload['entityId'], 'm');
    expect(
        () => RealtimeEvent.parse({...event.toJson(), 'workspaceId': 'same'}),
        throwsA(isA<ProtocolException>()));
    expect(
        () => RealtimeEvent.parse({
              ...event.toJson(),
              'payload': {
                'entityId': 'm',
                'workstreamId': 'W',
                'text': 'history'
              }
            }),
        throwsA(isA<ProtocolException>()));
    expect(() => RealtimeEvent.parse({...event.toJson(), 'version': '1.0'}),
        throwsA(isA<ProtocolException>()));
  });
  test('legacy execution events infer an independent stream key', () {
    final event = RealtimeEvent.parse({
      'eventId': 'e',
      'type': 'step.running',
      'version': '1.0',
      'timestamp': '2026-10-06T00:00:00.000Z',
      'workspaceId': 'same',
      'sequence': 1,
      'payload': {'workRequestId': 'R', 'workstreamId': 'W', 'stepKind': 'test'}
    });
    expect(event.streamKey, '["execution_workspace","same"]');
  });
  test('round trips durable and ephemeral realtime events', () {
    final event = RealtimeEvent.parse({
      'eventId': 'event-1',
      'type': 'run.completed',
      'version': '1.0',
      'timestamp': '2026-09-23T10:00:00.000Z',
      'workspaceId': 'workspace-1',
      'sequence': 7,
      'payload': <String, Object?>{
        'entityId': 'run-1',
        'status': 'completed',
      },
    });
    expect(RealtimeEvent.parse(event.encode()).type, equals('run.completed'));
    expect(durableRealtimeEventTypes, contains('run.completed'));
    expect(ephemeralRealtimeEventTypes, contains('stream.delta'));
  });
}

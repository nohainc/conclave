import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('maps unknown execution errors to the generic failure code', () {
    expect(canonicalExecutionErrorCode('unknown'), equals('execution_failed'));
    expect(executionErrorMessage('timeout'), isNotEmpty);
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

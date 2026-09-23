import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'dart:io';

void main() {
  final message = <String, Object?>{
    'protocol': protocolName,
    'version': protocolVersion,
    'messageId': 'message-1',
    'goalId': 'goal-1',
    'runId': 'run-1',
    'workerId': 'worker-1',
    'createdAt': '2026-09-21T00:00:00Z',
    'messageType': 'TaskRequest',
    'payload': {'taskId': 'task-1'},
  };

  test('round trips the canonical envelope', () {
    final parsed = ProtocolEnvelope.parse(message).toJson();
    expect(parsed['protocol'], equals(message['protocol']));
    expect(parsed['version'], equals(message['version']));
    expect(parsed['payload'], equals(message['payload']));
    expect(DateTime.parse(parsed['createdAt']! as String),
        equals(DateTime.parse(message['createdAt']! as String)));
  });

  test('rejects missing correlation fields', () {
    final invalid = Map<String, Object?>.from(message)..remove('runId');
    expect(() => ProtocolEnvelope.parse(invalid),
        throwsA(isA<ProtocolException>()));
  });

  test('rejects unknown canonical message types', () {
    final invalid = Map<String, Object?>.from(message)
      ..['messageType'] = 'UnknownMessage';
    expect(
      () => ProtocolEnvelope.parse(invalid),
      throwsA(isA<ProtocolException>()),
    );
  });

  test('rejects incompatible major versions', () {
    expect(isCompatibleVersion('1.2.0', '1.3.0'), isTrue);
    expect(isCompatibleVersion('1.2.0', '2.0.0'), isFalse);
  });

  test('accepts a compatible minor version in the envelope', () {
    final compatible = Map<String, Object?>.from(message)..['version'] = '0.2';
    expect(ProtocolEnvelope.parse(compatible).version, equals('0.2'));

    final incompatible = Map<String, Object?>.from(message)
      ..['version'] = '1.0';
    expect(
      () => ProtocolEnvelope.parse(incompatible),
      throwsA(isA<ProtocolException>()),
    );
  });

  test('parses the canonical cross-language task fixture', () {
    final fixture = jsonDecode(
      File('../../protocol/fixtures/task-request.json').readAsStringSync(),
    );
    final parsed = ProtocolEnvelope.parse(fixture);
    expect(parsed.messageType, equals('TaskRequest'));
    expect(parsed.payload['taskId'], equals('task-1'));
  });

  test('validates a canonical runtime operation request', () {
    final runtime = ProtocolEnvelope.parse(jsonDecode(
      File('../../protocol/fixtures/runtime-operation-request.json')
          .readAsStringSync(),
    ));
    expect(RuntimeOperationRequest.parse(runtime).operation, equals('test'));
    expect(
      () => RuntimeOperationRequest.parse(ProtocolEnvelope.parse({
        ...runtime.toJson(),
        'payload': {...runtime.payload, 'operation': 'unknown'},
      })),
      throwsA(isA<ProtocolException>()),
    );
  });

  test('validates a generated Host assignment envelope', () {
    final parsed = HostProtocolMessage.parse({
      'protocol': hostProtocolName,
      'protocolVersion': hostProtocolVersion,
      'messageId': 'message-1',
      'timestamp': '2026-09-23T00:00:00Z',
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'hostId': 'host-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idempotency-1',
      'payload': <String, Object?>{
        'snapshot': <String, Object?>{
          'assignmentId': 'assignment-1',
          'workspaceId': 'workspace-1',
          'projectId': 'project-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'requestedByUserId': 'user-1',
          'hostId': 'host-1',
          'workerId': 'worker-1',
          'resolvedWorkerVersion': '1.0.0',
          'credentialProfileId': 'credential-1',
          'config': <String, Object?>{},
          'sessionPolicy': 'stateless',
          'permissions': <Object?>[],
          'contextRefs': <Object?>[],
          'timeoutMs': 1000,
          'idempotencyKey': 'idempotency-1',
        },
        'input': <String, Object?>{},
      },
    });
    expect(parsed.type, 'assignment.start');
  });

  test('rejects malformed or oversized Host messages', () {
    expect(
      () => HostProtocolMessage.parse({
        'protocol': hostProtocolName,
        'protocolVersion': hostProtocolVersion,
        'messageId': 'message-1',
        'timestamp': '2026-09-23T00:00:00Z',
        'type': 'assignment.start',
        'payload': <String, Object?>{},
      }),
      throwsA(isA<ProtocolException>()),
    );
    expect(
      () => HostProtocolMessage.parse({
        'protocol': hostProtocolName,
        'protocolVersion': hostProtocolVersion,
        'messageId': 'message-1',
        'timestamp': '2026-09-23T00:00:00Z',
        'type': 'host.heartbeat',
        'payload': {'padding': 'x' * hostProtocolMaxMessageSizeBytes},
      }),
      throwsA(isA<ProtocolException>()),
    );
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

  test('accepts unknown compatible events and rejects secrets or bad order', () {
    final base = <String, Object?>{
      'eventId': 'event-1',
      'type': 'future.new.fact',
      'version': '1.1',
      'timestamp': '2026-09-23T10:00:00.000Z',
      'workspaceId': 'workspace-1',
      'sequence': 0,
      'payload': <String, Object?>{},
    };
    expect(RealtimeEvent.parse(base).type, equals('future.new.fact'));
    expect(
      () => RealtimeEvent.parse({...base, 'sequence': -1}),
      throwsA(isA<ProtocolException>()),
    );
    expect(
      () => RealtimeEvent.parse({
        ...base,
        'payload': {'rawApiKey': 'secret'},
      }),
      throwsA(isA<ProtocolException>()),
    );
  });
}

import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:test/test.dart';

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
    expect(() => ProtocolEnvelope.parse(invalid), throwsA(isA<ProtocolException>()));
  });

  test('rejects incompatible major versions', () {
    expect(isCompatibleVersion('1.2.0', '1.3.0'), isTrue);
    expect(isCompatibleVersion('1.2.0', '2.0.0'), isFalse);
  });

  test('accepts a compatible minor version in the envelope', () {
    final compatible = Map<String, Object?>.from(message)
      ..['version'] = '0.2';
    expect(ProtocolEnvelope.parse(compatible).version, equals('0.2'));

    final incompatible = Map<String, Object?>.from(message)
      ..['version'] = '1.0';
    expect(
      () => ProtocolEnvelope.parse(incompatible),
      throwsA(isA<ProtocolException>()),
    );
  });
}

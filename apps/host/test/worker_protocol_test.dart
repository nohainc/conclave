import 'package:conclave_host/worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('accepts a JSON-RPC result frame', () {
    final response = WorkerRpcResponse.parse({
      'jsonrpc': '2.0',
      'id': 'request-1',
      'result': {'status': 'healthy'},
    });
    expect(response.result?['status'], 'healthy');
  });

  test('rejects malformed and ambiguous response frames', () {
    expect(
      () =>
          WorkerRpcResponse.parse({'jsonrpc': '1.0', 'id': '1', 'result': {}}),
      throwsA(isA<WorkerProtocolViolation>()),
    );
    expect(
      () => WorkerRpcResponse.parse({
        'jsonrpc': '2.0',
        'id': '1',
        'result': {},
        'error': {},
      }),
      throwsA(isA<WorkerProtocolViolation>()),
    );
  });

  test('accepts protocol notifications and rejects unknown events', () {
    final notification = WorkerRpcNotification.parse({
      'jsonrpc': '2.0',
      'method': 'progress',
      'params': {
        'assignmentId': 'assignment-1',
        'percentage': 25,
        'timestamp': '2026-09-23T00:00:00Z',
      },
    });
    expect(notification.method, 'progress');
    expect(
      WorkerRpcNotification.parse({
        'jsonrpc': '2.0',
        'method': 'output_delta',
        'params': {
          'assignmentId': 'assignment-1',
          'delta': 'partial output',
          'timestamp': '2026-09-23T00:00:00Z',
        },
      }).method,
      'output_delta',
    );
    expect(
      () => WorkerRpcNotification.parse({
        'jsonrpc': '2.0',
        'method': 'output_delta',
        'params': {
          'assignmentId': 'assignment-1',
          'delta': 'x' * 8193,
          'timestamp': '2026-09-23T00:00:00Z',
        },
      }),
      throwsA(isA<WorkerProtocolViolation>()),
    );
    expect(
      () => WorkerRpcNotification.parse({
        'jsonrpc': '2.0',
        'method': 'unknown',
      }),
      throwsA(isA<WorkerProtocolViolation>()),
    );
  });

  test('requires complete worker identity during initialize', () {
    final identity = WorkerIdentity.parse({
      'workerId': 'conclave.echo',
      'version': '1.0.0',
      'protocolVersion': '4.0',
      'runtimeLanguage': 'dart',
      'capabilities': ['deterministic_echo'],
    });
    expect(identity.capabilities, contains('deterministic_echo'));
    expect(
      () => WorkerIdentity.parse({
        'workerId': 'conclave.echo',
        'protocolVersion': '2.0',
      }),
      throwsA(isA<WorkerProtocolViolation>()),
    );
  });
}

import 'package:conclave_worker_protocol/worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round trips an execute request', () {
    final request = WorkerRpcRequest(
      id: 'request-1',
      method: 'execute',
      params: {'assignmentId': 'assignment-1'},
    );
    final parsed = parseWorkerRequest(request.toJson());
    expect(parsed.method, 'execute');
    expect(parsed.params['assignmentId'], 'assignment-1');
  });

  test('round trips a progress notification', () {
    final notif = WorkerRpcNotification(
      method: 'progress',
      params: {
        'assignmentId': 'assignment-1',
        'percentage': 50,
        'timestamp': '2026-09-23T00:00:00Z',
      },
    );
    final parsed = parseWorkerNotification(notif.toJson());
    expect(parsed.method, 'progress');
    expect(parsed.params['percentage'], 50);
  });

  test('validates streaming and tool notifications', () {
    for (final method in ['status', 'output_delta', 'tool.started']) {
      final params = <String, Object?>{
        'assignmentId': 'assignment-1',
        'timestamp': '2026-09-23T00:00:00Z',
        if (method == 'status') 'status': 'running',
        if (method == 'output_delta') 'delta': 'partial',
        if (method == 'tool.started') ...{
          'toolCallId': 'tool-1',
          'tool': 'shell',
        },
      };
      expect(
        parseWorkerNotification({
          'jsonrpc': '2.0',
          'method': method,
          'params': params,
        }).method,
        method,
      );
    }
    expect(
      () => parseWorkerNotification({
        'jsonrpc': '2.0',
        'method': 'output_delta',
        'params': {
          'assignmentId': 'assignment-1',
          'delta': 'x' * 8193,
          'timestamp': '2026-09-23T00:00:00Z',
        },
      }),
      throwsA(isA<WorkerRpcException>()),
    );
  });

  test('rejects methods outside the worker contract', () {
    expect(
      () => parseWorkerRequest({'jsonrpc': '2.0', 'id': '1', 'method': 'eval'}),
      throwsA(isA<WorkerRpcException>()),
    );
  });
}

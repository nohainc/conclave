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

  test('rejects methods outside the worker contract', () {
    expect(
      () => parseWorkerRequest({'jsonrpc': '2.0', 'id': '1', 'method': 'eval'}),
      throwsA(isA<WorkerRpcException>()),
    );
  });
}

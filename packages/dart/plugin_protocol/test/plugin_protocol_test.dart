import 'package:conclave_plugin_protocol/plugin_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round trips an execute request', () {
    final request = JsonRpcRequest(
      id: 'request-1',
      method: 'execute',
      params: {'assignmentId': 'assignment-1'},
    );
    final parsed = parseRequest(request.toJson());
    expect(parsed.method, 'execute');
    expect(parsed.params['assignmentId'], 'assignment-1');
  });

  test('round trips a progress notification', () {
    final notif = JsonRpcNotification(
      method: 'progress',
      params: {
        'assignmentId': 'assignment-1',
        'percentage': 50,
        'timestamp': '2026-09-23T00:00:00Z',
      },
    );
    final parsed = parseNotification(notif.toJson());
    expect(parsed.method, 'progress');
    expect(parsed.params['percentage'], 50);
  });

  test('rejects methods outside the worker contract', () {
    expect(
      () => parseRequest({'jsonrpc': '2.0', 'id': '1', 'method': 'eval'}),
      throwsA(isA<JsonRpcException>()),
    );
  });
}

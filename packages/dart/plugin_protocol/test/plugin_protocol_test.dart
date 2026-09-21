import 'package:conclave_plugin_protocol/plugin_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round trips a start assignment request', () {
    final request = JsonRpcRequest(
      id: 'request-1',
      method: 'start_assignment',
      params: {'assignmentId': 'assignment-1'},
    );
    final parsed = parseRequest(request.toJson());
    expect(parsed.method, 'start_assignment');
    expect(parsed.params['assignmentId'], 'assignment-1');
  });

  test('rejects methods outside the plugin contract', () {
    expect(
      () => parseRequest({'jsonrpc': '2.0', 'id': '1', 'method': 'eval'}),
      throwsA(isA<JsonRpcException>()),
    );
  });
}

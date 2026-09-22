import 'package:conclave_host/plugin_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('accepts a JSON-RPC result frame', () {
    final response = PluginRpcResponse.parse({
      'jsonrpc': '2.0',
      'id': 'request-1',
      'result': {'status': 'healthy'},
    });
    expect(response.result?['status'], 'healthy');
  });

  test('rejects malformed and ambiguous response frames', () {
    expect(
      () =>
          PluginRpcResponse.parse({'jsonrpc': '1.0', 'id': '1', 'result': {}}),
      throwsA(isA<PluginProtocolViolation>()),
    );
    expect(
      () => PluginRpcResponse.parse({
        'jsonrpc': '2.0',
        'id': '1',
        'result': {},
        'error': {},
      }),
      throwsA(isA<PluginProtocolViolation>()),
    );
  });

  test('accepts protocol notifications and rejects unknown events', () {
    final notification = PluginRpcNotification.parse({
      'jsonrpc': '2.0',
      'method': 'progress',
      'params': {'stage': 'running'},
    });
    expect(notification.method, 'progress');
    expect(
      () => PluginRpcNotification.parse({
        'jsonrpc': '2.0',
        'method': 'unknown',
      }),
      throwsA(isA<PluginProtocolViolation>()),
    );
  });

  test('requires complete plugin identity during initialize', () {
    final identity = PluginIdentity.parse({
      'pluginId': 'conclave.echo',
      'version': '1.0.0',
      'protocolVersion': '2.0',
      'runtimeLanguage': 'dart',
      'capabilities': ['deterministic_echo'],
    });
    expect(identity.capabilities, contains('deterministic_echo'));
    expect(
      () => PluginIdentity.parse({
        'pluginId': 'conclave.echo',
        'protocolVersion': '2.0',
      }),
      throwsA(isA<PluginProtocolViolation>()),
    );
  });
}

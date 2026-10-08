import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/realtime/realtime_client.dart';

void main() {
  for (final source in [
    'http://localhost:8787/api',
    'http://localhost:8787/api#',
    'http://localhost:8787/api#threads',
    'http://localhost:8787/api?filter=value#threads',
  ]) {
    test('local WebSocket endpoint removes fragment from $source', () {
      final endpoint = realtimeEndpointForApi(source);
      expect(endpoint.hasFragment, isFalse);
      expect(endpoint.toString(), isNot(contains('#')));
      expect(endpoint.scheme, 'ws');
      expect(endpoint.host, 'localhost');
      expect(endpoint.port, 8787);
      expect(endpoint.path, '/api/realtime');
      expect(endpoint.query, isEmpty);
    });
  }
  test('production and nested API bases preserve secure scheme and path', () {
    final endpoint =
        realtimeEndpointForApi('https://app.conclaveax.com/team/api#');
    expect(endpoint.hasFragment, isFalse);
    expect(endpoint.scheme, 'wss');
    expect(endpoint.host, 'app.conclaveax.com');
    expect(endpoint.path, '/team/api/realtime');
  });
  test('origin base and trailing slash resolve to the realtime route', () {
    for (final source in [
      'https://app.conclaveax.com',
      'https://app.conclaveax.com/'
    ]) {
      final endpoint = realtimeEndpointForApi(source);
      expect(endpoint.hasFragment, isFalse);
      expect(endpoint.path, '/api/realtime');
    }
  });
}

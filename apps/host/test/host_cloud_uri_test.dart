import 'dart:io';

import 'package:conclave_host/host.dart';
import 'package:conclave_host/secure_credentials.dart';
import 'package:test/test.dart';

class _NoCredentials implements SecureCredentialStore {
  @override
  String? readSync(String key) => null;

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

void main() {
  HostConfig configFor(String cloudUrl) => HostConfig.fromArgs(
        ['--cloud-url', cloudUrl, '--host-id', 'runtime-test'],
        credentialStore: _NoCredentials(),
      );

  test('HTTPS origin becomes WSS with a materialized default port', () {
    final uri = configFor('https://app.conclaveax.com/#discard-me').cloudUri!;

    expect(uri.scheme, 'wss');
    expect(uri.host, 'app.conclaveax.com');
    expect(uri.port, 443);
    expect(uri.path, '/api/workspace-gateway/connect');
    expect(uri.queryParameters['workspaceRuntimeId'], 'runtime-test');
    expect(uri.hasFragment, isFalse);
    expect(uri.toString(), isNot(contains(':0')));
  });

  test('explicit Cloud ports are preserved', () {
    final standardPort = configFor('https://cloud.example.test:443').cloudUri!;
    final uri = configFor('https://cloud.example.test:8443').cloudUri!;

    expect(standardPort.port, 443);
    expect(uri.scheme, 'wss');
    expect(uri.port, 8443);
  });

  test('Cloud URL secrets are never copied into the WebSocket query', () {
    final uri = configFor(
      'https://cloud.example.test?source=desktop&authToken=must-not-leak&api_key=also-secret',
    ).cloudUri!;

    expect(uri.queryParameters['source'], 'desktop');
    expect(uri.queryParameters['workspaceRuntimeId'], 'runtime-test');
    expect(uri.queryParameters.containsKey('authToken'), isFalse);
    expect(uri.queryParameters.containsKey('api_key'), isFalse);
  });

  test('local HTTP origin keeps its explicit development port', () {
    final uri = configFor('http://127.0.0.1:8787').cloudUri!;

    expect(uri.scheme, 'ws');
    expect(uri.host, '127.0.0.1');
    expect(uri.port, 8787);
    expect(uri.path, '/api/workspace-gateway/connect');
  });

  test('an explicit WSS endpoint gets a port without losing its path/query',
      () {
    final uri = configFor(
      'wss://cloud.example.test/api/workspace-gateway/connect?source=desktop#old',
    ).cloudUri!;

    expect(uri.scheme, 'wss');
    expect(uri.port, 443);
    expect(uri.path, '/api/workspace-gateway/connect');
    expect(uri.queryParameters['source'], 'desktop');
    expect(uri.queryParameters['workspaceRuntimeId'], 'runtime-test');
    expect(uri.hasFragment, isFalse);
  });

  test('configured WebSocket URI completes a local upgrade', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upgrade = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('ready');
      await socket.close();
    });
    addTearDown(() async {
      await upgrade.cancel();
      await server.close(force: true);
    });

    final uri =
        configFor('ws://${server.address.address}:${server.port}').cloudUri!;
    final socket = await WebSocket.connect(uri.toString());
    expect(await socket.first, 'ready');
  });
}

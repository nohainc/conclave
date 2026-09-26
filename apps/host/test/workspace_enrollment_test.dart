import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/host_configuration.dart';
import 'package:conclave_host/secure_credentials.dart';
import 'package:conclave_host/workspace_enrollment.dart';
import 'package:test/test.dart';

class _MemoryCredentials implements SecureCredentialStore {
  final Map<String, String> values = {};

  @override
  String? readSync(String key) => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test('pairs a desktop Workspace and persists only the runtime token locally',
      () async {
    final temp = await Directory.systemTemp.createTemp('conclave-pairing-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    final requestFuture = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/workspace-runtime/enroll');
      final body =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      expect(body['token'], 'one-time-code');
      expect(body['hostname'], 'test-mac');
      expect(body['platform'], isNotEmpty);
      expect(body['architecture'], anyOf('arm64', 'x64'));
      request.response.statusCode = HttpStatus.created;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'workspaceRuntimeId': 'runtime-1',
        'workspaceId': 'workspace-1',
        'workspaceName': 'MacBook Pro',
        'authToken': 'runtime-secret',
      }));
      await request.response.close();
    });

    final credentials = _MemoryCredentials();
    final service = WorkspacePairingService(
      dataDirectory: temp,
      credentialStore: credentials,
    );
    final registration = await service.pair(
      cloudUrl: 'http://127.0.0.1:${server.port}',
      token: 'one-time-code',
      hostname: 'test-mac',
    );
    await requestFuture;

    expect(registration.hostId, 'runtime-1');
    expect(registration.workspaceId, 'workspace-1');
    expect(registration.name, 'MacBook Pro');
    expect(credentials.values['runtime-1'], 'runtime-secret');

    final saved = HostRegistrationStore(temp).readSync();
    expect(saved?.hostId, 'runtime-1');
    expect(saved?.workspaceId, 'workspace-1');
    final raw = await File('${temp.path}/host-registration.json').readAsString();
    expect(raw, isNot(contains('runtime-secret')));
  });
}

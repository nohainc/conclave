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
  test('unpair revokes the runtime credential before local unlinking',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestFuture = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/workspace-runtime/unpair');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer runtime-secret');
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"unpaired":true}');
      await request.response.close();
    });

    await WorkspacePairingService.unpair(
      cloudUrl: 'http://127.0.0.1:${server.port}',
      token: 'runtime-secret',
    );
    await requestFuture;
  });

  test('pairs a desktop Workspace and persists only the runtime token locally',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('conclave-pairing-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    final requestFuture = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/workspace-runtime/enroll');
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
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
    final raw = await File('${temp.path}/host-config.json').readAsString();
    expect(raw, isNot(contains('runtime-secret')));
  });

  test('passes proposedWorkspaceName and installationId during pairing',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('conclave-pairing-name-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    final requestFuture = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/workspace-runtime/enroll');
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      expect(body['token'], 'one-time-code');
      expect(body['hostname'], 'test-mac.local');
      expect(body['name'], "Vitalii's MacBook Pro");
      expect(body['installationId'],
          'install_12345678-1234-4234-8234-123456789abc');
      request.response.statusCode = HttpStatus.created;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'workspaceRuntimeId': 'runtime-2',
        'workspaceId': 'workspace-2',
        'workspaceName': "Vitalii's MacBook Pro",
        'authToken': 'runtime-secret-2',
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
      hostname: 'test-mac.local',
      proposedWorkspaceName: "Vitalii's MacBook Pro",
      installationId: 'install_12345678-1234-4234-8234-123456789abc',
    );
    await requestFuture;

    expect(registration.hostId, 'runtime-2');
    expect(registration.workspaceId, 'workspace-2');
    expect(registration.name, "Vitalii's MacBook Pro");
    expect(registration.hostname, 'test-mac.local');
    expect(registration.installationId,
        'install_12345678-1234-4234-8234-123456789abc');

    final saved = HostRegistrationStore(temp).readSync();
    expect(saved?.name, "Vitalii's MacBook Pro");
    expect(saved?.hostname, 'test-mac.local');
    expect(
        saved?.installationId, 'install_12345678-1234-4234-8234-123456789abc');
  });

  group('SafeMachineFacts', () {
    test('collects safe machine facts without secrets', () {
      final facts = SafeMachineFacts.collect(
        installationId: 'install_123',
        name: "Vitalii's MacBook",
        hostname: 'vitalii-mac',
        platform: 'macos',
        architecture: 'arm64',
        appVersion: '1.0.3',
      );

      expect(facts.installationId, 'install_123');
      expect(facts.name, "Vitalii's MacBook");
      expect(facts.hostname, 'vitalii-mac');
      expect(facts.platform, 'macos');
      expect(facts.architecture, 'arm64');
      expect(facts.appVersion, '1.0.3');
      expect(facts.runtimeCapabilities['os'], 'macos');
      expect(facts.runtimeCapabilities['arch'], 'arm64');
      expect(facts.runtimeCapabilities['appVersion'], '1.0.3');
      expect(facts.runtimeCapabilities['supportedRuntimes'], ['dart']);
      expect(facts.runtimeCapabilities['maxConcurrentWorkers'], 1);

      final json = facts.toJson(token: 'pairing-code-123');
      expect(json.keys.toSet(), {
        'token',
        'hostname',
        'name',
        'installationId',
        'platform',
        'architecture',
        'appVersion',
        'runtimeCapabilities',
      });
      expect(json['token'], 'pairing-code-123');
      expect(json['name'], "Vitalii's MacBook");
    });

    test('detectArchitecture returns arm64 or x64', () {
      final arch = SafeMachineFacts.detectArchitecture();
      expect(arch, anyOf('arm64', 'x64'));
    });

    test('validateSafePayload rejects forbidden secret keys', () {
      final forbiddenKeys = [
        'apiKey',
        'api_key',
        'secret',
        'secrets',
        'password',
        'cookie',
        'cookies',
        'credential',
        'credentials',
        'authToken',
        'auth_token',
        'homeDirectory',
        'home_directory',
        'workRoot',
        'work_root',
        'filesystem',
        'inventory',
      ];

      for (final key in forbiddenKeys) {
        expect(
          () => SafeMachineFacts.validateSafePayload({
            'token': 'pairing-code',
            key: 'sensitive-value',
          }),
          throwsA(isA<ArgumentError>()),
          reason: 'Expected $key to be rejected',
        );

        // Nested in runtime capabilities
        expect(
          () => SafeMachineFacts.validateSafePayload({
            'token': 'pairing-code',
            'runtimeCapabilities': {
              'os': 'macos',
              key: 'nested-secret',
            },
          }),
          throwsA(isA<ArgumentError>()),
          reason: 'Expected nested $key to be rejected',
        );
      }
    });

    test('validateSafePayload allows safe metadata payload', () {
      final safePayload = {
        'token': 'pairing-code',
        'hostname': 'host.local',
        'name': 'My Computer',
        'installationId': 'install_uuid',
        'platform': 'macos',
        'architecture': 'arm64',
        'appVersion': '1.0.3',
        'runtimeCapabilities': {
          'os': 'macos',
          'arch': 'arm64',
          'appVersion': '1.0.3',
          'supportedRuntimes': ['dart'],
          'maxConcurrentWorkers': 1,
        },
      };

      expect(() => SafeMachineFacts.validateSafePayload(safePayload),
          returnsNormally);
    });
  });
}

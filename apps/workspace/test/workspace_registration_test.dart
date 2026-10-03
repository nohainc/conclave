import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/desktop_auth.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_registration.dart';
import 'package:test/test.dart';

class _MemoryCredentials implements SecureCredentialStore {
  final Map<String, String> values = {};

  @override
  String? readSync(String key) => values[key];

  @override
  Future<String?> read(String key) async => readSync(key);

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
  test('Workspace ownership read model rejects cross-account details', () {
    expect(
      WorkspaceOwnership.fromJson({'state': 'owned_by_other_user'}).state,
      WorkspaceOwnershipState.ownedByOtherUser,
    );
    expect(
      () => WorkspaceOwnership.fromJson({
        'state': 'owned_by_other_user',
        'workspaceId': 'private-workspace',
      }),
      throwsFormatException,
    );
  });

  test('Cloud API URLs normalize configured /api suffixes exactly once', () {
    const configured = 'https://app.conclaveax.com/api/';

    expect(
      normalizeWorkspaceCloudOrigin(configured),
      'https://app.conclaveax.com',
    );
    expect(
      workspaceCloudApiUri(configured, '/api/workspace-runtime/register'),
      Uri.parse('https://app.conclaveax.com/api/workspace-runtime/register'),
    );
  });

  test('desktop ownership check uses the authenticated human session',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestFuture = server.first.then((request) async {
      expect(request.uri.path, '/api/workspace-runtime/ownership');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer desktop-human-secret',
      );
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body, {
        'contractVersion': '1.0',
        'installationId': 'install_12345678-1234-4234-8234-123456789abc',
        'workspaceId': 'workspace-1',
        'runtimeId': 'runtime-1',
      });
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"state":"owned_by_current_user","workspaceId":"workspace-1",'
        '"workspaceRuntimeId":"runtime-1","ownerUserId":"user-a",'
        '"ownerMatchesCurrentSession":true,"runtimeState":"offline"}',
      );
      await request.response.close();
    });
    final client = DesktopAuthClient(
      cloudUrl: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(client.close);

    final ownership = await client.checkWorkspaceOwnership(
      session: DesktopHumanSession(
        credential: 'desktop-human-secret',
        sessionId: 'session-a',
        userId: 'user-a',
        displayName: 'A',
        email: 'a@example.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      installationId: 'install_12345678-1234-4234-8234-123456789abc',
      workspaceId: 'workspace-1',
      runtimeId: 'runtime-1',
    );

    expect(ownership.state, WorkspaceOwnershipState.ownedByCurrentUser);
    expect(ownership.workspaceId, 'workspace-1');
    expect(ownership.workspaceRuntimeId, 'runtime-1');
    expect(ownership.ownerUserId, 'user-a');
    expect(ownership.ownerMatchesCurrentSession, isTrue);
    expect(ownership.runtimeState, 'offline');
    await requestFuture;
  });

  test('registration uses desktop auth and stores runtime credentials securely',
      () async {
    final temp = await Directory.systemTemp.createTemp('workspace-register-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    final requestFuture = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/workspace-runtime/register');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer desktop-human-secret',
      );
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['contractVersion'], '1.0');
      expect(body['proposedWorkspaceName'], 'Test Workspace');
      expect(body['installationId'],
          'install_12345678-1234-4234-8234-123456789abc');
      expect(body, isNot(contains('token')));
      request.response.statusCode = HttpStatus.created;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'outcome': 'created',
        'workspaceId': 'workspace-1',
        'workspaceRuntimeId': 'runtime-1',
        'workspaceName': 'Test Workspace',
        'ownerUserId': 'user-a',
        'runtimeCredential': 'runtime-secret',
        'credentialIssuedAt': DateTime.now().toUtc().toIso8601String(),
        'credentialExpiresAt': null,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      }));
      await request.response.close();
    });

    final credentials = _MemoryCredentials();
    final registration = await WorkspaceRegistrationService(
      dataDirectory: temp,
      credentialStore: credentials,
    ).registerWithDesktopSession(
      cloudUrl: 'http://127.0.0.1:${server.port}',
      desktopCredential: 'desktop-human-secret',
      expectedOwnerUserId: 'user-a',
      facts: SafeMachineFacts.collect(
        installationId: 'install_12345678-1234-4234-8234-123456789abc',
        name: 'Test Workspace',
        hostname: 'test-host',
      ),
    );
    await requestFuture;

    expect(registration.workspaceRuntimeId, 'runtime-1');
    expect(registration.workspaceId, 'workspace-1');
    expect(credentials.values['runtime-1'], 'runtime-secret');
    final saved = WorkspaceRegistrationStore(temp).readSync();
    expect(saved?.workspaceId, 'workspace-1');
    final raw =
        await File('${temp.path}/workspace-registration.json').readAsString();
    expect(raw, isNot(contains('runtime-secret')));
  });

  test('same-owner connect recovers a missing runtime credential', () async {
    final temp = await Directory.systemTemp.createTemp('workspace-recovery-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    final requestFuture = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/workspace-runtime/register');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer desktop-human-secret',
      );
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(
        body['installationId'],
        'install_12345678-1234-4234-8234-123456789abc',
      );
      expect(body['proposedWorkspaceName'], 'Existing Workspace');
      request.response.statusCode = HttpStatus.created;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'outcome': 'recovered',
        'workspaceId': 'workspace-1',
        'workspaceRuntimeId': 'runtime-1',
        'workspaceName': 'Existing Workspace',
        'ownerUserId': 'user-a',
        'runtimeCredential': 'replacement-runtime-secret',
        'credentialIssuedAt': DateTime.now().toUtc().toIso8601String(),
        'credentialExpiresAt': null,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      }));
      await request.response.close();
    });

    final credentials = _MemoryCredentials();
    await WorkspaceRegistrationService(
      dataDirectory: temp,
      credentialStore: credentials,
    ).recoverMissingRuntimeCredential(
      registration: WorkspaceRegistration(
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        cloudUrl: 'http://127.0.0.1:${server.port}',
        name: 'Existing Workspace',
        hostname: 'existing-host',
        installationId: 'install_12345678-1234-4234-8234-123456789abc',
        ownerUserId: 'user-a',
      ),
      desktopCredential: 'desktop-human-secret',
      expectedOwnerUserId: 'user-a',
    );
    await requestFuture;

    expect(credentials.values['runtime-1'], 'replacement-runtime-secret');
    expect(
      WorkspaceRegistrationStore(temp).readSync()?.installationId,
      'install_12345678-1234-4234-8234-123456789abc',
    );
    final persisted = await File(
      '${temp.path}/workspace-registration.json',
    ).readAsString();
    expect(persisted, isNot(contains('replacement-runtime-secret')));
  });

  test('registration rejects a Workspace owned by another account', () async {
    final temp =
        await Directory.systemTemp.createTemp('workspace-owner-check-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    final requestFuture = server.first.then((request) async {
      expect(request.uri.path, '/api/workspace-runtime/register');
      request.response.statusCode = HttpStatus.created;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'outcome': 'recovered',
        'workspaceId': 'workspace-1',
        'workspaceRuntimeId': 'runtime-1',
        'workspaceName': 'Workspace',
        'ownerUserId': 'user-b',
        'runtimeCredential': 'runtime-secret',
        'credentialIssuedAt': DateTime.now().toUtc().toIso8601String(),
        'credentialExpiresAt': null,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      }));
      await request.response.close();
    });

    final credentials = _MemoryCredentials();
    await expectLater(
      WorkspaceRegistrationService(
        dataDirectory: temp,
        credentialStore: credentials,
      ).registerWithDesktopSession(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        desktopCredential: 'desktop-human-secret',
        expectedOwnerUserId: 'user-a',
        facts: SafeMachineFacts.collect(
          installationId: 'install_12345678-1234-4234-8234-123456789abc',
          name: 'Workspace',
          hostname: 'test-host',
        ),
      ),
      throwsStateError,
    );
    await requestFuture;
    expect(credentials.values, isEmpty);
    expect(WorkspaceRegistrationStore(temp).readSync(), isNull);
  });

  test('registration records persist the stable installation identity', () {
    const registration = WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      cloudUrl: 'https://app.conclaveax.com',
      name: 'My Workspace',
      hostname: 'my-host',
      installationId: 'install_12345678-1234-4234-8234-123456789abc',
      ownerUserId: 'user-a',
    );

    final decoded = WorkspaceRegistration.fromJson(registration.toJson());
    expect(decoded.workspaceRuntimeId, registration.workspaceRuntimeId);
    expect(decoded.workspaceId, registration.workspaceId);
    expect(decoded.installationId, registration.installationId);
    expect(decoded.ownerUserId, 'user-a');
    expect(
      () => WorkspaceRegistration.fromJson(
        Map<String, dynamic>.from(registration.toJson())
          ..remove('installationId'),
      ),
      throwsFormatException,
    );
  });

  test('machine registration facts exclude credentials and token fields', () {
    final facts = SafeMachineFacts.collect(
      installationId: 'install_12345678-1234-4234-8234-123456789abc',
      name: 'Test Workspace',
      hostname: 'test-host',
      platform: 'macos',
      architecture: 'arm64',
      appVersion: '1.0.3',
    );
    final payload = facts.toRegistrationJson();
    expect(
        payload.keys,
        containsAll([
          'hostname',
          'installationId',
          'name',
          'platform',
          'architecture',
          'appVersion',
          'runtimeCapabilities',
        ]));
    expect(payload.keys, isNot(contains('token')));
    expect(
      () => SafeMachineFacts.validateSafePayload({
        ...payload,
        'apiKey': 'secret-value',
      }),
      throwsArgumentError,
    );
  });
}

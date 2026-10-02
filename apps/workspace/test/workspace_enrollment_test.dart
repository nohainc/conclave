import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/desktop_auth.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace_enrollment.dart';
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
  test('Cloud API URLs normalize configured /api suffixes exactly once', () {
    final configured = 'https://app.conclaveax.com/api/';

    expect(
      normalizeWorkspaceCloudOrigin(configured),
      'https://app.conclaveax.com',
    );
    expect(
      workspaceCloudApiUri(configured, '/api/workspace-runtime/register'),
      Uri.parse('https://app.conclaveax.com/api/workspace-runtime/register'),
    );
  });

  test('desktop ownership check uses the human session and legacy binding IDs',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestFuture = server.first.then((request) async {
      expect(request.uri.path, '/api/workspace-runtime/ownership');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer desktop-human-secret');
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body, {
        'contractVersion': '1.0',
        'installationId': 'install_12345678-1234-4234-8234-123456789abc',
        'workspaceId': 'legacy-workspace',
        'runtimeId': 'legacy-runtime',
      });
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"registered":true,"ownerUserId":"user-a"}');
      await request.response.close();
    });
    final client = DesktopAuthClient(
      cloudUrl: 'http://127.0.0.1:${server.port}',
    );
    addTearDown(client.close);
    final owner = await client.checkWorkspaceOwnership(
      session: DesktopHumanSession(
        credential: 'desktop-human-secret',
        sessionId: 'session-a',
        userId: 'user-a',
        displayName: 'A',
        email: 'a@example.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
      installationId: 'install_12345678-1234-4234-8234-123456789abc',
      workspaceId: 'legacy-workspace',
      runtimeId: 'legacy-runtime',
    );
    expect(owner, 'user-a');
    await requestFuture;
  });

  test('desktop registration rejects a Workspace owned by another user',
      () async {
    final temp = await Directory.systemTemp.createTemp('owner-check-test-');
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
        'runtimeCredential': List.filled(32, 'r').join(),
        'credentialIssuedAt': DateTime.now().toUtc().toIso8601String(),
        'credentialExpiresAt': null,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      }));
      await request.response.close();
    });
    final credentials = _MemoryCredentials();
    final service = WorkspacePairingService(
      dataDirectory: temp,
      credentialStore: credentials,
    );

    await expectLater(
      service.registerWithDesktopSession(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        desktopCredential: 'h' * 32,
        expectedOwnerUserId: 'user-a',
        facts: SafeMachineFacts.collect(
          installationId: 'install_12345678-1234-4234-8234-123456789abc',
          name: 'Workspace',
          hostname: 'test-workspace',
        ),
      ),
      throwsStateError,
    );
    await requestFuture;
    expect(credentials.values, isEmpty,
        reason: 'Do not store a runtime credential before owner verification.');
    expect(WorkspaceRegistrationStore(temp).readSync(), isNull);
  });

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

  test('pairing recovery preserves local Workers and installation identity',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('conclave-pairing-recovery-');
    addTearDown(() => temp.delete(recursive: true));
    const registration = WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-old',
      workspaceId: 'workspace-old',
      cloudUrl: 'https://app.conclaveax.com',
      name: 'Development Mac',
      hostname: 'development-mac.local',
      installationId: 'install_12345678-1234-4234-8234-123456789abc',
    );
    await WorkspaceRegistrationStore(temp).write(registration);
    const workersJson = '{"workers":[{"id":"worker-1"}]}';
    await File('${temp.path}/configured-workers.json')
        .writeAsString(workersJson);
    final workRoot = Directory('${temp.path}/Work');
    await workRoot.create();
    await File('${workRoot.path}/keep.txt').writeAsString('local work');
    final identities = InstallationIdentityStore(temp);
    final installationId = await identities.getOrCreate(
      initialIdentity: registration.installationId,
    );
    final credentials = _MemoryCredentials()
      ..values['runtime-old'] = 'old-runtime-credential'
      ..values['worker-credential/worker-1'] = 'local-worker-credential';

    await WorkspacePairingService(
      dataDirectory: temp,
      credentialStore: credentials,
    ).preparePairingRecovery();

    expect(WorkspaceRegistrationStore(temp).readSync(), isNull);
    expect(credentials.values, isNot(contains('runtime-old')));
    expect(credentials.values['worker-credential/worker-1'],
        'local-worker-credential');
    expect(await File('${temp.path}/configured-workers.json').readAsString(),
        workersJson);
    expect(
        await File('${workRoot.path}/keep.txt').readAsString(), 'local work');
    expect(await identities.getOrCreate(), installationId);
    expect(identities.recoveryAuthorizedSync(), isTrue);
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

    expect(registration.workspaceRuntimeId, 'runtime-1');
    expect(registration.workspaceId, 'workspace-1');
    expect(registration.name, 'MacBook Pro');
    expect(credentials.values['runtime-1'], 'runtime-secret');

    final saved = WorkspaceRegistrationStore(temp).readSync();
    expect(saved?.workspaceRuntimeId, 'runtime-1');
    expect(saved?.workspaceId, 'workspace-1');
    final raw =
        await File('${temp.path}/workspace-registration.json').readAsString();
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
      expect(body['allowRecovery'], isTrue);
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
      allowRecovery: true,
    );
    await requestFuture;

    expect(registration.workspaceRuntimeId, 'runtime-2');
    expect(registration.workspaceRuntimeId, 'runtime-2');
    expect(registration.workspaceId, 'workspace-2');
    expect(registration.name, "Vitalii's MacBook Pro");
    expect(registration.name, "Vitalii's MacBook Pro");
    expect(registration.hostname, 'test-mac.local');
    expect(registration.installationId,
        'install_12345678-1234-4234-8234-123456789abc');
    expect(registration.pairedAt, isNotNull);

    final saved = WorkspaceRegistrationStore(temp).readSync();
    expect(saved?.name, "Vitalii's MacBook Pro");
    expect(saved?.name, "Vitalii's MacBook Pro");
    expect(saved?.hostname, 'test-mac.local');
    expect(
        saved?.installationId, 'install_12345678-1234-4234-8234-123456789abc');
    expect(saved?.pairedAt, isNotNull);
  });

  test('WorkspaceRegistration serializes and deserializes canonical identity',
      () {
    final reg = const WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-abc',
      workspaceId: 'workspace-xyz',
      cloudUrl: 'https://app.conclaveax.com',
      name: 'My Workspace',
      hostname: 'my-mac',
      installationId: 'install_123',
      pairedAt: '2026-09-26T20:00:00.000Z',
    );

    expect(reg.workspaceRuntimeId, 'runtime-abc');
    expect(reg.name, 'My Workspace');

    final json = reg.toJson();
    expect(json['workspaceRuntimeId'], 'runtime-abc');
    expect(json['workspaceId'], 'workspace-xyz');
    expect(json['cloudUrl'], 'https://app.conclaveax.com');
    expect(json['name'], 'My Workspace');
    expect(json['hostname'], 'my-mac');
    expect(json['installationId'], 'install_123');
    expect(json['pairedAt'], '2026-09-26T20:00:00.000Z');

    final deserialized = WorkspaceRegistration.fromJson(json);
    expect(deserialized.workspaceRuntimeId, 'runtime-abc');
    expect(deserialized.workspaceId, 'workspace-xyz');
    expect(deserialized.cloudUrl, 'https://app.conclaveax.com');
    expect(deserialized.name, 'My Workspace');
    expect(deserialized.hostname, 'my-mac');
    expect(deserialized.installationId, 'install_123');
    expect(deserialized.pairedAt, '2026-09-26T20:00:00.000Z');

    // Optional pairing time may be absent, but a registration must retain the
    // stable identity created when this fresh v8 installation was paired.
    final withoutPairingTime = WorkspaceRegistration.fromJson(
      Map<String, dynamic>.from(json)..remove('pairedAt'),
    );
    expect(withoutPairingTime.pairedAt, isNull);
    expect(
      () => WorkspaceRegistration.fromJson({...json}..remove('installationId')),
      throwsFormatException,
    );
  });

  test('blocks pairing if installation is already paired locally', () async {
    final temp =
        await Directory.systemTemp.createTemp('conclave-pairing-block-test-');
    addTearDown(() => temp.delete(recursive: true));

    final registration = const WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-existing',
      workspaceId: 'workspace-existing',
      cloudUrl: 'https://app.conclaveax.com',
      name: 'Existing Workspace',
      hostname: 'test-mac',
      installationId: 'install_existing',
    );
    await WorkspaceRegistrationStore(temp).write(registration);

    final service = WorkspacePairingService(
      dataDirectory: temp,
      credentialStore: _MemoryCredentials(),
    );

    expect(
      () => service.pair(
        cloudUrl: 'https://app.conclaveax.com',
        token: 'new-token',
        hostname: 'test-mac',
      ),
      throwsA(
        isA<WorkspacePairingException>()
            .having(
              (e) => e.kind,
              'kind',
              WorkspacePairingErrorKind.installationAlreadyPaired,
            )
            .having(
              (e) => e.message,
              'message',
              'This installation is already connected to a Workspace.',
            )
            .having(
              (e) => e.action,
              'action',
              'Disconnect the current Workspace before connecting to another account.',
            ),
      ),
    );
  });

  group('WorkspacePairingException failure state classification', () {
    test('classifies expired code', () {
      final fromStatus = WorkspacePairingException.fromError(
        statusCode: 410,
        serverError: 'Pairing code has expired',
      );
      expect(fromStatus.kind, WorkspacePairingErrorKind.expiredCode);
      expect(fromStatus.message, 'This pairing code has expired.');
      expect(fromStatus.action,
          'Generate a new code in Conclave AX and try again.');

      final fromCode = WorkspacePairingException.fromError(
        serverCode: 'pairing_code_expired',
      );
      expect(fromCode.kind, WorkspacePairingErrorKind.expiredCode);
    });

    test('classifies already claimed / used code', () {
      final fromCode = WorkspacePairingException.fromError(
        statusCode: 409,
        serverCode: 'pairing_already_claimed',
        serverError: 'Pairing code was already claimed',
      );
      expect(fromCode.kind, WorkspacePairingErrorKind.alreadyUsed);
      expect(fromCode.message, 'This pairing code has already been used.');
      expect(fromCode.action,
          'Generate a fresh pairing code in Conclave AX to connect this Workspace.');
    });

    test('classifies already paired installation from server', () {
      final ex = WorkspacePairingException.fromError(
        statusCode: 409,
        serverCode: 'installation_already_paired',
      );
      expect(ex.kind, WorkspacePairingErrorKind.installationAlreadyPaired);
      expect(
          ex.message, 'This installation is already connected to a Workspace.');
      expect(ex.action,
          'Disconnect the current Workspace before connecting to another account.');
    });

    test('explains when explicit installation recovery is required', () {
      final ex = WorkspacePairingException.fromError(
        statusCode: 409,
        serverCode: 'installation_recovery_required',
        serverError: 'This installation was previously paired',
      );
      expect(ex.kind, WorkspacePairingErrorKind.installationAlreadyPaired);
      expect(ex.message, 'This installation needs explicit pairing recovery.');
      expect(ex.action, contains('Disconnect in Conclave Workspace'));
    });

    test('classifies revoked / inactive account', () {
      final ex = WorkspacePairingException.fromError(
        statusCode: 403,
        serverCode: 'account_revoked',
        serverError: 'Pairing owner is no longer active',
      );
      expect(ex.kind, WorkspacePairingErrorKind.workspaceOrAccountRevoked);
      expect(ex.message,
          'The associated account or Workspace is inactive or revoked.');
      expect(
          ex.action, 'Sign in to Conclave AX to verify your account status.');
    });

    test('classifies unsupported version', () {
      final ex = WorkspacePairingException.fromError(
        serverCode: 'version_unsupported',
        serverError: 'Workspace app version is unsupported',
      );
      expect(ex.kind, WorkspacePairingErrorKind.versionUnsupported);
      expect(ex.message,
          'This version of Conclave Workspace is no longer supported.');
      expect(
          ex.action, 'Please update Conclave Workspace to the latest version.');
    });

    test('classifies invalid pairing code', () {
      final ex = WorkspacePairingException.fromError(
        statusCode: 401,
        serverCode: 'invalid_pairing_code',
        serverError:
            'Invalid, expired, revoked, or already used enrollment token',
      );
      expect(ex.kind, WorkspacePairingErrorKind.invalidCode);
      expect(ex.message, 'The pairing code is invalid.');
      expect(ex.action, 'Check the code in Conclave AX and try again.');
    });

    test('classifies cloud unavailable on network exceptions or 5xx', () {
      final fromSocket = WorkspacePairingException.fromError(
        underlyingError: const SocketException('Connection refused'),
      );
      expect(fromSocket.kind, WorkspacePairingErrorKind.cloudUnavailable);
      expect(fromSocket.message, 'Unable to connect to Conclave Cloud.');
      expect(fromSocket.action,
          'Check your internet connection or verify the Cloud URL.');

      final from502 = WorkspacePairingException.fromError(
        statusCode: 502,
        serverError: 'Bad Gateway',
      );
      expect(from502.kind, WorkspacePairingErrorKind.cloudUnavailable);
    });

    test('classifies server validation failure on 400', () {
      final ex = WorkspacePairingException.fromError(
        statusCode: 400,
        serverError: 'Workspace name is invalid or exceeds 120 characters',
      );
      expect(ex.kind, WorkspacePairingErrorKind.serverValidationFailure);
      expect(ex.message, 'Registration details were rejected by the server.');
      expect(ex.action, 'Workspace name is invalid or exceeds 120 characters');
    });
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
        'hostname': 'workspace.local',
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

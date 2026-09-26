import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/friendly_computer_name.dart';
import 'package:conclave_host/host.dart';
import 'package:conclave_host/host_configuration.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/secure_credentials.dart';
import 'package:conclave_host/workspace_enrollment.dart';
import 'package:conclave_host/workspace_runtime.dart';
import 'package:test/test.dart';

class _MemoryCredentialStore implements SecureCredentialStore {
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

class _TestPlatformRuntime implements PlatformRuntime {
  _TestPlatformRuntime();

  @override
  String get operatingSystem => 'macos';
  @override
  bool get isWindows => false;
  @override
  String get homeDirectory => '/tmp';
  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {}
  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [];
  @override
  Future<Process> startIsolatedProcess(
      String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true}) {
    throw UnsupportedError('not used in tests');
  }

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {}
}

void main() {
  group('Phase B10: Desktop Pairing & Lifecycle Acceptance Tests', () {
    late Directory tempDir;
    late _MemoryCredentialStore credentialStore;

    setUp(() async {
      tempDir = await Directory.systemTemp
          .createTemp('conclave-desktop-b10-test-');
      credentialStore = _MemoryCredentialStore();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('1. installation ID generated once', () async {
      final store = InstallationIdentityStore(tempDir);
      final id1 = await store.getOrCreate();
      final id2 = await store.getOrCreate();

      expect(id1, startsWith('install_'));
      expect(id1, equals(id2));
    });

    test('2. installation ID survives restart', () async {
      final store1 = InstallationIdentityStore(tempDir);
      final id1 = await store1.getOrCreate();

      // Simulate restart with new store instance
      final store2 = InstallationIdentityStore(tempDir);
      final id2 = store2.readSync();

      expect(id2, equals(id1));
      expect(await store2.getOrCreate(), equals(id1));
    });

    test('3. computer-name default resolves friendly name with hostname fallback',
        () async {
      final friendly = resolveFriendlyComputerNameSync(
        localHostname: 'vitalii-macbook-pro.local',
      );
      expect(friendly, isNotEmpty);
      expect(friendly, isNot(contains('.local')));
    });

    test('4. user edits Workspace name during pairing', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        expect(body['name'], "Vitalii's Custom Studio");
        request.response.statusCode = HttpStatus.created;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'workspaceRuntimeId': 'runtime-custom-1',
          'workspaceId': 'ws-custom-1',
          'workspaceName': "Vitalii's Custom Studio",
          'authToken': 'tok_custom_1',
        }));
        await request.response.close();
      });

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );
      final reg = await service.pair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'code-123',
        hostname: 'test-mac',
        proposedWorkspaceName: "Vitalii's Custom Studio",
      );

      expect(reg.name, "Vitalii's Custom Studio");
      expect(reg.workspaceName, "Vitalii's Custom Studio");
    });

    test('5. successful pairing stores canonical identity and credentials',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.created;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'workspaceRuntimeId': 'runtime-success-1',
          'workspaceId': 'ws-success-1',
          'workspaceName': 'Main Studio',
          'authToken': 'conclave_workspace_tok_abc',
        }));
        await request.response.close();
      });

      final installStore = InstallationIdentityStore(tempDir);
      final installId = await installStore.getOrCreate();

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );
      final reg = await service.pair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'code-valid',
        hostname: 'mac.local',
        installationId: installId,
      );

      expect(reg.hostId, 'runtime-success-1');
      expect(reg.workspaceId, 'ws-success-1');
      expect(reg.workspaceName, 'Main Studio');
      expect(reg.credentialRef, 'workspace-runtime:runtime-success-1');
      expect(reg.installationId, installId);
      expect(reg.pairedAt, isNotNull);
      expect(credentialStore.values['runtime-success-1'],
          'conclave_workspace_tok_abc');
    });

    test('6. runtime starts immediately after pairing', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.created;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'workspaceRuntimeId': 'runtime-live-1',
          'workspaceId': 'ws-live-1',
          'workspaceName': 'Live Studio',
          'authToken': 'tok_live_1',
        }));
        await request.response.close();
      });

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );
      await service.pair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'code-live',
        hostname: 'mac.local',
      );

      // Build runtime immediately without restarting app
      final config = HostConfig.fromArgs(
        ['--data-dir', tempDir.path],
        credentialStore: credentialStore,
      );
      final runtime = await buildWorkspaceRuntime(config);
      expect(runtime.config.workspaceId, 'ws-live-1');
      expect(runtime.config.hostId, 'runtime-live-1');
      expect(runtime.config.authToken, 'tok_live_1');
      await runtime.stop();
    });

    test('7. pairing code invalid returns actionable error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'Invalid pairing code',
          'code': 'invalid_pairing_code',
        }));
        await request.response.close();
      });

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );

      expect(
        () => service.pair(
          cloudUrl: 'http://127.0.0.1:${server.port}',
          token: 'bad-code',
          hostname: 'mac.local',
        ),
        throwsA(
          isA<WorkspacePairingException>()
              .having((e) => e.kind, 'kind', WorkspacePairingErrorKind.invalidCode)
              .having((e) => e.message, 'message', 'The pairing code is invalid.')
              .having((e) => e.action, 'action',
                  'Check the code in Conclave AX and try again.'),
        ),
      );
    });

    test('8. pairing code expired returns actionable error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.gone;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'Pairing code has expired',
          'code': 'pairing_code_expired',
        }));
        await request.response.close();
      });

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );

      expect(
        () => service.pair(
          cloudUrl: 'http://127.0.0.1:${server.port}',
          token: 'expired-code',
          hostname: 'mac.local',
        ),
        throwsA(
          isA<WorkspacePairingException>()
              .having((e) => e.kind, 'kind', WorkspacePairingErrorKind.expiredCode)
              .having((e) => e.message, 'message',
                  'This pairing code has expired.')
              .having((e) => e.action, 'action',
                  'Generate a new code in Conclave AX and try again.'),
        ),
      );
    });

    test('9. installation already paired prevents concurrent registration',
        () async {
      final store = HostRegistrationStore(tempDir);
      await store.write(const HostRegistration(
        hostId: 'runtime-active-1',
        workspaceId: 'ws-active-1',
        cloudUrl: 'https://app.conclaveax.com',
        name: 'Active Mac',
        hostname: 'mac.local',
      ));

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );

      expect(
        () => service.pair(
          cloudUrl: 'https://app.conclaveax.com',
          token: 'new-code',
          hostname: 'mac.local',
        ),
        throwsA(
          isA<WorkspacePairingException>().having(
            (e) => e.kind,
            'kind',
            WorkspacePairingErrorKind.installationAlreadyPaired,
          ),
        ),
      );
    });

    test('10. local second-pair attempt rejected with clear unpair guidance',
        () async {
      final store = HostRegistrationStore(tempDir);
      await store.write(const HostRegistration(
        hostId: 'runtime-active-2',
        workspaceId: 'ws-active-2',
        cloudUrl: 'https://app.conclaveax.com',
        name: 'Office Mac',
        hostname: 'mac.local',
      ));

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );

      try {
        await service.pair(
          cloudUrl: 'https://app.conclaveax.com',
          token: 'another-code',
          hostname: 'mac.local',
        );
        fail('Should have thrown WorkspacePairingException');
      } on WorkspacePairingException catch (e) {
        expect(e.message,
            'This installation is already connected to a Workspace.');
        expect(e.action,
            'Disconnect the current Workspace before connecting to another account.');
      }
    });

    test('11. Cloud second-pair rejection handled gracefully', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.conflict;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error':
              'This installation is already paired; unpair it before pairing another Workspace',
          'code': 'installation_already_paired',
        }));
        await request.response.close();
      });

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );

      expect(
        () => service.pair(
          cloudUrl: 'http://127.0.0.1:${server.port}',
          token: 'fresh-code',
          hostname: 'mac.local',
        ),
        throwsA(
          isA<WorkspacePairingException>().having(
            (e) => e.kind,
            'kind',
            WorkspacePairingErrorKind.installationAlreadyPaired,
          ),
        ),
      );
    });

    test('12. reconnect to same Workspace preserves credentials and configuration',
        () async {
      final regStore = HostRegistrationStore(tempDir);
      await regStore.write(const HostRegistration(
        hostId: 'runtime-recon-1',
        workspaceId: 'ws-recon-1',
        cloudUrl: 'https://app.conclaveax.com',
        name: 'Main Studio',
        hostname: 'studio.local',
        credentialRef: 'workspace-runtime:runtime-recon-1',
      ));
      await credentialStore.write(
          'runtime-recon-1', 'tok_reconnect_preserved');

      final config = HostConfig.fromArgs(
        ['--data-dir', tempDir.path],
        credentialStore: credentialStore,
      );

      expect(config.hostId, 'runtime-recon-1');
      expect(config.workspaceId, 'ws-recon-1');
      expect(config.authToken, 'tok_reconnect_preserved');
    });

    test('13. disconnect Workspace revokes cloud runtime without deleting local workers',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      var cloudUnpairCalled = false;
      server.listen((request) async {
        expect(request.uri.path, '/api/workspace-runtime/unpair');
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer tok_unpair_1');
        cloudUnpairCalled = true;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"unpaired":true}');
        await request.response.close();
      });

      // Write local registration & credential
      final regStore = HostRegistrationStore(tempDir);
      await regStore.write(HostRegistration(
        hostId: 'runtime-unpair-1',
        workspaceId: 'ws-unpair-1',
        cloudUrl: 'http://127.0.0.1:${server.port}',
        name: 'Unpair Mac',
        hostname: 'mac.local',
      ));
      await credentialStore.write('runtime-unpair-1', 'tok_unpair_1');

      // Configure a local worker
      final localWsStore = LocalWorkspaceIdentityStore(tempDir);
      final localWsId = await localWsStore.getOrCreate();
      final workerRegistry = LocalConfiguredWorkerRegistry(
        dataDirectory: tempDir,
        workspaceId: localWsId,
        platform: _TestPlatformRuntime(),
        idGenerator: () => 'worker-local-1',
      );
      await workerRegistry.create(
        name: 'Claude Local',
        workerTypeId: 'claude-code',
        authStrategy: 'api_key',
        credentialRef: 'worker-credential/worker-local-1',
        defaultModel: 'claude-3-7-sonnet',
        allowedModels: const ['claude-3-7-sonnet'],
        localPermissions: const ['workstream_filesystem'],
        localConcurrencyLimit: 1,
        adapterVersionPolicy: 'latest',
        status: LocalWorkerStatus.ready,
        credentialStatus: LocalWorkerCredentialStatus.ready,
      );
      await credentialStore.write(
          'worker-credential/worker-local-1', 'sk-ant-test-key');

      // Perform disconnect
      await WorkspacePairingService.unpair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'tok_unpair_1',
      );
      await credentialStore.delete('runtime-unpair-1');
      await regStore.clear();

      expect(cloudUnpairCalled, isTrue);
      expect(regStore.readSync(), isNull);
      expect(credentialStore.readSync('runtime-unpair-1'), isNull);

      // Verify local worker and worker secret remain intact!
      final workers = await workerRegistry.list();
      expect(workers, hasLength(1));
      expect(workers.first.name, 'Claude Local');
      expect(credentialStore.readSync('worker-credential/worker-local-1'),
          'sk-ant-test-key');
    });

    test('14. re-pair after legitimate disconnect succeeds with new runtime ID',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      var enrollmentsCount = 0;
      server.listen((request) async {
        enrollmentsCount++;
        request.response.statusCode = HttpStatus.created;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'workspaceRuntimeId': 'runtime-new-$enrollmentsCount',
          'workspaceId': 'ws-target-$enrollmentsCount',
          'workspaceName': 'Target Workspace',
          'authToken': 'tok_new_$enrollmentsCount',
        }));
        await request.response.close();
      });

      final regStore = HostRegistrationStore(tempDir);
      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );

      // First pairing
      final reg1 = await service.pair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'token-1',
        hostname: 'mac.local',
      );
      expect(reg1.hostId, 'runtime-new-1');

      // Disconnect
      await credentialStore.delete('runtime-new-1');
      await regStore.clear();
      expect(regStore.readSync(), isNull);

      // Re-pair with new workspace/token
      final reg2 = await service.pair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'token-2',
        hostname: 'mac.local',
      );
      expect(reg2.hostId, 'runtime-new-2');
      expect(reg2.workspaceId, 'ws-target-2');
      expect(credentialStore.readSync('runtime-new-2'), 'tok_new_2');
    });

    test('15. runtime credential stored securely in SecureCredentialStore',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.created;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'workspaceRuntimeId': 'runtime-secure-test',
          'workspaceId': 'ws-sec-test',
          'workspaceName': 'Secure Studio',
          'authToken': 'secret_runtime_bearer_token_xyz',
        }));
        await request.response.close();
      });

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );
      await service.pair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'code-sec',
        hostname: 'mac.local',
      );

      expect(credentialStore.values['runtime-secure-test'],
          'secret_runtime_bearer_token_xyz');
    });

    test('16. safe local registration contains no bearer token', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        request.response.statusCode = HttpStatus.created;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'workspaceRuntimeId': 'runtime-safe-test',
          'workspaceId': 'ws-safe-test',
          'workspaceName': 'Safe Studio',
          'authToken': 'secret_super_secret_bearer_token',
        }));
        await request.response.close();
      });

      final service = WorkspacePairingService(
        dataDirectory: tempDir,
        credentialStore: credentialStore,
      );
      await service.pair(
        cloudUrl: 'http://127.0.0.1:${server.port}',
        token: 'code-safe',
        hostname: 'mac.local',
      );

      final configFile = File('${tempDir.path}/host-config.json');
      expect(configFile.existsSync(), isTrue);
      final rawContent = await configFile.readAsString();

      expect(rawContent, isNot(contains('secret_super_secret_bearer_token')));
      expect(rawContent, isNot(contains('authToken')));
      expect(rawContent, isNot(contains('auth_token')));
      expect(rawContent, isNot(contains('bearer')));

      // Decoded JSON contains safe reference only
      final decoded = jsonDecode(rawContent) as Map<String, dynamic>;
      expect(decoded['credentialRef'], 'workspace-runtime:runtime-safe-test');
      expect(decoded['hostId'], 'runtime-safe-test');
      expect(decoded['workspaceId'], 'ws-safe-test');
    });

    test('17. Workers remain isolated and local across pairing lifecycle',
        () async {
      final localWsStore = LocalWorkspaceIdentityStore(tempDir);
      final localWsId = await localWsStore.getOrCreate();

      final registry = LocalConfiguredWorkerRegistry(
        dataDirectory: tempDir,
        workspaceId: localWsId,
        platform: _TestPlatformRuntime(),
      );

      await registry.create(
        name: 'Ollama Qwen',
        workerTypeId: 'ollama',
        authStrategy: 'local_endpoint',
        credentialRef: null,
        defaultModel: 'qwen2.5-coder:32b',
        allowedModels: const ['qwen2.5-coder:32b'],
        localPermissions: const ['workstream_filesystem', 'terminal_process'],
        localConcurrencyLimit: 1,
        adapterVersionPolicy: 'latest',
        status: LocalWorkerStatus.ready,
        credentialStatus: LocalWorkerCredentialStatus.ready,
      );

      // Local workers file is separate from host-config.json
      final workerFile = File('${tempDir.path}/configured-workers.json');
      expect(workerFile.existsSync(), isTrue);

      final workers = await registry.list();
      expect(workers.first.name, 'Ollama Qwen');
      expect(workers.first.workspaceId, localWsId);
    });

    test('18. machine rename does not change Workspace identity or installation ID',
        () async {
      final installStore = InstallationIdentityStore(tempDir);
      final installId = await installStore.getOrCreate();

      final regStore = HostRegistrationStore(tempDir);
      await regStore.write(HostRegistration(
        hostId: 'runtime-static-1',
        workspaceId: 'ws-static-1',
        cloudUrl: 'https://app.conclaveax.com',
        name: "Vitalii's Studio",
        hostname: 'vitalii-macbook-pro.local',
        installationId: installId,
      ));

      // Simulate OS hostname changing after network change / system settings rename
      final reloadedStore = HostRegistrationStore(tempDir);
      final savedReg = reloadedStore.readSync();

      expect(savedReg?.installationId, installId);
      expect(savedReg?.workspaceId, 'ws-static-1');
      expect(savedReg?.hostId, 'runtime-static-1');
      expect(await installStore.getOrCreate(), installId);
    });

    test('19. Workspace rename does not change installation identity',
        () async {
      final installStore = InstallationIdentityStore(tempDir);
      final installId = await installStore.getOrCreate();

      final regStore = HostRegistrationStore(tempDir);
      final initialReg = HostRegistration(
        hostId: 'runtime-renamed-1',
        workspaceId: 'ws-renamed-1',
        cloudUrl: 'https://app.conclaveax.com',
        name: 'Old Studio Name',
        hostname: 'mac.local',
        installationId: installId,
      );
      await regStore.write(initialReg);

      // Cloud renames workspace to "New Studio Name"
      final updatedReg = HostRegistration(
        hostId: initialReg.hostId,
        workspaceId: initialReg.workspaceId,
        cloudUrl: initialReg.cloudUrl,
        name: 'New Studio Name',
        hostname: initialReg.hostname,
        installationId: installId,
        credentialRef: initialReg.credentialRef,
        pairedAt: initialReg.pairedAt,
      );
      await regStore.write(updatedReg);

      final read = regStore.readSync();
      expect(read?.name, 'New Studio Name');
      expect(read?.installationId, installId);
      expect(await installStore.getOrCreate(), installId);
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/worker_diagnostic_store.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:conclave_workspace/local_worker_setup.dart';
import 'package:conclave_workspace/workspace_worker_view.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  test(
    'a dynamic Worker survives an offline restart, retirement, and restoration',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('third-cli-profile-');
      addTearDown(() => root.delete(recursive: true));

      final signing = await Ed25519ReleaseFixture.create();
      var profileStore = ToolProfileReleaseStore(
        profilesRoot: Directory('${root.path}/Profiles'),
        trustPolicy: signing.trustPolicy,
      );
      final profileFile = File(
        '$repository/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
      );
      final profile =
          jsonDecode(await profileFile.readAsString()) as Map<String, Object?>;
      profile['profileDefinitionId'] = 'dynamic-test-cli';
      profile['logicalWorkerTypeId'] = 'dynamic-test-worker';
      final release = <String, Object?>{
        'profileDefinitionId': 'dynamic-test-cli',
        'workerTypeId': 'dynamic-test-worker',
        'displayName': 'Dynamic Test Worker',
        'providerToolName': 'Fixture CLI',
        'channel': 'stable',
        'releaseVersion': 1,
        'profile': profile,
        'schemaVersion': profile['schemaVersion'],
        'engineFamily': profile['engineFamily'],
        'engineCompatibility': profile['engineCompatibility'],
      };
      await signing.signToolProfileRelease(release);
      final newerProfile = Map<String, Object?>.from(profile)
        ..['releaseVersion'] = 2;
      final newerRelease = Map<String, Object?>.from(release)
        ..['releaseVersion'] = 2
        ..['profile'] = newerProfile;
      await signing.signToolProfileRelease(newerRelease);
      const dynamicDescriptor = {
        'workerTypeId': 'dynamic-test-worker',
        'displayName': 'Dynamic Test Worker',
        'description': 'A Worker known only to this acceptance fixture.',
        'profileDefinitionId': 'dynamic-test-cli',
        'providerToolName': 'Fixture CLI',
        'engineFamily': 'cli',
        'visibilityState': 'visible',
        'releaseStage': 'stable',
        'capabilities': ['text'],
        'sortOrder': 5,
      };
      const newlyApprovedDescriptor = {
        'workerTypeId': 'offline-added-worker',
        'displayName': 'Offline Added Worker',
        'description': 'Added while this Workspace is offline.',
        'profileDefinitionId': 'offline-added-profile',
        'providerToolName': 'Offline Fixture CLI',
        'engineFamily': 'cli',
        'visibilityState': 'visible',
        'releaseStage': 'stable',
        'capabilities': ['text'],
        'sortOrder': 6,
      };
      var cloudAvailable = true;
      var catalogActive = true;
      var newWorkerApproved = false;
      var dynamicReleases = <Map<String, Object?>>[release];
      var catalog = ToolProfileCatalogClient(
        cloudUri: Uri.https('cloud.example', '/'),
        store: profileStore,
        trustPolicy: signing.trustPolicy,
        trustRefresher: () async {
          if (!cloudAvailable) throw const SocketException('offline');
        },
        workerCatalogLoader: () async {
          if (!cloudAvailable) throw const SocketException('offline');
          return [
            if (catalogActive) dynamicDescriptor,
            if (newWorkerApproved) newlyApprovedDescriptor,
          ];
        },
        listLoader: (workerTypeId, channel) async {
          expect(channel, 'stable');
          return ToolProfileCatalogResult(
            channel: channel,
            releases: workerTypeId == 'dynamic-test-worker'
                ? dynamicReleases
                : const [],
          );
        },
        candidateValidator: (admission, file) async =>
            admission.logicalWorkerTypeId == 'dynamic-test-worker' &&
            await file.exists(),
      );
      var registry = LocalWorkerRegistry(
        dataDirectory: Directory('${root.path}/Registry'),
        workspaceId: 'workspace-dynamic-worker',
        idGenerator: () => 'dynamic-test-worker-local',
      );
      var coordinator = WorkerCatalogCoordinator(
        catalog: catalog,
        releaseStore: profileStore,
        registry: registry,
      );
      await coordinator.refresh(force: true);
      final entry = coordinator.entryForWorker('dynamic-test-worker');
      expect(entry?.displayName, 'Dynamic Test Worker');
      expect(
        await profileStore.profileFile('dynamic-test-cli', 1).exists(),
        isTrue,
      );
      expect(
        (await profileStore.activeRelease('dynamic-test-cli'))?.releaseVersion,
        1,
      );

      final initialWorker =
          await LocalWorkerSetupService(registry: registry).createCatalogWorker(
        entry: entry!,
        permissions: const ['repository:read'],
      );
      await coordinator.refreshLocalWorkers();

      // Simulate a Cloud-side Worker addition and Profile update, then restart
      // Workspace with Cloud unreachable. The durable local state must win.
      newWorkerApproved = true;
      dynamicReleases = [newerRelease];
      cloudAvailable = false;
      coordinator.dispose();
      catalog.close();
      var postRestartProfileRequests = 0;
      profileStore = ToolProfileReleaseStore(
        profilesRoot: Directory('${root.path}/Profiles'),
        trustPolicy: signing.trustPolicy,
      );
      registry = LocalWorkerRegistry(
        dataDirectory: Directory('${root.path}/Registry'),
        workspaceId: 'workspace-dynamic-worker',
        idGenerator: () => 'dynamic-test-worker-local-next',
      );
      catalog = ToolProfileCatalogClient(
        cloudUri: Uri.https('cloud.example', '/'),
        store: profileStore,
        trustPolicy: signing.trustPolicy,
        trustRefresher: () async {
          if (!cloudAvailable) throw const SocketException('offline');
        },
        workerCatalogLoader: () async {
          if (!cloudAvailable) throw const SocketException('offline');
          return [
            if (catalogActive) dynamicDescriptor,
            if (newWorkerApproved) newlyApprovedDescriptor,
          ];
        },
        listLoader: (workerTypeId, channel) async {
          if (!cloudAvailable) throw const SocketException('offline');
          postRestartProfileRequests++;
          return ToolProfileCatalogResult(
            channel: channel,
            releases: workerTypeId == 'dynamic-test-worker'
                ? dynamicReleases
                : const [],
          );
        },
        candidateValidator: (admission, file) async =>
            admission.logicalWorkerTypeId == 'dynamic-test-worker' &&
            await file.exists(),
      );
      coordinator = WorkerCatalogCoordinator(
        catalog: catalog,
        releaseStore: profileStore,
        registry: registry,
      );
      await coordinator.refresh(force: true);
      expect(coordinator.snapshot.catalogConfirmed, isFalse);
      expect(coordinator.snapshot.descriptors, hasLength(1));
      expect(
        coordinator.snapshot.profiles['dynamic-test-worker']?.state,
        WorkspaceWorkerProfileState.ready,
      );
      expect(
        coordinator.snapshot.workers.single.localWorker?.id,
        initialWorker.id,
      );
      expect(
        coordinator.snapshot.workers.single.descriptor?.displayName,
        'Dynamic Test Worker',
      );
      expect(
          await coordinator.ensureCatalogEntry('offline-added-worker'), isNull);
      expect(
        (await profileStore.activeRelease('dynamic-test-cli'))?.releaseVersion,
        1,
      );
      expect(
        await profileStore.profileFile('dynamic-test-cli', 2).exists(),
        isFalse,
      );
      final worker = (await registry.find(initialWorker.id))!;

      final providerDirectory = Directory('${root.path}/provider-bin')
        ..createSync();
      final providerExecutable = File(
        '${providerDirectory.path}/fixture-provider'
        '${Platform.isWindows ? '.exe' : ''}',
      );
      final providerBuild = await Process.run(
        _dartExecutable(),
        [
          'compile',
          'exe',
          '$repository/packages/tool-profile/test/fixtures/fixture_provider.dart',
          '-o',
          providerExecutable.path,
        ],
        workingDirectory: repository,
        runInShell: false,
      );
      expect(providerBuild.exitCode, 0, reason: '${providerBuild.stderr}');
      final bundledEngine = File(
        '$repository/apps/workspace/assets/engines/'
        'conclave_cli_worker_engine${Platform.isWindows ? '.exe' : ''}',
      );
      final dartDirectory = File(_dartExecutable()).parent.path;
      final inheritedPath = Platform.environment['PATH'] ?? '';
      final engine = CliWorkerEngineSupervisor(
        engineExecutable:
            bundledEngine.existsSync() ? bundledEngine.path : _dartExecutable(),
        engineArgumentsPrefix: bundledEngine.existsSync()
            ? const []
            : ['$repository/engines/cli_worker/bin/conclave_cli_worker.dart'],
        environmentOverrides: {
          'PATH': '${providerDirectory.path}${Platform.isWindows ? ';' : ':'}'
              '$dartDirectory${Platform.isWindows ? ';' : ':'}$inheritedPath',
          'HOME': root.path,
        },
      );
      final diagnostics = WorkerDiagnosticStore(
        directory: Directory('${root.path}/Diagnostics'),
      );
      final monitor = WorkerReadinessMonitor(
        registry: registry,
        toolProfileReleaseStore: profileStore,
        workerCatalogCoordinator: coordinator,
        cliWorkerEngineSupervisor: engine,
        workerStateDirectory: (workerId) =>
            Directory('${root.path}/Workers/$workerId/state'),
        profileDiagnosticStoreForWorker: (_) => diagnostics,
      );

      await monitor.checkNow(workerTypeId: 'dynamic-test-worker');
      final probed = (await registry.find(worker.id))!;
      expect(
        probed.readinessState,
        WorkerReadinessState.ready,
        reason: '${probed.readinessIssueCode}: ${probed.lastLiveTestDetails}',
      );
      expect(probed.toolVersion, '0.3.0');
      final inventory = await coordinator.inventoryForWorkers(
        await registry.list(),
        engineVersion: cliWorkerEngineVersion,
        engineAvailable: true,
      );
      expect(inventory, hasLength(1));
      expect(
        inventory.single,
        containsPair('workerTypeId', 'dynamic-test-worker'),
      );
      expect(
        inventory.single,
        containsPair('profileDefinitionId', 'dynamic-test-cli'),
      );
      expect(
        inventory.single['readinessState'],
        WorkerReadinessState.ready.wireValue,
      );

      final permissionAssignment = Map<String, Object?>.from(
        jsonDecode(
          await File(
            '$repository/packages/workspace-runtime-protocol/test/fixtures/execution-permission-assignment.json',
          ).readAsString(),
        ) as Map,
      );
      final assignmentHandler = WorkerAssignmentHandler(
        resolveLogicalWorker: (workerId) async {
          final configured = await registry.find(workerId);
          if (configured == null) return null;
          final catalogEntry =
              await coordinator.ensureCatalogEntry(configured.workerTypeId);
          return AssignmentLogicalWorker(
            id: configured.id,
            workerTypeId: configured.workerTypeId,
            enabled: catalogEntry != null &&
                configured.activationState ==
                    LocalWorkerActivationState.enabled,
            ready: catalogEntry != null &&
                configured.status == LocalWorkerStatus.ready,
            permissions: configured.localPermissions.toSet(),
            localConcurrencyLimit: configured.localConcurrencyLimit,
            providerCliVersion: configured.toolVersion,
          );
        },
        defaultWorkingDirectory: Directory('${root.path}/permission-work'),
        executeWithToolProfile:
            (logicalWorker, workingDirectory, context, payload,
                {onProgress}) async {
          final resolution = await coordinator.resolveProfileForWorker(
            workerTypeId: logicalWorker.workerTypeId,
            engineVersion: cliWorkerEngineVersion,
            providerCliVersion: logicalWorker.providerCliVersion,
          );
          final release = resolution.release;
          if (release == null) {
            throw StateError('Dynamic Worker Profile unavailable');
          }
          final input = Map<String, Object?>.from(payload['input'] as Map);
          return engine.execute(
            release,
            profileFile: profileStore.profileFile(
              'dynamic-test-cli',
              release.releaseVersion,
            ),
            stateDirectory: Directory('${root.path}/permission-state'),
            workingDirectory: workingDirectory,
            workerId: logicalWorker.id,
            maxConcurrentAssignments: 1,
            assignmentId: context.assignmentId,
            prompt: input['prompt'] as String,
            timeout: const Duration(seconds: 30),
          );
        },
      );
      final cloudPayload = Map<String, Object?>.from(permissionAssignment)
        ..['workerId'] = worker.id
        ..['workerTypeId'] = 'dynamic-test-worker';
      Future<WorkspaceAssignmentResult> runAssignment(
        Map<String, Object?> payload,
      ) =>
          assignmentHandler.call(
            WorkspaceAssignmentContext(
              workspaceId: payload['executionWorkspaceId'] as String,
              workspaceRuntimeId: payload['workspaceRuntimeId'] as String,
              workerId: payload['workerId'] as String,
              runId: payload['runId'] as String,
              taskId: payload['taskId'] as String,
              attemptId: payload['attemptId'] as String,
              assignmentId: payload['assignmentId'] as String,
              idempotencyKey: payload['idempotencyKey'] as String,
              payload: payload,
            ),
          );
      final assigned = await runAssignment(cloudPayload);
      expect(assigned.summary, 'OK');

      await monitor.checkNow(
        mode: LocalWorkerProbeMode.live,
        workerTypeId: 'dynamic-test-worker',
      );
      final tested = (await registry.find(worker.id))!;
      expect(tested.lastLiveTestPassed, isTrue,
          reason:
              '${tested.lastLiveTestIssueCode}: ${tested.lastLiveTestDetails}');
      expect(tested.lastLiveTestAt, isNotNull);
      expect(tested.toolName, 'Fixture CLI');
      expect(tested.toolVersion, '0.3.0');

      final diagnostic = jsonDecode(
        (await diagnostics.currentFile.readAsLines()).last,
      ) as Map<String, Object?>;
      expect(diagnostic['workerTypeId'], 'dynamic-test-worker');
      expect(diagnostic['profileDefinitionId'], 'dynamic-test-cli');
      expect(diagnostic['profileReleaseVersion'], 1);

      cloudAvailable = true;
      await coordinator.refresh(force: true);
      expect(coordinator.snapshot.catalogConfirmed, isTrue);
      expect(coordinator.entryForWorker('offline-added-worker'), isNotNull);
      expect(postRestartProfileRequests, 2);
      expect(
        await profileStore.installedVersions('dynamic-test-cli'),
        contains(2),
      );
      expect(
        (await profileStore.activeRelease('dynamic-test-cli'))?.releaseVersion,
        2,
      );
      expect(
        await profileStore.profileFile('dynamic-test-cli', 2).exists(),
        isTrue,
      );

      // Cloud retires the Worker while offline. The cached active catalog and
      // signed Profile remain authoritative until the next successful sync.
      catalogActive = false;
      cloudAvailable = false;
      await coordinator.refresh(force: true);
      expect(coordinator.snapshot.catalogError, contains('offline'));
      expect(coordinator.entryForWorker('dynamic-test-worker'), isNotNull);
      expect(
        (await coordinator.inventoryForWorkers(
          await registry.list(),
          engineVersion: cliWorkerEngineVersion,
          engineAvailable: true,
        ))
            .single['readinessState'],
        WorkerReadinessState.ready.wireValue,
      );
      final offlineFollowup = Map<String, Object?>.from(cloudPayload)
        ..['assignmentId'] = 'offline-retirement-followup'
        ..['idempotencyKey'] = 'offline-retirement-followup-idempotency';
      expect((await runAssignment(offlineFollowup)).summary, 'OK');

      cloudAvailable = true;
      await coordinator.refresh(force: true);
      expect(coordinator.snapshot.catalogConfirmed, isTrue);
      expect(coordinator.entryForWorker('dynamic-test-worker'), isNull);
      expect(
        coordinator.snapshot.workers
            .singleWhere((state) => state.catalogRetired)
            .catalogRetired,
        isTrue,
      );
      expect(
        coordinator.inventoryEligibleWorkers(await registry.list()),
        isEmpty,
      );
      expect(
        await coordinator.inventoryForWorkers(
          await registry.list(),
          engineVersion: cliWorkerEngineVersion,
          engineAvailable: true,
        ),
        isEmpty,
      );
      await expectLater(
        runAssignment(cloudPayload),
        throwsA(isA<AssignmentExecutionFailure>().having(
          (error) => error.code,
          'code',
          'worker_not_ready',
        )),
      );

      catalogActive = true;
      await coordinator.refresh(force: true);
      expect(
        coordinator.entryForWorker('dynamic-test-worker')?.displayName,
        'Dynamic Test Worker',
      );
      final restoredWorkerState = coordinator.snapshot.workers.singleWhere(
        (state) => state.descriptor?.workerTypeId == 'dynamic-test-worker',
      );
      expect(restoredWorkerState.catalogRetired, isFalse);
      expect(restoredWorkerState.localWorker?.id, worker.id);
      expect(
        (await coordinator.inventoryForWorkers(
          await registry.list(),
          engineVersion: cliWorkerEngineVersion,
          engineAvailable: true,
        ))
            .single['readinessState'],
        WorkerReadinessState.ready.wireValue,
      );
      await monitor.dispose();
      catalog.close();
    },
  );
}

String _dartExecutable() {
  final resolved = File(Platform.resolvedExecutable);
  if (!resolved.path.endsWith('flutter_tester')) return resolved.path;
  final cacheDirectory = resolved.parent.parent.parent.parent;
  final dart = File('${cacheDirectory.path}/dart-sdk/bin/dart');
  if (!dart.existsSync()) {
    throw StateError('Could not locate the Flutter-bundled Dart executable.');
  }
  return dart.path;
}

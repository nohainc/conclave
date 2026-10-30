import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';

import 'package:syntila_workspace/tool_profile_catalog.dart';
import 'package:syntila_workspace/worker_profile_store.dart';
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'package:syntila_workspace/worker_catalog_coordinator.dart';
import 'package:syntila_workspace/workspace_worker_view.dart';
import 'package:syntila_workspace/cli_worker_engine_supervisor.dart';

import 'support/ed25519_release_fixture.dart';
import 'support/worker_profile_fixture.dart';

void main() {
  late Directory directory;
  late Ed25519ReleaseFixture signing;
  late WorkerProfileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('worker-catalog-');
    signing = await Ed25519ReleaseFixture.create();
    store = WorkerProfileStore(
      profilesRoot: Directory('${directory.path}/Profiles'),
      trustPolicy: signing.trustPolicy,
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  const descriptor = {
    'workerTypeId': 'fixture-cli',
    'displayName': 'Fixture CLI',
    'description': 'Controller pipeline test',
    'profileDefinitionId': 'fixture-profile',
    'providerToolName': 'fixture',
    'engineFamily': 'cli',
    'visibilityState': 'visible',
    'releaseStage': 'stable',
    'sortOrder': 1,
  };

  test('downloads a Profile only after the Worker is added', () async {
    final candidate = await _snapshot(
        signing,
        buildTestWorkerProfile(
          profileDefinitionId: 'fixture-profile',
          logicalWorkerTypeId: 'fixture-cli',
        ),
        revision: 1);
    final registry = LocalWorkerRegistry(
      dataDirectory: Directory('${directory.path}/workspace'),
      workspaceId: 'workspace-fixture',
    );
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      currentProfileLoader: (_) async => candidate,
      trustRefresher: () async {},
      candidateValidator: (_, __) async => (await registry.list()).isNotEmpty,
    );
    addTearDown(catalog.close);
    final controller = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
      registry: registry,
    );
    addTearDown(controller.dispose);

    await controller.refresh(force: true);

    // Catalog entries the user has not added are display metadata only.
    expect(await registry.list(), isEmpty);
    expect(await store.hasWorkerProfileCache('fixture-cli'), isFalse);
    expect(controller.snapshot.workers.single.localWorker, isNull);

    await registry.create(catalogEntry: WorkerDescriptor.fromJson(descriptor));
    await controller.refreshWorker('fixture-cli');
    expect((await store.currentWorkerProfile('fixture-cli'))?.revision, 1);
    expect(controller.snapshot.workers.single.profileState,
        WorkspaceWorkerProfileState.ready);
  });

  test('missing CLI preserves staged Profile and reports activation cause',
      () async {
    final candidate = await _snapshot(
        signing,
        buildTestWorkerProfile(
          profileDefinitionId: 'fixture-profile',
          logicalWorkerTypeId: 'fixture-cli',
        ),
        revision: 1);
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      currentProfileLoader: (_) async => candidate,
      trustRefresher: () async {},
      candidateValidator: (_, __) async =>
          throw const WorkerProfileProbeFailure('provider_tool_unavailable'),
    );
    addTearDown(catalog.close);
    final registry = LocalWorkerRegistry(
      dataDirectory: Directory('${directory.path}/workspace'),
      workspaceId: 'workspace-fixture',
    );
    final local = await registry.create(
        catalogEntry: WorkerDescriptor.fromJson(descriptor));
    final controller = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
      registry: registry,
    );
    addTearDown(controller.dispose);
    await controller.refresh(force: true);
    expect(await store.currentWorkerProfile('fixture-cli'), isNull);
    expect(await store.hasWorkerProfileCache('fixture-cli'), isTrue);
    final view = controller.snapshot.workers.single;
    expect(view.availabilityLabel, 'Provider CLI not found');
    expect(view.availabilityDetail,
        contains('Profile downloaded; activation blocked'));
    expect(view.issueCode, 'provider_tool_unavailable');
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      toolProfileReleaseStore: store,
      workerCatalogCoordinator: controller,
      cliWorkerEngineSupervisor:
          CliWorkerEngineSupervisor(engineExecutable: '/unused'),
      workerStateDirectory: (_) => Directory('${directory.path}/worker'),
    );
    addTearDown(monitor.dispose);
    await monitor.checkNow(includeDisabled: true);
    expect((await registry.find(local.id))!.readinessIssueCode,
        'provider_tool_unavailable');
  });

  test('refreshWorker syncs only the requested Worker Profile', () async {
    final otherDescriptor = {
      ...descriptor,
      'workerTypeId': 'fixture-cli-other',
      'displayName': 'Fixture CLI Other',
      'profileDefinitionId': 'fixture-profile-other',
      'sortOrder': 2,
    };
    var catalogLoads = 0;
    final profileLoads = <String>[];
    var readinessRuns = 0;
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async {
        catalogLoads++;
        return [descriptor, otherDescriptor];
      },
      currentProfileLoader: (workerTypeId) async {
        profileLoads.add(workerTypeId);
        throw StateError('no published Profile in this test');
      },
      trustRefresher: () async {},
    );
    addTearDown(catalog.close);
    final controller = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
      refreshReadiness: () async => readinessRuns++,
    );
    addTearDown(controller.dispose);

    await controller.refreshWorker('fixture-cli');

    expect(catalogLoads, 1);
    expect(profileLoads, ['fixture-cli']);
    expect(readinessRuns, 0, reason: 'no all-Worker readiness sweep');
    expect(controller.snapshot.catalogConfirmed, isTrue);
    expect(
      controller.snapshot.workers
          .map((worker) => worker.descriptor?.workerTypeId),
      containsAll(['fixture-cli', 'fixture-cli-other']),
    );
  });

  test('renders cached catalog before refresh and runs one canonical pipeline',
      () async {
    const secondDescriptor = {
      'workerTypeId': 'fixture-cli-two',
      'displayName': 'Fixture CLI Two',
      'description': 'Controller pipeline test',
      'profileDefinitionId': 'fixture-profile-two',
      'providerToolName': 'fixture-two',
      'engineFamily': 'cli',
      'visibilityState': 'visible',
      'releaseStage': 'stable',
      'sortOrder': 2,
    };
    final seedCatalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor, secondDescriptor],
      trustRefresher: () async {},
    );
    await seedCatalog.syncCatalog();
    seedCatalog.close();

    final cloudCatalog = Completer<List<Object?>>();
    final order = <String>[];
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () {
        order.add('catalog');
        return cloudCatalog.future;
      },
      trustRefresher: () async => order.add('trust'),
    );
    final readinessRefreshed = Completer<void>();
    final controller = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
      refreshReadiness: () async {
        order.add('readiness');
        if (!readinessRefreshed.isCompleted) readinessRefreshed.complete();
      },
    );
    final cachedCatalogPublished = Completer<void>();
    controller.addListener(() {
      if (controller.snapshot.workers.isNotEmpty &&
          !cachedCatalogPublished.isCompleted) {
        cachedCatalogPublished.complete();
      }
    });

    final refresh = controller.refresh(force: true);
    await cachedCatalogPublished.future.timeout(const Duration(seconds: 2));
    expect(
      controller.snapshot.descriptors.map((worker) => worker.workerTypeId),
      ['fixture-cli', 'fixture-cli-two'],
    );
    expect(controller.snapshot.refreshing, isTrue);

    cloudCatalog.complete([descriptor, secondDescriptor]);
    await refresh;
    await readinessRefreshed.future;

    expect(
      order,
      [
        'catalog',
        // Both Workers in one pass share a single release-trust refresh.
        'trust',
        'readiness',
      ],
    );
    expect(controller.snapshot.catalogConfirmed, isTrue);
    expect(controller.snapshot.refreshing, isFalse);
  });

  test(
      'startup readiness and catalog refresh complete when a Worker has no release',
      () async {
    final registry = LocalWorkerRegistry(
        dataDirectory: Directory('${directory.path}/Registry'),
        workspaceId: 'workspace-startup');
    await registry.create(catalogEntry: WorkerDescriptor.fromJson(descriptor));
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      trustRefresher: () async {},
    );
    await catalog.syncCatalog();
    late WorkerReadinessMonitor monitor;
    final coordinator = WorkerCatalogCoordinator(
        catalog: catalog,
        releaseStore: store,
        registry: registry,
        refreshReadiness: () => monitor.checkNow(rerunWhenActive: true));
    monitor = WorkerReadinessMonitor(
        registry: registry,
        toolProfileReleaseStore: store,
        workerCatalogCoordinator: coordinator,
        cliWorkerEngineSupervisor:
            CliWorkerEngineSupervisor(engineExecutable: '/unused-engine'),
        workerStateDirectory: (id) =>
            Directory('${directory.path}/Workers/$id/state'));
    try {
      await Future.wait([
        coordinator.refresh(force: true),
        monitor.checkNow(),
      ]).timeout(const Duration(seconds: 2));
      expect((await registry.list()).single.readinessIssueCode,
          'tool_profile_unavailable');
      expect(coordinator.snapshot.refreshing, isFalse);
    } finally {
      await monitor.dispose();
      coordinator.dispose();
      catalog.close();
    }
  });

  test('keeps verified cached catalog and Worker Profile when Cloud is offline',
      () async {
    final profile = buildTestWorkerProfile(
      profileDefinitionId: 'fixture-profile',
      logicalWorkerTypeId: 'fixture-cli',
    );
    final current = await _snapshot(signing, profile, revision: 1);
    await store.activateWorkerProfile(
      await store.stageWorkerProfile(current),
    );

    final seedCatalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      trustRefresher: () async {},
    );
    await seedCatalog.syncCatalog();
    seedCatalog.close();

    final registry = LocalWorkerRegistry(
      dataDirectory: Directory('${directory.path}/workspace'),
      workspaceId: 'workspace-fixture',
    );
    await registry.create(catalogEntry: WorkerDescriptor.fromJson(descriptor));

    final offlineCatalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => throw const SocketException('offline'),
      trustRefresher: () async => throw const SocketException('offline'),
    );
    final controller = WorkerCatalogCoordinator(
      catalog: offlineCatalog,
      releaseStore: store,
      registry: registry,
    );

    await controller.refresh(force: true);

    expect(controller.snapshot.descriptors.map((worker) => worker.workerTypeId),
        ['fixture-cli']);
    expect(controller.snapshot.catalogConfirmed, isFalse);
    expect(controller.snapshot.catalogError, contains('offline'));
    expect(controller.snapshot.profiles['fixture-cli']?.state,
        WorkspaceWorkerProfileState.ready);
    expect((await registry.list()).single.workerTypeId, 'fixture-cli');
    offlineCatalog.close();
    controller.dispose();
  });

  test('keeps cached catalog without runtime identity while disconnected',
      () async {
    final seedCatalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      trustRefresher: () async {},
    );
    await seedCatalog.syncCatalog();
    seedCatalog.close();

    final disconnectedCatalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
    );
    final controller = WorkerCatalogCoordinator(
      catalog: disconnectedCatalog,
      releaseStore: store,
    );

    await controller.refresh(force: true);

    expect(
      controller.snapshot.descriptors.map((worker) => worker.workerTypeId),
      ['fixture-cli'],
    );
    expect(controller.snapshot.catalogConfirmed, isFalse);
    expect(controller.snapshot.catalogError, isNull);

    disconnectedCatalog.close();
    controller.dispose();
  });

  test('shows redacted download failure when no cached Profile exists',
      () async {
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      trustRefresher: () async =>
          throw StateError('release trust refresh failed with HTTP 500'),
    );
    final controller =
        WorkerCatalogCoordinator(catalog: catalog, releaseStore: store);
    await controller.refresh(force: true);
    expect(controller.snapshot.profiles['fixture-cli']?.state,
        WorkspaceWorkerProfileState.error);
    expect(controller.snapshot.profiles['fixture-cli']?.message,
        contains('HTTP 500'));
    catalog.close();
    controller.dispose();
  });

  test('reconciles additions, metadata, retirement, and Worker restoration',
      () async {
    final registry = LocalWorkerRegistry(
      dataDirectory: Directory('${directory.path}/workspace'),
      workspaceId: 'workspace-fixture',
      idGenerator: () => 'local-fixture-worker',
    );
    final originalWorker = await registry.create(
      catalogEntry: WorkerDescriptor.fromJson(descriptor),
    );
    var remoteDescriptors = <Object?>[descriptor];
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => remoteDescriptors,
      trustRefresher: () async {},
    );
    final controller = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
      registry: registry,
    );

    await controller.refresh(force: true);
    expect(controller.snapshot.catalogConfirmed, isTrue);

    const addedDescriptor = {
      'workerTypeId': 'claude',
      'displayName': 'Claude',
      'description': 'Claude Code CLI integration',
      'profileDefinitionId': 'claude-code',
      'providerToolName': 'claude',
      'engineFamily': 'cli',
      'visibilityState': 'visible',
      'releaseStage': 'testing',
      'sortOrder': 2,
    };
    remoteDescriptors = [descriptor, addedDescriptor];
    await controller.refresh(force: true);
    expect(controller.snapshot.descriptors.map((worker) => worker.workerTypeId),
        ['fixture-cli', 'claude']);
    final claudeState = controller.snapshot.workers
        .singleWhere((state) => state.descriptor?.workerTypeId == 'claude');
    expect(claudeState.localWorker, isNull);
    // Not added to this Workspace, so its Profile is never downloaded.
    expect(await store.hasWorkerProfileCache('claude'), isFalse);
    expect(claudeState.readiness, isNull);
    expect((await registry.list()).map((worker) => worker.workerTypeId),
        ['fixture-cli']);

    final changedOriginal = {
      ...descriptor,
      'displayName': 'Fixture CLI Updated',
      'description': 'Updated catalog metadata',
      'profileDefinitionId': 'fixture-profile-v2',
      'providerToolName': 'fixture-next',
      'sortOrder': 3,
    };
    remoteDescriptors = [changedOriginal, addedDescriptor];
    await controller.refresh(force: true);
    final changed = controller.snapshot.descriptors
        .firstWhere((worker) => worker.workerTypeId == 'fixture-cli');
    expect(changed.displayName, 'Fixture CLI Updated');
    expect(changed.profileDefinitionId, 'fixture-profile-v2');
    expect(changed.providerToolName, 'fixture-next');
    expect(
        (await registry.find(originalWorker.id))?.workerTypeId, 'fixture-cli');

    remoteDescriptors = [addedDescriptor];
    await controller.refresh(force: true);
    expect(controller.snapshot.descriptors.map((worker) => worker.workerTypeId),
        ['claude']);
    expect(await controller.ensureCatalogEntry('fixture-cli'), isNull);
    expect((await registry.list()).single.id, originalWorker.id);
    expect(controller.inventoryEligibleWorkers(await registry.list()), isEmpty);
    final workerStates = controller.snapshot.workers;
    expect(workerStates, hasLength(2));
    expect(
      workerStates.singleWhere((state) => state.catalogRetired).localWorker?.id,
      originalWorker.id,
    );
    expect(
      workerStates
          .singleWhere((state) => !state.catalogRetired)
          .descriptor
          ?.workerTypeId,
      'claude',
    );
    expect(
      workerStates.singleWhere((state) => state.catalogRetired).readiness,
      originalWorker.readinessState,
    );
    var readinessProbeCalls = 0;
    final readiness = WorkerReadinessMonitor(
      registry: registry,
      workerCatalogCoordinator: controller,
      assessWorker: (_) async {
        readinessProbeCalls++;
        return const WorkerReadinessAssessment(WorkerReadinessState.ready);
      },
    );
    await readiness.checkNow();
    expect(readinessProbeCalls, 0);
    await readiness.dispose();

    remoteDescriptors = [changedOriginal, addedDescriptor];
    await controller.refresh(force: true);
    expect((await controller.ensureCatalogEntry('fixture-cli'))?.displayName,
        'Fixture CLI Updated');
    expect((await registry.list()).map((worker) => worker.id),
        [originalWorker.id]);
    expect(controller.inventoryEligibleWorkers(await registry.list()),
        hasLength(1));

    controller.dispose();
    catalog.close();
  });
}

Future<WorkerProfileSnapshotAdmission> _snapshot(
  Ed25519ReleaseFixture signing,
  Map<String, Object?> profile, {
  required int revision,
}) async {
  final digest = sha256.convert(utf8.encode(canonicalJson(profile))).toString();
  return WorkerProfileSnapshotAdmission(
    profile: profile,
    workerTypeId: 'fixture-cli',
    revision: revision,
    payloadDigest: digest,
  );
}

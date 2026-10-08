import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:conclave_workspace/workspace_worker_view.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Directory directory;
  late Ed25519ReleaseFixture signing;
  late ToolProfileReleaseStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('worker-catalog-');
    signing = await Ed25519ReleaseFixture.create();
    store = ToolProfileReleaseStore(
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
    'capabilities': ['text'],
    'sortOrder': 1,
  };

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
      'capabilities': ['text'],
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
      listLoader: (workerTypeId, channel) async {
        order.add('profiles:$workerTypeId');
        return ToolProfileCatalogResult(channel: channel, releases: const []);
      },
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
        'trust',
        'profiles:fixture-cli',
        'trust',
        'profiles:fixture-cli-two',
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
    final syncEntered = Completer<void>();
    final finishSync = Completer<void>();
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      trustRefresher: () async {},
      listLoader: (_, channel) async {
        if (!syncEntered.isCompleted) syncEntered.complete();
        await finishSync.future;
        return ToolProfileCatalogResult(channel: channel, releases: const []);
      },
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
      final refresh = coordinator.refresh(force: true);
      await syncEntered.future;
      final readiness = monitor.checkNow();
      await Future<void>.delayed(Duration.zero);
      finishSync.complete();
      await Future.wait([refresh, readiness])
          .timeout(const Duration(seconds: 2));
      expect((await registry.list()).single.readinessIssueCode,
          'tool_profile_unavailable');
      expect(coordinator.snapshot.refreshing, isFalse);
    } finally {
      await monitor.dispose();
      coordinator.dispose();
      catalog.close();
    }
  });

  test('keeps verified cached catalog and signed Profile when Cloud is offline',
      () async {
    final releaseProfile = jsonDecode(
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
    releaseProfile['profileDefinitionId'] = 'fixture-profile';
    releaseProfile['logicalWorkerTypeId'] = 'fixture-cli';
    final release = <String, Object?>{
      'profileDefinitionId': 'fixture-profile',
      'workerTypeId': 'fixture-cli',
      'displayName': 'Fixture CLI',
      'providerToolName': 'Fixture CLI',
      'channel': 'stable',
      'releaseVersion': 1,
      'profile': releaseProfile,
      'schemaVersion': releaseProfile['schemaVersion'],
      'engineFamily': releaseProfile['engineFamily'],
      'engineCompatibility': releaseProfile['engineCompatibility'],
    };
    await signing.signToolProfileRelease(release);
    await store.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'fixture-cli',
    );
    await store.activateVersion('fixture-profile', 1, selectAsStable: true);

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

  test('force refresh applies the current Cloud Profile channel', () async {
    final profile = jsonDecode(
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
    profile['profileDefinitionId'] = 'fixture-profile';
    profile['logicalWorkerTypeId'] = 'fixture-cli';
    final release = <String, Object?>{
      'profileDefinitionId': 'fixture-profile',
      'workerTypeId': 'fixture-cli',
      'displayName': 'Fixture CLI',
      'providerToolName': 'Fixture CLI',
      'channel': 'stable',
      'releaseVersion': 1,
      'profile': profile,
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
    };
    await signing.signToolProfileRelease(release);
    await store.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'fixture-cli',
    );
    await store.activateVersion('fixture-profile', 1, selectAsStable: true);

    var remoteChannel = 'stable';
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [descriptor],
      trustRefresher: () async {},
      listLoader: (workerTypeId, channel) async => ToolProfileCatalogResult(
        channel: remoteChannel,
        releases: const [],
      ),
    );
    final controller = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
    );
    addTearDown(catalog.close);
    addTearDown(controller.dispose);

    expect(controller.refreshInterval, const Duration(minutes: 10));
    expect(controller.minimumRefreshInterval, const Duration(minutes: 1));

    await controller.refresh(force: true);
    expect(
      (await store.releaseState('fixture-profile')).selectedChannel,
      'stable',
    );

    remoteChannel = 'beta';
    await controller.refresh(force: true);
    expect(
      (await store.releaseState('fixture-profile')).selectedChannel,
      'beta',
    );
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
      listLoader: (workerTypeId, channel) async =>
          ToolProfileCatalogResult(channel: channel, releases: const []),
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
      'capabilities': ['text'],
      'sortOrder': 2,
    };
    remoteDescriptors = [descriptor, addedDescriptor];
    await controller.refresh(force: true);
    expect(controller.snapshot.descriptors.map((worker) => worker.workerTypeId),
        ['fixture-cli', 'claude']);
    final claudeState = controller.snapshot.workers
        .singleWhere((state) => state.descriptor?.workerTypeId == 'claude');
    expect(claudeState.localWorker, isNull);
    expect(claudeState.profileAvailability.state,
        WorkspaceWorkerProfileState.unavailable);
    expect(claudeState.readiness, isNull);
    expect((await registry.list()).map((worker) => worker.workerTypeId),
        ['fixture-cli']);

    final changedOriginal = {
      ...descriptor,
      'displayName': 'Fixture CLI Updated',
      'description': 'Updated catalog metadata',
      'profileDefinitionId': 'fixture-profile-v2',
      'providerToolName': 'fixture-next',
      'capabilities': ['text', 'thread_read'],
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

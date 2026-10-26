import 'dart:io';

import 'package:test/test.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/release_trust_roots.dart';
import 'package:conclave_workspace/worker_profile_store.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/workspace_worker_subsystem.dart';

import 'support/logical_worker_catalog_fixture.dart';

void main() {
  test('routes Worker lifecycle operations through one subsystem boundary',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('workspace-workers-');
    addTearDown(() => directory.delete(recursive: true));
    final registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      idGenerator: () => 'worker-1',
    );
    final created = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
    );
    final readiness = WorkerReadinessMonitor(
      registry: registry,
      assessWorker: (_) async => const WorkerReadinessAssessment(
        WorkerReadinessState.ready,
        toolName: 'fixture-cli',
      ),
    );
    final subsystem = WorkspaceWorkerSubsystem(
      registry: registry,
      releaseStore: WorkerProfileStore(
        profilesRoot: Directory('${directory.path}/profiles'),
        trustPolicy: workspaceReleaseTrustPolicy(),
      ),
      readiness: readiness,
    );

    expect((await subsystem.listWorkers()).single.id, created.id);
    final enabled = await subsystem.enableWorker(created.id);
    expect(enabled.activationState, LocalWorkerActivationState.enabled);
    expect(enabled.readinessState, WorkerReadinessState.ready);

    final tested = await subsystem.testWorker(created.id);
    expect(tested!.lastLiveTestPassed, isTrue);

    final disabled = await subsystem.disableWorker(created.id);
    expect(disabled!.activationState, LocalWorkerActivationState.disabled);
    expect(disabled.status, LocalWorkerStatus.disabled);
  });

  group('removeWorker', () {
    late Directory directory;
    late LocalWorkerRegistry registry;
    late WorkerReadinessMonitor readiness;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('workspace-remove-');
      registry = LocalWorkerRegistry(
        dataDirectory: directory,
        workspaceId: 'workspace-1',
        idGenerator: () => 'worker-1',
      );
      readiness = WorkerReadinessMonitor(
        registry: registry,
        assessWorker: (_) async =>
            const WorkerReadinessAssessment(WorkerReadinessState.ready),
      );
    });
    tearDown(() async {
      await readiness.dispose();
      await directory.delete(recursive: true);
    });

    WorkspaceWorkerSubsystem subsystemWith(int Function() pending) =>
        WorkspaceWorkerSubsystem(
          registry: registry,
          releaseStore: WorkerProfileStore(
            profilesRoot: Directory('${directory.path}/profiles'),
            trustPolicy: workspaceReleaseTrustPolicy(),
          ),
          readiness: readiness,
          workerStateDirectory: (id) => Directory('${directory.path}/w/$id'),
          pendingAssignmentsFor: (_) => pending(),
          removalPollInterval: const Duration(milliseconds: 10),
        );

    test('removes an idle Worker and its Engine state at once', () async {
      final worker = await registry.create(
        catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      );
      final state = Directory('${directory.path}/w/${worker.id}');
      await state.create(recursive: true);
      final subsystem = subsystemWith(() => 0);

      expect(await subsystem.removeWorker(worker.id), isTrue);
      expect(await registry.list(), isEmpty);
      expect(await state.exists(), isFalse);
      expect(subsystem.removingWorkerIds, isEmpty);
    });

    test('waits for running work, taking no new work meanwhile', () async {
      final worker = await registry.create(
        catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      );
      await registry.update(
        worker.id,
        (current) => current.copyWith(
            activationState: LocalWorkerActivationState.enabled),
      );
      var pending = 1;
      final subsystem = subsystemWith(() => pending);

      expect(await subsystem.removeWorker(worker.id), isFalse);
      expect(subsystem.isRemoving(worker.id), isTrue);
      final waiting = (await registry.find(worker.id))!;
      expect(waiting.activationState, LocalWorkerActivationState.disabled);
      // A repeated request joins the pending removal.
      expect(await subsystem.removeWorker(worker.id), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(await registry.find(worker.id), isNotNull);

      pending = 0;
      await subsystem.removalDone(worker.id);
      expect(await registry.list(), isEmpty);
      expect(subsystem.isRemoving(worker.id), isFalse);
    });
  });
}

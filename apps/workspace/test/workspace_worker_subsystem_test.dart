import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/release_trust_roots.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
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
      releaseStore: ToolProfileReleaseStore(
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
}

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_protocol/worker_descriptor.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/workspace_worker_view.dart';

void main() {
  const descriptor = WorkerDescriptor(
    workerTypeId: 'future-cli',
    displayName: 'Future CLI',
    description: 'A catalog-provided Worker used by this test.',
    profileDefinitionId: 'future-cli-profile',
    providerToolName: 'future',
    engineFamily: 'cli',
    visibilityState: 'visible',
    releaseStage: 'testing',
    capabilities: ['text'],
    sortOrder: 1,
  );

  WorkerCatalogWorkerState view({
    bool catalogRetired = false,
    LocalWorker? worker,
    WorkspaceLocalWorkerState localState =
        WorkspaceLocalWorkerState.notConfigured,
    WorkspaceWorkerProfileState profileState =
        WorkspaceWorkerProfileState.ready,
    WorkspaceProviderToolState providerToolState =
        WorkspaceProviderToolState.unknown,
    WorkerDescriptor? workerDescriptor = descriptor,
  }) =>
      WorkerCatalogWorkerState(
        descriptor: workerDescriptor,
        catalogRetired: catalogRetired,
        localWorker: worker,
        localState: localState,
        profileAvailability: WorkerProfileResolution(state: profileState),
        providerToolState: providerToolState,
      );

  LocalWorker localWorker({
    LocalWorkerActivationState activationState =
        LocalWorkerActivationState.enabled,
    WorkerReadinessState readinessState = WorkerReadinessState.ready,
    String? readinessIssueCode,
    String? lastLiveTestIssueCode,
    String? toolVersion = '1.0.0',
  }) =>
      LocalWorker(
        id: 'local-future-cli',
        workspaceId: 'workspace-1',
        workerTypeId: descriptor.workerTypeId,
        localPermissions: const [],
        localConcurrencyLimit: 1,
        status: LocalWorkerStatus.ready,
        activationState: activationState,
        readinessState: readinessState,
        revision: 1,
        createdAt: '2026-10-01T00:00:00Z',
        updatedAt: '2026-10-01T00:00:00Z',
        readinessIssueCode: readinessIssueCode,
        lastLiveTestIssueCode: lastLiveTestIssueCode,
        toolVersion: toolVersion,
      );

  test('separates catalog presence from local Worker setup', () {
    final workerView = view();

    expect(workerView.catalogAvailable, isTrue);
    expect(workerView.localWorker, isNull);
    expect(workerView.state, WorkspaceWorkerState.setupRequired);
    expect(workerView.state.label, 'Setup required');
  });

  test('reports Profile sync independently while no local Worker exists', () {
    final workerView = view(
      profileState: WorkspaceWorkerProfileState.syncing,
    );

    expect(workerView.localWorker, isNull);
    expect(workerView.state, WorkspaceWorkerState.profileSyncing);
    expect(workerView.state.label, 'Preparing integration…');
  });

  test('reports catalog and Profile readiness as separate intermediate states',
      () {
    final resolving = view(
      profileState: WorkspaceWorkerProfileState.resolving,
    );
    final profileReady = view(
      worker: localWorker(readinessState: WorkerReadinessState.notProbed),
      localState: WorkspaceLocalWorkerState.configured,
      providerToolState: WorkspaceProviderToolState.unknown,
    );

    expect(resolving.state, WorkspaceWorkerState.catalogAvailable);
    expect(profileReady.state, WorkspaceWorkerState.profileReady);
  });

  test('reports a missing provider CLI for a configured Worker', () {
    final workerView = view(
      worker: localWorker(
        readinessState: WorkerReadinessState.runtimeUnavailable,
        readinessIssueCode: 'cli_not_found',
        toolVersion: null,
      ),
      localState: WorkspaceLocalWorkerState.configured,
      providerToolState: WorkspaceProviderToolState.missing,
    );

    expect(workerView.state, WorkspaceWorkerState.providerToolMissing);
  });

  test('reports Ready only when Profile, provider tool, and readiness agree',
      () {
    final workerView = view(
      worker: localWorker(),
      localState: WorkspaceLocalWorkerState.configured,
      profileState: WorkspaceWorkerProfileState.ready,
      providerToolState: WorkspaceProviderToolState.available,
    );

    expect(workerView.state, WorkspaceWorkerState.ready);
    expect(workerView.readiness, WorkerReadinessState.ready);
  });

  test('authentication failure takes precedence over generic readiness', () {
    final workerView = view(
      worker: localWorker(
        readinessState: WorkerReadinessState.signInRequired,
        readinessIssueCode: 'authentication_required',
      ),
      localState: WorkspaceLocalWorkerState.configured,
      providerToolState: WorkspaceProviderToolState.available,
    );

    expect(workerView.state, WorkspaceWorkerState.authenticationRequired);
  });

  test('disabled, incompatible, and retired states have explicit precedence',
      () {
    final disabled = view(
      worker: localWorker(
        activationState: LocalWorkerActivationState.disabled,
      ),
      localState: WorkspaceLocalWorkerState.configured,
    );
    final incompatible = view(
      profileState: WorkspaceWorkerProfileState.incompatible,
    );
    final retired = view(
      catalogRetired: true,
      workerDescriptor: null,
      worker: localWorker(),
      localState: WorkspaceLocalWorkerState.configured,
    );

    expect(disabled.state, WorkspaceWorkerState.disabled);
    expect(incompatible.state, WorkspaceWorkerState.incompatible);
    expect(retired.state, WorkspaceWorkerState.catalogRetired);
  });

  test('distinguishes unavailable Profile, runtime, and catalog states', () {
    expect(
      view(profileState: WorkspaceWorkerProfileState.unavailable).state,
      WorkspaceWorkerState.profileUnavailable,
    );
    expect(
      view(localState: WorkspaceLocalWorkerState.unavailable).state,
      WorkspaceWorkerState.runtimeUnavailable,
    );
    expect(
      view(workerDescriptor: null).state,
      WorkspaceWorkerState.catalogUnavailable,
    );
  });
}

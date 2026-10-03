import 'package:conclave_protocol/worker_descriptor.dart';

import 'local_worker_registry.dart';

class WorkerProfileResolution {
  const WorkerProfileResolution({
    required this.state,
    this.details,
    this.message,
  });

  final WorkspaceWorkerProfileState state;
  final Map<String, Object?>? details;
  final String? message;
}

enum WorkspaceWorkerState {
  catalogAvailable,
  catalogUnavailable,
  profileUnavailable,
  profileSyncing,
  profileReady,
  setupRequired,
  providerToolMissing,
  authenticationRequired,
  ready,
  disabled,
  incompatible,
  catalogRetired,
  runtimeUnavailable,
}

enum WorkspaceWorkerProfileState {
  resolving,
  syncing,
  ready,
  unavailable,
  incompatible,
  error,
}

enum WorkspaceLocalWorkerState {
  loading,
  notConfigured,
  configured,
  unavailable
}

enum WorkspaceProviderToolState { unknown, available, missing }

class WorkerCatalogWorkerState {
  const WorkerCatalogWorkerState({
    required this.descriptor,
    required this.catalogRetired,
    required this.localWorker,
    required this.localState,
    required this.profileAvailability,
    required this.providerToolState,
  });

  final WorkerDescriptor? descriptor;
  final bool catalogRetired;
  final LocalWorker? localWorker;
  final WorkspaceLocalWorkerState localState;
  final WorkerProfileResolution profileAvailability;
  final WorkspaceProviderToolState providerToolState;

  bool get catalogAvailable => descriptor != null && !catalogRetired;

  WorkerReadinessState? get readiness => localWorker?.readinessState;

  WorkspaceWorkerProfileState get profileState => profileAvailability.state;

  String get readinessLabel => localWorker == null
      ? switch (localState) {
          WorkspaceLocalWorkerState.loading => 'Resolving',
          WorkspaceLocalWorkerState.unavailable => 'Unavailable',
          WorkspaceLocalWorkerState.notConfigured => 'Setup required',
          WorkspaceLocalWorkerState.configured => 'Unavailable',
        }
      : deriveLocalWorkerReadiness(localWorker!);

  List<String> statusBadges({String? readinessLabelOverride}) {
    final worker = localWorker;
    if (worker == null) return [readinessLabelOverride ?? readinessLabel];
    return deriveLocalWorkerStatusBadges(
      worker,
      readinessLabel: readinessLabelOverride,
    );
  }

  WorkspaceWorkerState get state => deriveWorkspaceWorkerState(this);
}

WorkspaceWorkerState deriveWorkspaceWorkerState(WorkerCatalogWorkerState view) {
  if (view.catalogRetired) return WorkspaceWorkerState.catalogRetired;
  if (!view.catalogAvailable) return WorkspaceWorkerState.catalogUnavailable;
  if (view.localWorker?.activationState ==
      LocalWorkerActivationState.disabled) {
    return WorkspaceWorkerState.disabled;
  }
  if (view.profileState == WorkspaceWorkerProfileState.syncing) {
    return WorkspaceWorkerState.profileSyncing;
  }
  if (view.profileState == WorkspaceWorkerProfileState.incompatible) {
    return WorkspaceWorkerState.incompatible;
  }
  if (view.profileState == WorkspaceWorkerProfileState.unavailable ||
      view.profileState == WorkspaceWorkerProfileState.error) {
    return WorkspaceWorkerState.profileUnavailable;
  }
  if (view.localState == WorkspaceLocalWorkerState.loading ||
      view.profileState == WorkspaceWorkerProfileState.resolving) {
    return WorkspaceWorkerState.catalogAvailable;
  }
  if (view.localState == WorkspaceLocalWorkerState.unavailable) {
    return WorkspaceWorkerState.runtimeUnavailable;
  }
  if (view.localState == WorkspaceLocalWorkerState.notConfigured) {
    return view.profileState == WorkspaceWorkerProfileState.ready
        ? WorkspaceWorkerState.setupRequired
        : WorkspaceWorkerState.profileUnavailable;
  }

  final worker = view.localWorker;
  if (worker == null) return WorkspaceWorkerState.runtimeUnavailable;
  if (view.readiness == WorkerReadinessState.signInRequired ||
      worker.readinessIssueCode == 'authentication_required' ||
      worker.lastLiveTestIssueCode == 'authentication_required') {
    return WorkspaceWorkerState.authenticationRequired;
  }
  if (view.providerToolState == WorkspaceProviderToolState.missing ||
      worker.readinessIssueCode == 'cli_not_found' ||
      worker.lastLiveTestIssueCode == 'cli_not_found') {
    return WorkspaceWorkerState.providerToolMissing;
  }
  if (view.readiness == WorkerReadinessState.runtimeUnavailable ||
      view.readiness == WorkerReadinessState.testFailed) {
    return WorkspaceWorkerState.runtimeUnavailable;
  }
  if (view.readiness == WorkerReadinessState.setupRequired) {
    return WorkspaceWorkerState.setupRequired;
  }
  if (view.profileState == WorkspaceWorkerProfileState.ready &&
      view.providerToolState == WorkspaceProviderToolState.available &&
      view.readiness == WorkerReadinessState.ready) {
    return WorkspaceWorkerState.ready;
  }
  if (view.profileState == WorkspaceWorkerProfileState.ready) {
    return WorkspaceWorkerState.profileReady;
  }
  return WorkspaceWorkerState.catalogAvailable;
}

extension WorkspaceWorkerStateLabel on WorkspaceWorkerState {
  String get label => switch (this) {
        WorkspaceWorkerState.catalogAvailable => 'Catalog available',
        WorkspaceWorkerState.catalogUnavailable => 'Catalog unavailable',
        WorkspaceWorkerState.profileUnavailable => 'Profile unavailable',
        WorkspaceWorkerState.profileSyncing => 'Preparing integration…',
        WorkspaceWorkerState.profileReady => 'Profile ready',
        WorkspaceWorkerState.setupRequired => 'Setup required',
        WorkspaceWorkerState.providerToolMissing =>
          'Provider tool not installed',
        WorkspaceWorkerState.authenticationRequired =>
          'Authentication required',
        WorkspaceWorkerState.ready => 'Ready',
        WorkspaceWorkerState.disabled => 'Disabled',
        WorkspaceWorkerState.incompatible => 'Incompatible',
        WorkspaceWorkerState.catalogRetired => 'Catalog retired',
        WorkspaceWorkerState.runtimeUnavailable => 'Runtime unavailable',
      };
}

extension WorkspaceWorkerProfileStateLabel on WorkspaceWorkerProfileState {
  String get label => switch (this) {
        WorkspaceWorkerProfileState.resolving => 'Resolving',
        WorkspaceWorkerProfileState.syncing => 'Downloading',
        WorkspaceWorkerProfileState.ready => 'Available',
        WorkspaceWorkerProfileState.unavailable => 'Not downloaded',
        WorkspaceWorkerProfileState.incompatible => 'Incompatible',
        WorkspaceWorkerProfileState.error => 'Error',
      };
}

String deriveLocalWorkerHealth(LocalWorker worker) {
  if (worker.activationState == LocalWorkerActivationState.disabled) {
    return 'Disabled';
  }
  return deriveLocalWorkerReadiness(worker);
}

List<String> deriveLocalWorkerStatusBadges(
  LocalWorker worker, {
  String? readinessLabel,
}) =>
    [
      if (worker.activationState == LocalWorkerActivationState.disabled)
        'Disabled',
      readinessLabel ?? deriveLocalWorkerReadiness(worker),
    ];

String deriveLocalWorkerReadiness(LocalWorker worker) {
  if (worker.lastLiveTestPassed == false) {
    final liveIssue = worker.lastLiveTestIssueCode ?? worker.readinessIssueCode;
    if (liveIssue == 'cli_not_found') return 'Not installed';
    if (liveIssue == 'setup_required' ||
        liveIssue == 'authentication_required') {
      return 'Setup required';
    }
    return 'Needs attention';
  }
  if (worker.readinessState == WorkerReadinessState.setupRequired &&
      worker.lastLiveTestPassed == true) {
    return 'Ready';
  }
  final issueCode = worker.readinessIssueCode;
  if (issueCode == 'cli_not_found') return 'Not installed';
  if (worker.readinessState == WorkerReadinessState.ready) return 'Ready';
  if (issueCode == 'setup_required' ||
      issueCode == 'authentication_required' ||
      worker.readinessState == WorkerReadinessState.setupRequired ||
      worker.readinessState == WorkerReadinessState.signInRequired) {
    return 'Setup required';
  }
  return 'Needs attention';
}

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

  /// Availability evidence is separate from activation. A disabled Worker may
  /// pass verification but must still be enabled before accepting work.
  bool get _latestLivePassed {
    final worker = localWorker;
    if (worker?.lastLiveTestPassed != true) return false;
    final live = DateTime.tryParse(worker?.lastLiveTestAt ?? '');
    final passive = DateTime.tryParse(worker?.lastPassiveProbeAt ?? '');
    return live != null && (passive == null || !live.isBefore(passive));
  }

  String? get issueCode {
    final worker = localWorker;
    if (_latestLivePassed) return null;
    return worker?.lastLiveTestPassed == false
        ? worker?.lastLiveTestIssueCode ?? worker?.readinessIssueCode
        : worker?.readinessIssueCode;
  }

  String get availabilityLabel {
    if (catalogRetired) return 'Worker retired';
    if (localState == WorkspaceLocalWorkerState.unavailable) {
      return 'Local state unavailable';
    }
    if (profileState == WorkspaceWorkerProfileState.incompatible) {
      return 'Profile incompatible';
    }
    if (profileState == WorkspaceWorkerProfileState.error ||
        profileState == WorkspaceWorkerProfileState.unavailable) {
      return 'Profile unavailable';
    }
    if (localWorker == null) return 'Setup required';
    if (profileState != WorkspaceWorkerProfileState.ready) {
      return 'Checking Profile';
    }
    if (issueCode != null &&
        issueCode != 'setup_required' &&
        issueCode != 'probe_required') {
      return workerIssueLabel(issueCode!);
    }
    if (_latestLivePassed) return 'Ready';
    if (localWorker!.lastLiveTestPassed == false) return 'Live test failed';
    if (readiness == WorkerReadinessState.signInRequired) {
      return 'CLI sign-in required';
    }
    if (readinessLabel == 'Ready') return 'Ready';
    if (readiness == WorkerReadinessState.setupRequired) {
      return 'Live test required';
    }
    if (readiness == WorkerReadinessState.runtimeUnavailable) {
      return 'Worker Engine unavailable';
    }
    if (readiness == WorkerReadinessState.testFailed) {
      return 'Verification failed';
    }
    return 'Not verified';
  }

  String get availabilityDetail {
    if (catalogRetired) {
      return 'This Worker is no longer published in the Cloud catalog. Existing local files are preserved.';
    }
    if (localState == WorkspaceLocalWorkerState.unavailable) {
      return 'Local Worker state could not be read. Reconnect to the service and retry.';
    }
    if (profileState == WorkspaceWorkerProfileState.error ||
        profileState == WorkspaceWorkerProfileState.unavailable ||
        profileState == WorkspaceWorkerProfileState.incompatible) {
      return profileAvailability.message ??
          'Refresh the published Profile and check Workspace and CLI compatibility.';
    }
    if (localWorker == null) {
      return 'Configure this Worker on this computer, then run a live test.';
    }
    if (availabilityLabel == 'Ready') {
      return localWorker!.activationState == LocalWorkerActivationState.disabled
          ? 'Verification passed. Enable this Worker to accept requests.'
          : 'Verification passed. This Worker is enabled to accept requests.';
    }
    return workerIssueRecovery(issueCode, fallback: availabilityLabel);
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

String workerIssueLabel(String code) => switch (code) {
      'cli_not_found' ||
      'provider_tool_unavailable' =>
        'Provider CLI not found',
      'authentication_required' ||
      'provider_authentication_required' =>
        'CLI sign-in required',
      'setup_required' || 'live_probe_required' => 'Live test required',
      'probe_required' => 'Not verified',
      'tool_profile_unavailable' ||
      'package_unavailable' =>
        'Profile unavailable',
      'profile_invalid' ||
      'profile_identity_mismatch' =>
        'Profile validation failed',
      'unsupported_provider_tool_version' => 'CLI version unsupported',
      'cli_worker_engine_unavailable' => 'Worker Engine unavailable',
      'engine_incompatible' => 'Engine version incompatible',
      'probe_timeout' || 'deadline_exceeded' => 'Verification timed out',
      'provider_rate_limited' ||
      'rate_limited' =>
        'Provider rate limit reached',
      'verification_save_failed' => 'Could not save verification',
      'execution_test_failed' || 'provider_failure' => 'Live test failed',
      _ => 'Verification failed: $code',
    };

String workerIssueRecovery(String? code, {String fallback = 'Not verified'}) =>
    switch (code) {
      'cli_not_found' ||
      'provider_tool_unavailable' =>
        'Install the provider CLI and make it available to the Workspace service, then test again.',
      'authentication_required' ||
      'provider_authentication_required' =>
        'Sign in using the provider CLI on this computer, then test again.',
      'tool_profile_unavailable' ||
      'package_unavailable' ||
      'profile_invalid' ||
      'profile_identity_mismatch' =>
        'Refresh the published Worker Profile, then test again.',
      'unsupported_provider_tool_version' =>
        'Install a CLI version supported by the current Worker Profile, then test again.',
      'cli_worker_engine_unavailable' ||
      'engine_incompatible' =>
        'Update Workspace to restore a compatible Worker Engine, then test again.',
      'probe_timeout' ||
      'deadline_exceeded' =>
        'Check the provider connection and CLI responsiveness, then retry the test.',
      'provider_rate_limited' ||
      'rate_limited' =>
        'Wait for the provider limit to reset before testing again.',
      'verification_save_failed' =>
        'Check that Workspace can write its application state, then retry.',
      _ =>
        '$fallback. Run a live test to verify availability; review the test details if it fails.',
    };

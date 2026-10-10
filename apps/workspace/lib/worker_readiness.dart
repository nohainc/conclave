import 'dart:async';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'local_worker_registry.dart';
import 'cli_worker_engine_supervisor.dart';
import 'tool_profile_release_store.dart';
import 'tool_profile_release_verifier.dart';
import 'tool_profile_resolver.dart';
import 'worker_catalog_coordinator.dart';
import 'worker_diagnostic_store.dart';
import 'workspace_registration.dart';

enum LocalWorkerProbeMode { passive, live }

class WorkerReadinessAssessment {
  const WorkerReadinessAssessment(
    this.state, {
    this.issueCode,
    this.diagnosticDetails,
    this.toolVersion,
    this.replaceToolVersion = false,
    this.toolName,
    this.replaceToolName = false,
    this.toolPath,
    this.replaceToolPath = false,
  });

  final WorkerReadinessState state;
  final String? issueCode;
  final String? diagnosticDetails;
  final String? toolVersion;
  final bool replaceToolVersion;
  final String? toolName;
  final bool replaceToolName;
  final String? toolPath;
  final bool replaceToolPath;
}

class WorkerReadinessMonitor {
  WorkerReadinessMonitor({
    required this.registry,
    this.toolProfileReleaseStore,
    this.workerCatalogCoordinator,
    this.cliWorkerEngineSupervisor,
    this.workerStateDirectory,
    this.profileDiagnosticStoreForWorker,
    this.assessWorker,
  });

  final LocalWorkerRegistry registry;
  final ToolProfileReleaseStore? toolProfileReleaseStore;
  final WorkerCatalogCoordinator? workerCatalogCoordinator;
  final CliWorkerEngineSupervisor? cliWorkerEngineSupervisor;
  final Directory Function(String workerId)? workerStateDirectory;
  final WorkerDiagnosticStore Function(String workerTypeId)?
      profileDiagnosticStoreForWorker;
  final Future<WorkerReadinessAssessment> Function(LocalWorker worker)?
      assessWorker;
  bool _started = false;
  Future<void>? _activeCheck;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final worker in await registry.list()) {
      if (worker.activationState != LocalWorkerActivationState.enabled ||
          worker.status != LocalWorkerStatus.ready) {
        continue;
      }
      await registry.update(
        worker.id,
        (current) => current.copyWith(
          status: LocalWorkerStatus.needsAttention,
          activationState: current.activationState,
          readinessState: WorkerReadinessState.notProbed,
          readinessIssueCode: 'probe_required',
        ),
      );
    }
    unawaited(_checkSafely());
  }

  Future<void> _checkSafely({
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
  }) async {
    try {
      await checkNow(mode: mode);
    } on Object {
      // Preserve the last safe state and retry on the next lifecycle event.
    }
  }

  Future<void> checkNow({
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
    String? workerTypeId,
    bool includeDisabled = false,
    bool rerunWhenActive = false,
  }) {
    final active = _activeCheck;
    if (active != null) {
      if (rerunWhenActive) {
        return active.catchError((_) {}).then((_) => checkNow(
              mode: mode,
              workerTypeId: workerTypeId,
              includeDisabled: includeDisabled,
            ));
      }
      if (mode == LocalWorkerProbeMode.passive && !includeDisabled) {
        return active;
      }
      return active.catchError((_) {}).then((_) => checkNow(
            mode: mode,
            workerTypeId: workerTypeId,
            includeDisabled: includeDisabled,
          ));
    }
    final check = _checkAll(
      mode: mode,
      workerTypeId: workerTypeId,
      includeDisabled: includeDisabled,
    );
    _activeCheck = check;
    return check.whenComplete(() => _activeCheck = null);
  }

  /// Validates and atomically activates the trusted last-known-good Profile.
  /// The callback always performs a passive Engine probe; no model request is
  /// used for rollback.
  Future<bool> rollbackToolProfile(String workerTypeId) async {
    final timer = Stopwatch()..start();
    final profileDefinitionId = _profileDefinitionFor(workerTypeId);
    final store = toolProfileReleaseStore;
    final engine = cliWorkerEngineSupervisor;
    if (profileDefinitionId == null || store == null || engine == null) {
      return false;
    }
    final worker = (await registry.list(includeRemoved: true))
        .where((item) =>
            item.workerTypeId == workerTypeId &&
            item.status != LocalWorkerStatus.removed)
        .firstOrNull;
    if (worker == null) return false;
    final stateDirectory = workerStateDirectory?.call(worker.id);
    if (stateDirectory == null) return false;

    final resolver = ToolProfileResolver(store);
    final profileChannel =
        (await store.releaseState(profileDefinitionId)).selectedChannel;
    final runId = 'profile-rollback-${DateTime.now().microsecondsSinceEpoch}';
    var issueCode = 'tool_profile_unavailable';
    ProbeResult? candidateProbe;
    try {
      final rolledBack = await store.rollbackToLastKnownGood(
        profileDefinitionId,
        candidateValidator: (candidate) async {
          if (!resolver.isCompatibleRelease(
            release: candidate,
            logicalWorkerTypeId: workerTypeId,
            profileDefinitionId: profileDefinitionId,
            engineVersion: cliWorkerEngineVersion,
            // The stored version can be stale. The Engine's passive probe
            // discovers the installed CLI version and validates it below.
            providerCliVersion: null,
            channel: profileChannel,
          )) {
            issueCode = worker.toolVersion == null
                ? 'engine_incompatible'
                : 'unsupported_provider_tool_version';
            return false;
          }
          try {
            candidateProbe = await engine.probe(
              candidate,
              profileFile: store.profileFile(
                profileDefinitionId,
                candidate.releaseVersion,
              ),
              stateDirectory: stateDirectory,
              mode: WorkerProbeMode.passive,
              timeout: const Duration(seconds: 20),
            );
          } on Object catch (error) {
            issueCode = error is CliWorkerEngineProbeException
                ? error.issueCode
                : error is TimeoutException
                    ? 'deadline_exceeded'
                    : 'provider_failure';
            return false;
          }
          final result = candidateProbe!;
          if (!result.ready) {
            issueCode = result.issueCode ?? 'provider_failure';
            return false;
          }
          if (result.providerToolVersion == null ||
              !resolver.isCompatibleRelease(
                release: candidate,
                logicalWorkerTypeId: workerTypeId,
                profileDefinitionId: profileDefinitionId,
                engineVersion: cliWorkerEngineVersion,
                providerCliVersion: result.providerToolVersion,
                channel: profileChannel,
              )) {
            issueCode = 'unsupported_provider_tool_version';
            return false;
          }
          return true;
        },
      );
      final result = candidateProbe;
      if (result == null || !result.ready) return false;
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: LocalWorkerProbeMode.passive,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        profileReleaseVersion: rolledBack.releaseVersion,
        profileResolutionSource: 'lastKnownGood',
        providerToolName: result.providerToolName,
        providerToolVersion: result.providerToolVersion,
      );
      await checkNow(
        mode: LocalWorkerProbeMode.passive,
        workerTypeId: workerTypeId,
        includeDisabled: true,
      );
      return true;
    } on Object {
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: LocalWorkerProbeMode.passive,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        profileResolutionSource: 'lastKnownGood',
        issueCode: issueCode,
        failureLayer: _profileProbeFailureLayer(issueCode),
      );
      return false;
    }
  }

  Future<void> _checkAll({
    required LocalWorkerProbeMode mode,
    String? workerTypeId,
    bool includeDisabled = false,
  }) async {
    for (final worker in await registry.list()) {
      if ((workerTypeId != null && worker.workerTypeId != workerTypeId) ||
          worker.status == LocalWorkerStatus.removed) {
        continue;
      }
      if (workerCatalogCoordinator != null &&
          _profileDefinitionFor(worker.workerTypeId) == null) {
        continue;
      }
      if (worker.activationState == LocalWorkerActivationState.disabled &&
          mode == LocalWorkerProbeMode.passive &&
          !includeDisabled) {
        continue;
      }
      final assessment = assessWorker != null
          ? await assessWorker!(worker)
          : await _assess(worker, mode: mode);
      final checkedAt = DateTime.now().toUtc().toIso8601String();
      if (mode == LocalWorkerProbeMode.passive) {
        final effectiveReady = assessment.state == WorkerReadinessState.ready ||
            (assessment.state == WorkerReadinessState.setupRequired &&
                worker.lastLiveTestPassed == true);
        await registry.update(
          worker.id,
          (current) => current.copyWith(
            status:
                current.activationState == LocalWorkerActivationState.disabled
                    ? LocalWorkerStatus.disabled
                    : effectiveReady
                        ? LocalWorkerStatus.ready
                        : LocalWorkerStatus.needsAttention,
            activationState: current.activationState,
            readinessState: assessment.state,
            lastPassiveProbeAt: checkedAt,
            readinessIssueCode: assessment.issueCode,
            clearReadinessIssueCode: assessment.issueCode == null,
            toolVersion: assessment.toolVersion,
            clearToolVersion:
                assessment.replaceToolVersion && assessment.toolVersion == null,
            toolName: assessment.toolName,
            clearToolName:
                assessment.replaceToolName && assessment.toolName == null,
            toolPath: assessment.toolPath,
            clearToolPath:
                assessment.replaceToolPath && assessment.toolPath == null,
          ),
        );
        continue;
      }

      final passed = assessment.state == WorkerReadinessState.ready;
      final details = passed
          ? null
          : assessment.diagnosticDetails ?? _safeTestDetails(assessment);
      await registry.update(
        worker.id,
        (current) => current.copyWith(
          status: current.activationState == LocalWorkerActivationState.disabled
              ? LocalWorkerStatus.disabled
              : passed
                  ? LocalWorkerStatus.ready
                  : LocalWorkerStatus.needsAttention,
          activationState: current.activationState,
          lastLiveTestAt: checkedAt,
          lastLiveTestPassed: passed,
          lastLiveTestIssueCode: assessment.issueCode,
          clearLastLiveTestIssueCode: assessment.issueCode == null,
          lastLiveTestDetails: details,
          clearLastLiveTestDetails: passed,
          toolVersion: assessment.toolVersion,
          clearToolVersion:
              assessment.replaceToolVersion && assessment.toolVersion == null,
          toolName: assessment.toolName,
          clearToolName:
              assessment.replaceToolName && assessment.toolName == null,
          toolPath: assessment.toolPath,
          clearToolPath:
              assessment.replaceToolPath && assessment.toolPath == null,
        ),
      );
    }
  }

  String _safeTestDetails(WorkerReadinessAssessment assessment) {
    final issueCode = assessment.issueCode ?? 'execution_test_failed';
    final details = [
      'Tool Profile test failed ($issueCode).',
      assessment.diagnosticDetails ??
          'The package did not return safe diagnostic details.',
    ].join('\n');
    return details.length <= 1000 ? details : details.substring(0, 1000);
  }

  Future<WorkerReadinessAssessment> _assess(
    LocalWorker worker, {
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
  }) async {
    try {
      final profileDefinitionId = _profileDefinitionFor(worker.workerTypeId);
      if (profileDefinitionId == null || toolProfileReleaseStore == null) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.runtimeUnavailable,
          issueCode: 'tool_profile_unavailable',
        );
      }
      return await _assessToolProfileWorker(
        worker,
        profileDefinitionId: profileDefinitionId,
        mode: mode,
      );
    } on Object catch (error) {
      if (error is CliWorkerEngineProbeException) {
        return WorkerReadinessAssessment(
          error.issueCode == 'provider_authentication_required'
              ? WorkerReadinessState.signInRequired
              : error.issueCode == 'provider_tool_unavailable'
                  ? WorkerReadinessState.runtimeUnavailable
                  : WorkerReadinessState.testFailed,
          issueCode: error.issueCode,
          diagnosticDetails: error.safeMessage,
        );
      }
      final timeout = error is TimeoutException;
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: timeout ? 'probe_timeout' : 'provider_failure',
        diagnosticDetails: timeout
            ? 'The Tool Profile probe timed out.'
            : 'The Tool Profile could not complete its probe.',
      );
    }
  }

  String? _profileDefinitionFor(String workerTypeId) =>
      workerCatalogCoordinator?.profileDefinitionForWorker(workerTypeId);

  Future<WorkerReadinessAssessment> _assessToolProfileWorker(
    LocalWorker worker, {
    required String profileDefinitionId,
    required LocalWorkerProbeMode mode,
  }) async {
    final timer = Stopwatch()..start();
    final runId = 'profile-probe-${DateTime.now().microsecondsSinceEpoch}';
    final engine = cliWorkerEngineSupervisor;
    final store = toolProfileReleaseStore!;
    final stateDirectory = workerStateDirectory?.call(worker.id);
    if (engine == null || stateDirectory == null) {
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        issueCode: 'cli_worker_engine_unavailable',
        failureLayer: 'engine',
        profileResolutionSource: 'unavailable',
      );
      return const WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: 'cli_worker_engine_unavailable',
        diagnosticDetails: 'The generic CLI Worker Engine is unavailable.',
      );
    }
    final resolver = ToolProfileResolver(store);
    var profileChannel =
        (await store.releaseState(profileDefinitionId)).selectedChannel;
    late ToolProfileResolution<ToolProfileCandidate> resolution;
    try {
      resolution = await workerCatalogCoordinator!.resolveProfileForWorker(
        workerTypeId: worker.workerTypeId,
        engineVersion: cliWorkerEngineVersion,
        providerCliVersion: worker.toolVersion,
        // Catalog refresh invokes readiness after downloading Profiles. Never
        // wait on that refresh from a readiness check: it may be waiting on us.
        synchronizeIfUnavailable: false,
      );
      profileChannel =
          (await store.releaseState(profileDefinitionId)).selectedChannel;
    } on Object catch (error) {
      final issueCode = error is FormatException
          ? 'profile_signature_invalid'
          : 'tool_profile_unavailable';
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        profileResolutionSource: 'unavailable',
        issueCode: issueCode,
        failureLayer: 'profile',
      );
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: issueCode,
        diagnosticDetails: 'The signed Tool Profile could not be resolved.',
      );
    }
    final candidate = resolution.release;
    if (candidate != null && !candidate.isSigned) {
      final probe = await engine.probe(
        candidate,
        profileFile: await store.executionProfileFile(candidate),
        stateDirectory: stateDirectory,
        mode: mode == LocalWorkerProbeMode.live
            ? WorkerProbeMode.live
            : WorkerProbeMode.passive,
        timeout: mode == LocalWorkerProbeMode.live
            ? const Duration(
                milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
            : const Duration(seconds: 20),
      );
      await _recordToolProfileDiagnostic(worker,
          runId: runId,
          mode: mode,
          durationMs: timer.elapsedMilliseconds,
          profileDefinitionId: profileDefinitionId,
          profileReleaseVersion: candidate.releaseVersion,
          profileResolutionSource: 'draft',
          providerToolName: probe.providerToolName,
          providerToolVersion: probe.providerToolVersion,
          issueCode: probe.issueCode,
          failureLayer: probe.issueCode == null
              ? null
              : _profileProbeFailureLayer(probe.issueCode!));
      return WorkerReadinessAssessment(
        probe.ready
            ? WorkerReadinessState.ready
            : probe.issueCode == 'provider_authentication_required'
                ? WorkerReadinessState.signInRequired
                : WorkerReadinessState.testFailed,
        issueCode: probe.issueCode,
        toolName: probe.providerToolName,
        toolVersion: probe.providerToolVersion,
        replaceToolName: true,
        replaceToolVersion: true,
        diagnosticDetails:
            'Unsigned development Profile; local loopback execution only.',
      );
    }
    var release = candidate as ToolProfileReleaseAdmission?;
    if (release == null) {
      final issueCode = switch (resolution.reason) {
        ToolProfileUnavailableReason.unsupportedProviderVersion =>
          'unsupported_provider_tool_version',
        ToolProfileUnavailableReason.incompatibleEngineVersion =>
          'engine_incompatible',
        _ => 'tool_profile_unavailable',
      };
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        issueCode: issueCode,
        failureLayer: 'profile',
        profileResolutionSource: resolution.source.name,
      );
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
        issueCode: issueCode,
        diagnosticDetails: 'No eligible signed Tool Profile is available.',
      );
    }

    Future<ProbeResult> run(
      ToolProfileReleaseAdmission selected, {
      WorkerProbeMode? modeOverride,
    }) =>
        engine.probe(
          selected,
          profileFile: store.profileFile(
            selected.profileDefinitionId,
            selected.releaseVersion,
          ),
          stateDirectory: stateDirectory,
          mode: modeOverride ??
              (mode == LocalWorkerProbeMode.live
                  ? WorkerProbeMode.live
                  : WorkerProbeMode.passive),
          timeout: mode == LocalWorkerProbeMode.live
              ? const Duration(
                  milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
              : const Duration(seconds: 20),
        );

    var resolutionSource = resolution.source.name;
    var passivePreflightFailed = false;
    ProbeResult probe;
    try {
      final releaseState = await store.releaseState(profileDefinitionId);
      if (mode == LocalWorkerProbeMode.live &&
          releaseState.activeVersion != release.releaseVersion) {
        final passiveCandidate = await run(
          release,
          modeOverride: WorkerProbeMode.passive,
        );
        if (!passiveCandidate.ready ||
            !resolver.isCompatibleRelease(
              release: release,
              logicalWorkerTypeId: worker.workerTypeId,
              profileDefinitionId: profileDefinitionId,
              engineVersion: cliWorkerEngineVersion,
              providerCliVersion: passiveCandidate.providerToolVersion,
              channel: profileChannel,
            )) {
          probe = passiveCandidate;
          passivePreflightFailed = true;
        } else {
          await store.activateVersion(
              profileDefinitionId, release.releaseVersion);
          probe = await run(release);
        }
      } else {
        probe = await run(release);
      }
    } on Object catch (error) {
      final issueCode = error is CliWorkerEngineProbeException
          ? error.issueCode
          : error is TimeoutException
              ? 'deadline_exceeded'
              : 'provider_failure';
      await _recordToolProfileDiagnostic(
        worker,
        runId: runId,
        mode: mode,
        durationMs: timer.elapsedMilliseconds,
        profileDefinitionId: profileDefinitionId,
        profileReleaseVersion: release.releaseVersion,
        profileResolutionSource: resolutionSource,
        issueCode: issueCode,
        failureLayer: _profileProbeFailureLayer(issueCode, error: error),
      );
      rethrow;
    }
    final actualVersion = probe.providerToolVersion;
    if (actualVersion != null) {
      final actualResolution = await resolver.resolve(
        logicalWorkerTypeId: worker.workerTypeId,
        profileDefinitionId: profileDefinitionId,
        engineVersion: cliWorkerEngineVersion,
        providerCliVersion: actualVersion,
        channel: profileChannel,
      );
      final actualRelease = actualResolution.release;
      final liveWasRun = probe.checks.any(
        (check) =>
            check.code == 'provider_live_execution' &&
            check.status != ProbeCheckStatus.warning,
      );
      if (actualRelease != null &&
          !passivePreflightFailed &&
          actualRelease.releaseVersion != release.releaseVersion &&
          !liveWasRun) {
        release = actualRelease;
        resolutionSource = actualResolution.source.name;
        try {
          probe = await run(release);
        } on Object catch (error) {
          final issueCode = error is CliWorkerEngineProbeException
              ? error.issueCode
              : error is TimeoutException
                  ? 'deadline_exceeded'
                  : 'provider_failure';
          await _recordToolProfileDiagnostic(
            worker,
            runId: runId,
            mode: mode,
            durationMs: timer.elapsedMilliseconds,
            profileDefinitionId: profileDefinitionId,
            profileReleaseVersion: release.releaseVersion,
            profileResolutionSource: resolutionSource,
            issueCode: issueCode,
            failureLayer: _profileProbeFailureLayer(issueCode, error: error),
            providerToolName: probe.providerToolName,
            providerToolVersion: actualVersion,
          );
          rethrow;
        }
      }
    }
    final issue = probe.issueCode;
    if (mode == LocalWorkerProbeMode.passive && probe.ready) {
      final currentState = await store.releaseState(profileDefinitionId);
      if (currentState.activeVersion != release.releaseVersion) {
        await store.activateVersion(
          profileDefinitionId,
          release.releaseVersion,
        );
      }
    }
    await _recordToolProfileDiagnostic(
      worker,
      runId: runId,
      mode: mode,
      durationMs: timer.elapsedMilliseconds,
      profileDefinitionId: profileDefinitionId,
      profileReleaseVersion: release.releaseVersion,
      profileResolutionSource: resolutionSource,
      providerToolName: probe.providerToolName,
      providerToolVersion: probe.providerToolVersion,
      issueCode: issue,
      failureLayer: issue == null ? null : _profileProbeFailureLayer(issue),
    );
    final state = probe.ready
        ? WorkerReadinessState.ready
        : switch (issue) {
            'provider_authentication_required' =>
              WorkerReadinessState.signInRequired,
            'provider_tool_unavailable' ||
            'cli_worker_engine_unavailable' =>
              WorkerReadinessState.runtimeUnavailable,
            'unsupported_provider_tool_version' ||
            'engine_incompatible' =>
              WorkerReadinessState.setupRequired,
            _ => WorkerReadinessState.testFailed,
          };
    return WorkerReadinessAssessment(
      state,
      issueCode: issue,
      diagnosticDetails:
          issue == null ? null : 'Provider readiness check failed ($issue).',
      toolVersion: probe.providerToolVersion,
      replaceToolVersion: true,
      toolName: probe.providerToolName,
      replaceToolName: true,
      replaceToolPath: true,
    );
  }

  Future<void> _recordToolProfileDiagnostic(
    LocalWorker worker, {
    required String runId,
    required LocalWorkerProbeMode mode,
    required int durationMs,
    required String profileResolutionSource,
    String? profileDefinitionId,
    int? profileReleaseVersion,
    String? providerToolName,
    String? providerToolVersion,
    String? issueCode,
    String? failureLayer,
  }) async {
    final store = profileDiagnosticStoreForWorker?.call(worker.workerTypeId);
    if (store == null) return;
    await store.record(
      workerTypeId: worker.workerTypeId,
      workerVersion: cliWorkerEngineVersion,
      protocolStage: 'profile_probe',
      event: issueCode == null
          ? 'profile.probe.completed'
          : 'profile.probe.failed',
      workspaceVersion: conclaveWorkspaceAppVersion,
      engineVersion: cliWorkerEngineVersion,
      profileDefinitionId: profileDefinitionId,
      profileReleaseVersion: profileReleaseVersion,
      profileResolutionSource: profileResolutionSource,
      probeStage: mode.name,
      failureLayer: failureLayer,
      runId: runId,
      providerToolName: providerToolName,
      providerToolVersion: providerToolVersion,
      durationMs: durationMs,
      errorCode: issueCode,
    );
  }

  String _profileProbeFailureLayer(String issueCode, {Object? error}) {
    if (error is CliWorkerEngineProbeException ||
        error is TimeoutException ||
        error is FormatException ||
        error is ProcessException) {
      return 'engine';
    }
    return switch (issueCode) {
      'cli_worker_engine_unavailable' ||
      'engine_incompatible' ||
      'engine_version_mismatch' ||
      'profile_identity_mismatch' ||
      'malformed_frame' ||
      'worker_internal_failure' =>
        'engine',
      'unsupported_provider_tool_version' ||
      'tool_profile_unavailable' ||
      'profile_signature_invalid' =>
        'profile',
      _ => 'provider_tool',
    };
  }

  Future<void> dispose() async {
    await _activeCheck;
  }
}

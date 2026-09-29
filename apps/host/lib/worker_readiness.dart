import 'dart:async';
import 'dart:io';

import 'configured_worker_registry.dart';
import 'first_party_worker_adapter_descriptor.dart';
import 'first_party_worker_cli_locator.dart';
import 'v7_adapter_package_store.dart';
import 'worker_executor.dart';

enum FirstPartyWorkerProbeReasonCode {
  cliNotFound('cli_not_found'),
  unsupportedCliVersion('unsupported_cli_version'),
  authenticationRequired('authentication_required'),
  permissionConfigurationRequired('permission_configuration_required'),
  executionTestFailed('execution_test_failed'),
  ready('ready');

  const FirstPartyWorkerProbeReasonCode(this.wireValue);
  final String wireValue;
}

FirstPartyWorkerProbeReasonCode firstPartyWorkerProbeReasonCodeForState(
  WorkerReadinessState state,
) =>
    switch (state) {
      WorkerReadinessState.ready => FirstPartyWorkerProbeReasonCode.ready,
      WorkerReadinessState.notInstalled =>
        FirstPartyWorkerProbeReasonCode.cliNotFound,
      WorkerReadinessState.unsupportedCliVersion =>
        FirstPartyWorkerProbeReasonCode.unsupportedCliVersion,
      WorkerReadinessState.signInRequired =>
        FirstPartyWorkerProbeReasonCode.authenticationRequired,
      _ => FirstPartyWorkerProbeReasonCode.executionTestFailed,
    };

class WorkerReadinessAssessment {
  const WorkerReadinessAssessment(
    this.state, {
    this.credentialStatus,
    this.executablePath,
    this.cliVersion,
    this.diagnosticDetails,
    FirstPartyWorkerProbeReasonCode? reasonCode,
  }) : _reasonCode = reasonCode;
  final WorkerReadinessState state;
  final LocalWorkerCredentialStatus? credentialStatus;
  final String? executablePath;
  final String? cliVersion;
  final String? diagnosticDetails;
  final FirstPartyWorkerProbeReasonCode? _reasonCode;
  FirstPartyWorkerProbeReasonCode get reasonCode =>
      _reasonCode ?? firstPartyWorkerProbeReasonCodeForState(state);
}

class WorkerReadinessMonitor {
  WorkerReadinessMonitor({
    required this.registry,
    required this.adapterStore,
    WorkerProcessExecutor? executor,
    this.readCredential,
    this.interval = const Duration(minutes: 5),
    this.assessWorker,
  }) : executor = executor ?? WorkerProcessExecutor();

  final LocalConfiguredWorkerRegistry registry;
  final V7AdapterPackageStore adapterStore;
  final WorkerProcessExecutor executor;
  final Future<String?> Function(String credentialRef)? readCredential;
  final Duration interval;
  final Future<WorkerReadinessAssessment> Function(
      LocalConfiguredWorker worker)? assessWorker;
  Timer? _timer;
  Future<void>? _activeCheck;

  Future<void> start() async {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_checkSafely()));
    // Stored Ready state is only a cache. Quarantine it until live prerequisites
    // are checked so Cloud cannot dispatch during startup validation.
    for (final worker in await registry.list()) {
      if (worker.status != LocalWorkerStatus.ready) continue;
      await registry.update(
        worker.id,
        (current) => current.copyWith(
          status: LocalWorkerStatus.needsAttention,
        ),
      );
    }
    unawaited(_checkSafely());
  }

  Future<void> _checkSafely({bool executionTest = false}) async {
    try {
      await checkNow(executionTest: executionTest);
    } on Object {
      // Keep the last persisted state and retry on the next lifecycle event.
    }
  }

  Future<void> checkNow({
    bool executionTest = false,
    String? workerTypeId,
  }) {
    final active = _activeCheck;
    if (active != null) {
      if (!executionTest) return active;
      return active.catchError((_) {}).then((_) => checkNow(
            executionTest: true,
            workerTypeId: workerTypeId,
          ));
    }
    final check = _checkAll(
      executionTest: executionTest,
      workerTypeId: workerTypeId,
    );
    _activeCheck = check;
    return check.whenComplete(() => _activeCheck = null);
  }

  Future<void> _checkAll({
    required bool executionTest,
    String? workerTypeId,
  }) async {
    final workers = await registry.list();
    for (final worker in workers) {
      if (workerTypeId != null && worker.workerTypeId != workerTypeId) {
        continue;
      }
      if (worker.status == LocalWorkerStatus.removed) continue;
      if (worker.status == LocalWorkerStatus.disabled && !executionTest) {
        if (worker.readinessState != WorkerReadinessState.disabled) {
          await registry.update(
            worker.id,
            (current) => current.copyWith(
              readinessState: WorkerReadinessState.disabled,
            ),
          );
        }
        continue;
      }
      final assessment = assessWorker != null
          ? await assessWorker!(worker)
          : await _assess(worker, executionTest: executionTest);
      final state = assessment.state;
      final credentialStatus =
          assessment.credentialStatus ?? worker.credentialStatus;
      final liveTestAt = executionTest
          ? DateTime.now().toUtc().toIso8601String()
          : worker.lastLiveTestAt;
      final liveTestPassed = executionTest
          ? state == WorkerReadinessState.ready
          : worker.lastLiveTestPassed;
      final liveTestDetails = executionTest &&
              state != WorkerReadinessState.ready
          ? assessment.diagnosticDetails ?? _safeTestDetails(worker, assessment)
          : worker.lastLiveTestDetails;
      if (worker.readinessState == state &&
          worker.credentialStatus == credentialStatus &&
          worker.executablePath == assessment.executablePath &&
          worker.cliVersion == assessment.cliVersion &&
          worker.lastLiveTestAt == liveTestAt &&
          worker.lastLiveTestPassed == liveTestPassed &&
          worker.lastLiveTestDetails == liveTestDetails &&
          ((state == WorkerReadinessState.ready) ==
              (worker.status == LocalWorkerStatus.ready)) &&
          !executionTest) {
        continue;
      }
      await registry.update(
        worker.id,
        (current) => current.copyWith(
          status: current.status == LocalWorkerStatus.disabled
              ? LocalWorkerStatus.disabled
              : state == WorkerReadinessState.ready
                  ? LocalWorkerStatus.ready
                  : LocalWorkerStatus.needsAttention,
          readinessState: current.status == LocalWorkerStatus.disabled
              ? WorkerReadinessState.disabled
              : state,
          credentialStatus: credentialStatus,
          executablePath: assessment.executablePath,
          cliVersion: assessment.cliVersion,
          lastLiveTestAt: liveTestAt,
          lastLiveTestPassed: liveTestPassed,
          lastLiveTestDetails: liveTestDetails,
          clearLastLiveTestDetails:
              executionTest && state == WorkerReadinessState.ready,
          clearExecutable: assessment.executablePath == null ||
              assessment.cliVersion == null,
        ),
      );
    }
    // The registry's onChanged hook sends a fresh full inventory snapshot.
  }

  String _safeTestDetails(
    LocalConfiguredWorker worker,
    WorkerReadinessAssessment assessment,
  ) {
    final code = assessment.reasonCode.wireValue;
    final guidance = switch (assessment.reasonCode) {
      FirstPartyWorkerProbeReasonCode.cliNotFound =>
        'The required CLI could not be found. Install it or make it available to Workspace, then select Check again.',
      FirstPartyWorkerProbeReasonCode.unsupportedCliVersion =>
        'The installed CLI version is not supported by this Workspace build.',
      FirstPartyWorkerProbeReasonCode.authenticationRequired =>
        'Sign in to the provider CLI on this computer, then run Test again.',
      FirstPartyWorkerProbeReasonCode.permissionConfigurationRequired =>
        'Update the CLI permission settings on this computer, then run Test again.',
      FirstPartyWorkerProbeReasonCode.executionTestFailed => assessment.state ==
              WorkerReadinessState.adapterUnavailable
          ? 'Workspace could not start or communicate with its local integration. Try Test again, then open Advanced Diagnostics if it continues.'
          : 'The local readiness or execution check did not complete. Open Advanced Diagnostics for more information.',
      FirstPartyWorkerProbeReasonCode.ready =>
        'No failure details are available. Run Test again if the issue continues.',
    };
    final descriptor = FirstPartyWorkerAdapterDescriptor.forProductWorkerTypeId(
      worker.workerTypeId,
    );
    final cli = descriptor?.executableCandidates.firstOrNull ?? 'CLI';
    final readinessCalls = switch (worker.workerTypeId) {
      'chatgpt' => '`$cli --version`; `$cli login status`',
      _ => '`$cli --version`',
    };
    final executionCall = switch (worker.workerTypeId) {
      'chatgpt' => '`codex --ask-for-approval never --sandbox workspace-write '
          'exec --json --ephemeral --color never --skip-git-repo-check '
          '--cd <Workspace test directory> -`',
      'gemini' => '`agy --input-format stream-json --output-format stream-json '
          '--sandbox --print-timeout 5m`',
      _ => 'local adapter execution test',
    };
    final prompt = descriptor?.probeStrategy.setupExecutionTestPrompt;
    final promptStatus =
        assessment.state == WorkerReadinessState.adapterUnavailable ||
                assessment.state == WorkerReadinessState.signInRequired ||
                assessment.state == WorkerReadinessState.notInstalled ||
                assessment.state == WorkerReadinessState.unsupportedCliVersion
            ? 'Not sent; intended prompt: "$prompt".'
            : prompt == null
                ? 'No execution prompt is configured.'
                : '"$prompt" (submission could not be confirmed)';
    final readinessResult = switch (assessment.state) {
      WorkerReadinessState.adapterUnavailable =>
        'failed: Workspace could not complete the local adapter readiness probe',
      WorkerReadinessState.notInstalled => 'failed: CLI not found',
      WorkerReadinessState.unsupportedCliVersion =>
        'failed: installed CLI version is unsupported',
      WorkerReadinessState.signInRequired =>
        'failed: provider CLI authentication is required',
      _ => 'failed: ${assessment.reasonCode.wireValue}',
    };
    return [
      'Test failed ($code)',
      'Readiness calls: $readinessCalls',
      'Readiness result: $readinessResult',
      'Execution call: $executionCall',
      'Prompt: $promptStatus',
      'Expected: exactly "OK"',
      'Result: $guidance',
    ].join('\n');
  }

  Future<WorkerReadinessAssessment> _assess(
    LocalConfiguredWorker worker, {
    bool executionTest = false,
  }) async {
    String? resolvedPath;
    String? resolvedVersion;
    try {
      final type = FirstPartyWorkerAdapterDescriptor.forProductWorkerTypeId(
        worker.workerTypeId,
      );
      if (type == null) {
        return const WorkerReadinessAssessment(WorkerReadinessState.testFailed);
      }
      final located = await adapterStore.cliLocator.locate(
        type,
        cachedPath: worker.executablePath,
      );
      if (located == null) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.notInstalled,
          reasonCode: FirstPartyWorkerProbeReasonCode.cliNotFound,
        );
      }
      resolvedPath = located.path;
      resolvedVersion = located.versionProbe.detectedVersion;
      if (!located.versionProbe.satisfied) {
        return WorkerReadinessAssessment(
          WorkerReadinessState.unsupportedCliVersion,
          executablePath: located.path,
          cliVersion: located.versionProbe.detectedVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.unsupportedCliVersion,
        );
      }
      if (!type.requiredLocalPermissions
          .every(worker.localPermissions.contains)) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.testFailed,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
        );
      }
      final adapterPackageId = type.adapterPackageId;
      var adapterAvailable = await adapterStore.hasVerifiedActivePackage(
        adapterPackageId,
        type.requiredLocalPermissions,
        [File(located.path).parent.path],
      );
      if (!adapterAvailable) {
        // Existing Worker records can outlive a removed or invalid active
        // package. Restore the last-known-good or embedded first-party
        // adapter before probing readiness, including after a local rebuild.
        adapterAvailable = await adapterStore.ensureFirstPartyAdapterAvailable(
          adapterPackageId,
          additionalPathDirectories: [File(located.path).parent.path],
        );
      }
      if (!adapterAvailable) {
        return WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          executablePath: located.path,
          cliVersion: located.versionProbe.detectedVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
        );
      }
      V7AdapterLaunch? adapter;
      try {
        adapter = await adapterStore.resolve(
          worker: worker.copyWith(
            executablePath: located.path,
            cliVersion: located.versionProbe.detectedVersion,
          ),
          readCredential: readCredential ?? (_) async => null,
        );
      } on FirstPartyCliResolutionException catch (error) {
        final unsupported = error.reasonCode == 'unsupported_cli_version';
        return WorkerReadinessAssessment(
          unsupported
              ? WorkerReadinessState.unsupportedCliVersion
              : WorkerReadinessState.notInstalled,
          executablePath: error.executablePath,
          cliVersion: error.detectedVersion,
          reasonCode: unsupported
              ? FirstPartyWorkerProbeReasonCode.unsupportedCliVersion
              : FirstPartyWorkerProbeReasonCode.cliNotFound,
        );
      } on Object {
        return WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          executablePath: located.path,
          cliVersion: located.versionProbe.detectedVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
        );
      }
      if (adapter == null) {
        return WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          executablePath: located.path,
          cliVersion: located.versionProbe.detectedVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
        );
      }
      late final Map<String, Object?> bridgeProbe;
      try {
        bridgeProbe = await executor.checkV7AdapterHealth(
          adapter.processSpec,
          workerTypeId: adapter.workerTypeId,
          adapterVersion: adapter.adapterVersion,
          healthCheckMode: 'protocol',
          // Match the opt-in live acceptance tests: provider execution may be
          // slower than routine adapter startup/readiness probes.
          timeout: executionTest
              ? const Duration(minutes: 5)
              : const Duration(seconds: 20),
          allowNotReady: true,
          executionTestPrompt: executionTest
              ? type.probeStrategy.setupExecutionTestPrompt
              : null,
        );
      } on Object catch (error) {
        final detail = error is TimeoutException
            ? 'adapter health check timed out'
            : error.toString();
        final safeDetail =
            detail.length <= 500 ? detail : '${detail.substring(0, 497)}…';
        final failedAssessment = WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          executablePath: located.path,
          cliVersion: located.versionProbe.detectedVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
        );
        final diagnosticDetails = executionTest
            ? '${_safeTestDetails(worker, failedAssessment)}\n'
                'Local process detail: $safeDetail'
            : safeDetail;
        final boundedDiagnostic = diagnosticDetails.length <= 1000
            ? diagnosticDetails
            : '${diagnosticDetails.substring(0, 997)}…';
        return WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          executablePath: located.path,
          cliVersion: located.versionProbe.detectedVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
          diagnosticDetails: boundedDiagnostic,
        );
      }
      final executablePath = adapter.executablePath ?? located.path;
      final cliVersion =
          adapter.cliVersion ?? located.versionProbe.detectedVersion;
      final toolVersion = bridgeProbe['toolVersion'];
      if (toolVersion == null) {
        return WorkerReadinessAssessment(
          WorkerReadinessState.notInstalled,
          executablePath: executablePath,
          cliVersion: cliVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.cliNotFound,
          diagnosticDetails: _testDetailsFrom(bridgeProbe),
        );
      }
      if (cliVersion != null && toolVersion != cliVersion) {
        return WorkerReadinessAssessment(
          WorkerReadinessState.testFailed,
          executablePath: executablePath,
          cliVersion: cliVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
          diagnosticDetails: _testDetailsFrom(bridgeProbe),
        );
      }
      if (type.probeStrategy.setupExecutionTestPrompt != null &&
          !executionTest) {
        // Antigravity has no documented cheap auth-status command. Keep the
        // last explicit headless-test result and avoid spending quota during
        // periodic polling. A new/unverified slot remains blocked until Test.
        if (worker.credentialStatus == LocalWorkerCredentialStatus.ready &&
            worker.readinessState == WorkerReadinessState.ready) {
          return WorkerReadinessAssessment(
            WorkerReadinessState.ready,
            credentialStatus: worker.credentialStatus,
            executablePath: executablePath,
            cliVersion: cliVersion,
            reasonCode: FirstPartyWorkerProbeReasonCode.ready,
          );
        }
        if (worker.credentialStatus ==
                LocalWorkerCredentialStatus.needsAuthentication ||
            worker.credentialStatus == LocalWorkerCredentialStatus.expired) {
          return WorkerReadinessAssessment(
            WorkerReadinessState.signInRequired,
            credentialStatus: LocalWorkerCredentialStatus.needsAuthentication,
            executablePath: executablePath,
            cliVersion: cliVersion,
            reasonCode: FirstPartyWorkerProbeReasonCode.authenticationRequired,
          );
        }
        // New Worker or no recorded auth state. Mark as needing a manual test
        // rather than a generic failure so the UI can show setup guidance.
        return WorkerReadinessAssessment(
          WorkerReadinessState.signInRequired,
          credentialStatus: LocalWorkerCredentialStatus.needsAuthentication,
          executablePath: executablePath,
          cliVersion: cliVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.authenticationRequired,
          diagnosticDetails:
              'This Worker requires a manual test to verify authentication. '
              'Sign in to the Antigravity CLI on this computer, then select '
              'Test to complete setup.',
        );
      }
      if (bridgeProbe['ready'] != true) {
        final issues = bridgeProbe['issues'] as List<Object?>? ?? const [];
        final authenticationRequired = issues.any((issue) =>
            issue is Map && issue['code'] == 'authentication_required');
        final permissionConfigurationRequired = issues.any((issue) =>
            issue is Map &&
            issue['code'] == 'permission_configuration_required');
        final cliNotFound = issues
            .any((issue) => issue is Map && issue['code'] == 'cli_not_found');
        return WorkerReadinessAssessment(
          authenticationRequired
              ? WorkerReadinessState.signInRequired
              : cliNotFound
                  ? WorkerReadinessState.notInstalled
                  : WorkerReadinessState.testFailed,
          credentialStatus: authenticationRequired
              ? LocalWorkerCredentialStatus.needsAuthentication
              : permissionConfigurationRequired
                  ? LocalWorkerCredentialStatus.error
                  : worker.credentialStatus,
          executablePath: executablePath,
          cliVersion: cliVersion,
          reasonCode: authenticationRequired
              ? FirstPartyWorkerProbeReasonCode.authenticationRequired
              : cliNotFound
                  ? FirstPartyWorkerProbeReasonCode.cliNotFound
                  : permissionConfigurationRequired
                      ? FirstPartyWorkerProbeReasonCode
                          .permissionConfigurationRequired
                      : FirstPartyWorkerProbeReasonCode.executionTestFailed,
          diagnosticDetails: _testDetailsFrom(bridgeProbe),
        );
      }
      return WorkerReadinessAssessment(
        WorkerReadinessState.ready,
        credentialStatus: LocalWorkerCredentialStatus.ready,
        executablePath: executablePath,
        cliVersion: cliVersion,
        reasonCode: FirstPartyWorkerProbeReasonCode.ready,
      );
    } on Object {
      return WorkerReadinessAssessment(
        WorkerReadinessState.testFailed,
        executablePath: resolvedPath ?? worker.executablePath,
        cliVersion: resolvedVersion ?? worker.cliVersion,
        reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
      );
    }
  }

  String? _testDetailsFrom(Map<String, Object?> probe) {
    final details = probe['testDetails'];
    if (details is! String || details.isEmpty) return null;
    return details.length <= 1000 ? details : '${details.substring(0, 997)}…';
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _activeCheck;
  }
}

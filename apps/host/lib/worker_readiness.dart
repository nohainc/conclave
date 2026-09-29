import 'dart:async';

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
    FirstPartyWorkerProbeReasonCode? reasonCode,
  }) : _reasonCode = reasonCode;
  final WorkerReadinessState state;
  final LocalWorkerCredentialStatus? credentialStatus;
  final String? executablePath;
  final String? cliVersion;
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
      if (worker.readinessState == state &&
          worker.credentialStatus == credentialStatus &&
          worker.executablePath == assessment.executablePath &&
          worker.cliVersion == assessment.cliVersion &&
          worker.lastLiveTestAt == liveTestAt &&
          worker.lastLiveTestPassed == liveTestPassed &&
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
          clearExecutable: assessment.executablePath == null ||
              assessment.cliVersion == null,
        ),
      );
    }
    // The registry's onChanged hook sends a fresh full inventory snapshot.
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
          timeout: const Duration(seconds: 20),
          allowNotReady: true,
          executionTestPrompt: executionTest
              ? type.probeStrategy.setupExecutionTestPrompt
              : null,
        );
      } on Object {
        return WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          executablePath: located.path,
          cliVersion: located.versionProbe.detectedVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
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
        );
      }
      if (cliVersion != null && toolVersion != cliVersion) {
        return WorkerReadinessAssessment(
          WorkerReadinessState.testFailed,
          executablePath: executablePath,
          cliVersion: cliVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
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
        return WorkerReadinessAssessment(
          WorkerReadinessState.testFailed,
          credentialStatus: worker.credentialStatus,
          executablePath: executablePath,
          cliVersion: cliVersion,
          reasonCode: FirstPartyWorkerProbeReasonCode.executionTestFailed,
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

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _activeCheck;
  }
}

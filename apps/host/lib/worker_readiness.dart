import 'dart:async';

import 'cloud_connection.dart';
import 'configured_worker_registry.dart';
import 'first_party_worker_registry.dart';
import 'v7_adapter_package_store.dart';
import 'v7_adapter_protocol.dart';
import 'worker_executor.dart';

export 'v7_adapter_protocol.dart' show LocalWorkerProbeMode;

class WorkerReadinessAssessment {
  const WorkerReadinessAssessment(
    this.state, {
    this.issueCode,
    this.diagnosticDetails,
    this.toolVersion,
    this.replaceToolVersion = false,
  });

  final WorkerReadinessState state;
  final String? issueCode;
  final String? diagnosticDetails;
  final String? toolVersion;
  final bool replaceToolVersion;
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
  }) {
    final active = _activeCheck;
    if (active != null) {
      if (mode == LocalWorkerProbeMode.passive) return active;
      return active.catchError((_) {}).then((_) => checkNow(
            mode: mode,
            workerTypeId: workerTypeId,
          ));
    }
    final check = _checkAll(mode: mode, workerTypeId: workerTypeId);
    _activeCheck = check;
    return check.whenComplete(() => _activeCheck = null);
  }

  Future<void> _checkAll({
    required LocalWorkerProbeMode mode,
    String? workerTypeId,
  }) async {
    for (final worker in await registry.list()) {
      if ((workerTypeId != null && worker.workerTypeId != workerTypeId) ||
          worker.status == LocalWorkerStatus.removed) {
        continue;
      }
      if (worker.activationState == LocalWorkerActivationState.disabled &&
          mode == LocalWorkerProbeMode.passive) {
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
        ),
      );
    }
  }

  String _safeTestDetails(WorkerReadinessAssessment assessment) {
    final issueCode = assessment.issueCode ?? 'execution_test_failed';
    final details = [
      'Worker Package test failed ($issueCode).',
      assessment.diagnosticDetails ??
          'The package did not return safe diagnostic details.',
    ].join('\n');
    return details.length <= 1000 ? details : details.substring(0, 1000);
  }

  Future<WorkerReadinessAssessment> _assess(
    LocalConfiguredWorker worker, {
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
  }) async {
    try {
      final entry = FirstPartyWorkerPackage.forProductWorkerTypeId(
        worker.workerTypeId,
      );
      if (entry == null) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.testFailed,
          issueCode: 'package_unavailable',
        );
      }
      var packageAvailable = await adapterStore.hasVerifiedActivePackage(
        entry.packageId,
        worker.localPermissions,
      );
      if (!packageAvailable) {
        packageAvailable = await adapterStore.ensureFirstPartyAdapterAvailable(
          entry.packageId,
        );
      }
      if (!packageAvailable) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          issueCode: 'package_unavailable',
        );
      }
      final launch = await adapterStore.resolve(
        worker: worker,
        readCredential: readCredential ?? (_) async => null,
      );
      if (launch == null) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
          issueCode: 'package_unavailable',
        );
      }
      final result = await executor.checkV7AdapterHealth(
        launch.processSpec,
        workerTypeId: launch.workerTypeId,
        adapterVersion: launch.adapterVersion,
        healthCheckMode: 'protocol',
        timeout: mode == LocalWorkerProbeMode.live
            ? const Duration(seconds: 30)
            : const Duration(seconds: 20),
        allowNotReady: true,
        mode: mode,
      );
      final checks = (result['checks'] as List? ?? const [])
          .whereType<Map>()
          .toList(growable: false);
      final failedCheck =
          checks.where((check) => check['status'] == 'failed').firstOrNull;
      final setupCheck = checks
          .where((check) =>
              check['status'] == 'skipped' &&
              check['issueCode'] == 'setup_required')
          .firstOrNull;
      final legacyIssue =
          (result['issues'] as List? ?? const []).whereType<Map>().firstOrNull;
      final code = (failedCheck?['issueCode'] ??
          setupCheck?['issueCode'] ??
          legacyIssue?['code']) as String?;
      final message = (failedCheck?['diagnostic'] ??
          setupCheck?['diagnostic'] ??
          legacyIssue?['message']) as String?;
      if (result['ready'] == true) {
        return WorkerReadinessAssessment(
          setupCheck == null
              ? WorkerReadinessState.ready
              : WorkerReadinessState.setupRequired,
          issueCode: code,
          diagnosticDetails: message,
          toolVersion: result['toolVersion'] as String?,
          replaceToolVersion: true,
        );
      }
      final state = switch (code) {
        'cli_not_found' ||
        'package_unavailable' =>
          WorkerReadinessState.adapterUnavailable,
        'setup_required' ||
        'authentication_required' =>
          WorkerReadinessState.setupRequired,
        'permission_configuration_required' =>
          WorkerReadinessState.setupRequired,
        _ => WorkerReadinessState.testFailed,
      };
      return WorkerReadinessAssessment(
        state,
        issueCode: code ?? 'probe_failed',
        diagnosticDetails: message,
        toolVersion: result['toolVersion'] as String?,
        replaceToolVersion: true,
      );
    } on Object catch (error) {
      final timeout = error is TimeoutException;
      return WorkerReadinessAssessment(
        WorkerReadinessState.adapterUnavailable,
        issueCode: timeout ? 'probe_timeout' : 'package_unavailable',
        diagnosticDetails: timeout
            ? 'The Worker Package probe timed out.'
            : error is V7AdapterExecutionFailure &&
                    error.localDiagnostic != null &&
                    error.localDiagnostic!.isNotEmpty
                ? error.localDiagnostic
                : 'The Worker Package could not complete its probe.',
      );
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _activeCheck;
  }
}

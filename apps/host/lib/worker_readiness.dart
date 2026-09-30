import 'dart:async';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'cloud_connection.dart';
import 'configured_worker_registry.dart';
import 'first_party_worker_registry.dart';
import 'v7_adapter_package_store.dart';
import 'v7_adapter_protocol.dart';
import 'worker_executor.dart';
import 'worker_version_store.dart';
import 'worker_release_verifier.dart';
import 'worker_process_supervisor.dart';

export 'v7_adapter_protocol.dart' show LocalWorkerProbeMode;

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
    required this.adapterStore,
    this.workerVersionStore,
    this.workerProcessSupervisor,
    WorkerProcessExecutor? executor,
    this.readCredential,
    this.interval = const Duration(minutes: 5),
    this.assessWorker,
  }) : executor = executor ?? WorkerProcessExecutor();

  final LocalConfiguredWorkerRegistry registry;
  final V7AdapterPackageStore adapterStore;
  final WorkerVersionStore? workerVersionStore;
  final WorkerProcessSupervisor? workerProcessSupervisor;
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
      final versionStore = workerVersionStore;
      final nativeSupervisor = workerProcessSupervisor;
      final nativeManifest = await versionStore?.activeManifest(
        worker.workerTypeId,
      );
      if (versionStore != null &&
          nativeSupervisor != null &&
          nativeManifest != null) {
        final admission = await WorkerReleaseVerifier.verifyInstalled(
          manifestInput: nativeManifest.toJson(),
          packageRoot: versionStore.versionDirectory(
            worker.workerTypeId,
            nativeManifest.workerVersion,
          ),
          expectedWorkerTypeId: worker.workerTypeId,
          platform: versionStore.platform,
          trustPolicy: versionStore.trustPolicy,
          allowedPermissions: versionStore.allowedPermissions,
          supportedProtocolVersions: versionStore.supportedProtocolVersions,
          readableStateSchemaVersion: versionStore.workerStateSchemaVersion,
        );
        final probe = await nativeSupervisor.probe(
          admission,
          stateDirectory: versionStore.stateDirectory(worker.workerTypeId),
          mode: mode == LocalWorkerProbeMode.live
              ? WorkerProbeMode.live
              : WorkerProbeMode.passive,
          timeout: mode == LocalWorkerProbeMode.live
              ? const Duration(seconds: 30)
              : const Duration(seconds: 20),
        );
        final issueCode = probe.issueCode;
        final readiness = probe.ready
            ? WorkerReadinessState.ready
            : switch (issueCode) {
                'authentication_required' ||
                'sign_in_required' =>
                  WorkerReadinessState.signInRequired,
                'setup_required' ||
                'cli_not_found' =>
                  WorkerReadinessState.setupRequired,
                'provider_tool_unavailable' =>
                  WorkerReadinessState.runtimeUnavailable,
                _ => WorkerReadinessState.testFailed,
              };
        return WorkerReadinessAssessment(
          readiness,
          issueCode: issueCode,
          diagnosticDetails: probe.diagnostics,
          toolVersion: probe.tool?.version,
          replaceToolVersion: true,
          toolName: probe.tool?.name,
          replaceToolName: true,
          toolPath: probe.tool?.path,
          replaceToolPath: true,
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
          WorkerReadinessState.runtimeUnavailable,
          issueCode: 'package_unavailable',
        );
      }
      final launch = await adapterStore.resolve(
        worker: worker,
        readCredential: readCredential ?? (_) async => null,
      );
      if (launch == null) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.runtimeUnavailable,
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
          toolName: result['toolName'] as String?,
          replaceToolName: true,
          toolPath: result['toolPath'] as String?,
          replaceToolPath: true,
        );
      }
      final state = switch (code) {
        'cli_not_found' ||
        'package_unavailable' =>
          WorkerReadinessState.runtimeUnavailable,
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
        toolName: result['toolName'] as String?,
        replaceToolName: true,
        toolPath: result['toolPath'] as String?,
        replaceToolPath: true,
      );
    } on Object catch (error) {
      final timeout = error is TimeoutException;
      return WorkerReadinessAssessment(
        WorkerReadinessState.runtimeUnavailable,
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

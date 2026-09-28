import 'dart:async';
import 'dart:io';

import 'adapter_prerequisite.dart';
import 'configured_worker_registry.dart';
import 'local_worker_setup.dart';
import 'process_tree.dart';
import 'v7_adapter_package_store.dart';

class WorkerReadinessAssessment {
  const WorkerReadinessAssessment(this.state, {this.credentialStatus});
  final WorkerReadinessState state;
  final LocalWorkerCredentialStatus? credentialStatus;
}

class WorkerReadinessMonitor {
  WorkerReadinessMonitor({
    required this.registry,
    required this.adapterStore,
    this.interval = const Duration(minutes: 5),
    this.assessWorker,
  });

  final LocalConfiguredWorkerRegistry registry;
  final V7AdapterPackageStore adapterStore;
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
          readinessState: WorkerReadinessState.testFailed,
        ),
      );
    }
    unawaited(_checkSafely());
  }

  Future<void> _checkSafely() async {
    try {
      await checkNow();
    } on Object {
      // Keep the last persisted state and retry on the next lifecycle event.
    }
  }

  Future<void> checkNow() {
    final active = _activeCheck;
    if (active != null) return active;
    final check = _checkAll();
    _activeCheck = check;
    return check.whenComplete(() => _activeCheck = null);
  }

  Future<void> _checkAll() async {
    final workers = await registry.list();
    for (final worker in workers) {
      if (worker.status == LocalWorkerStatus.removed) continue;
      if (worker.status == LocalWorkerStatus.disabled) {
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
      final assessment = await (assessWorker ?? _assess)(worker);
      final state = assessment.state;
      final credentialStatus =
          assessment.credentialStatus ?? worker.credentialStatus;
      if (worker.readinessState == state &&
          worker.credentialStatus == credentialStatus &&
          ((state == WorkerReadinessState.ready) ==
              (worker.status == LocalWorkerStatus.ready))) {
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
        ),
      );
    }
    // The registry's onChanged hook sends a fresh full inventory snapshot.
  }

  Future<WorkerReadinessAssessment> _assess(
      LocalConfiguredWorker worker) async {
    try {
      final type = LocalWorkerTypeOption.supported
          .where((item) => item.id == worker.workerTypeId)
          .firstOrNull;
      if (type == null) {
        return const WorkerReadinessAssessment(WorkerReadinessState.testFailed);
      }
      final prerequisites = <AdapterExecutablePrerequisite>[
        if (type.executablePrerequisite case final primary?) primary,
      ];
      final results = await Future.wait<AdapterPrerequisiteResult>(
        prerequisites.map(probeAdapterExecutable),
      );
      final failed = results.where((item) => !item.satisfied).firstOrNull;
      if (failed != null) {
        final unsupported = failed.message.contains('older than required') ||
            failed.message.contains('newer than supported');
        return WorkerReadinessAssessment(unsupported
            ? WorkerReadinessState.unsupportedCliVersion
            : WorkerReadinessState.notInstalled);
      }

      if (!await _validateCliAuthentication(type.adapterId)) {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.signInRequired,
          credentialStatus: LocalWorkerCredentialStatus.needsAuthentication,
        );
      }

      try {
        final summary = await adapterStore.activeManifestSummary(worker);
        if (summary == null) {
          return const WorkerReadinessAssessment(
            WorkerReadinessState.adapterUnavailable,
          );
        }
      } on Object {
        return const WorkerReadinessAssessment(
          WorkerReadinessState.adapterUnavailable,
        );
      }
      return const WorkerReadinessAssessment(
        WorkerReadinessState.ready,
        credentialStatus: LocalWorkerCredentialStatus.ready,
      );
    } on Object {
      return const WorkerReadinessAssessment(WorkerReadinessState.testFailed);
    }
  }

  Future<bool> _validateCliAuthentication(String adapterId) async {
    final command = adapterId == 'codex'
        ? ('codex', const ['login', 'status'])
        : ('agy', const ['-p', '/usage']);
    Process? process;
    try {
      process = await startIsolatedProcess(
        command.$1,
        command.$2,
        environment: {'PATH': workspaceCliSearchPath()},
      );
      final stdout = process.stdout.drain<void>();
      final stderr = process.stderr.drain<void>();
      final exitCode =
          await process.exitCode.timeout(const Duration(seconds: 20));
      await Future.wait([stdout, stderr]).timeout(const Duration(seconds: 2));
      return exitCode == 0;
    } on TimeoutException {
      if (process != null) await terminateProcessTree(process, force: true);
      return false;
    } on ProcessException {
      return false;
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _activeCheck;
  }
}

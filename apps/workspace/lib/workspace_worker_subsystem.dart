import 'dart:async';
import 'dart:io';

import 'local_worker_registry.dart';
import 'cloud_connection.dart';
import 'worker_catalog_coordinator.dart';
import 'worker_executor.dart';
import 'worker_readiness.dart';
import 'worker_profile_store.dart';
import 'cli_worker_engine_supervisor.dart';

/// The service-owned boundary for all local Worker management.
///
/// Cloud and AX concepts stop at the Workspace Service. This subsystem owns
/// the local Worker registry, approved Tool Profiles, readiness checks and the
/// generic Worker Engine supervisor. Callers do not need to know how those
/// pieces are composed.
class WorkspaceWorkerSubsystem {
  WorkspaceWorkerSubsystem({
    required this.registry,
    required this.releaseStore,
    required this.readiness,
    this.catalog,
    this.engineSupervisor,
    this.assignmentHandler,
    this.workerStateDirectory,
    int Function(String workerId)? pendingAssignmentsFor,
    this.removalPollInterval = const Duration(seconds: 2),
    this.onRemovalChanged,
  }) : _pendingAssignmentsFor = pendingAssignmentsFor;

  final LocalWorkerRegistry registry;
  final WorkerProfileStorePort releaseStore;
  final WorkerReadinessMonitor readiness;
  final WorkerCatalogCoordinator? catalog;
  final CliWorkerEngineSupervisor? engineSupervisor;
  final WorkerAssignmentHandler? assignmentHandler;

  /// Runtime-owned Engine state for one Worker, deleted with the Worker.
  final Directory Function(String workerId)? workerStateDirectory;
  final int Function(String workerId)? _pendingAssignmentsFor;
  final Duration removalPollInterval;
  final void Function()? onRemovalChanged;
  final Map<String, Timer> _removalTimers = {};
  final Map<String, Completer<void>> _removals = {};

  /// Workers that stopped taking new work and are removed once their
  /// running and queued assignments finish.
  Set<String> get removingWorkerIds => Set.unmodifiable(_removals.keys);

  bool isRemoving(String workerId) => _removals.containsKey(workerId);

  Future<List<LocalWorker>> listWorkers() => registry.list();

  Future<LocalWorker?> resolveWorker(String workerId) =>
      registry.find(workerId);

  Future<LocalWorker> enableWorker(String workerId) async {
    final worker = await registry.update(
      workerId,
      (current) => current.copyWith(
        status: LocalWorkerStatus.needsAttention,
        activationState: LocalWorkerActivationState.enabled,
      ),
    );
    await readiness.checkNow(
      mode: LocalWorkerProbeMode.passive,
      workerTypeId: worker.workerTypeId,
    );
    return (await registry.find(workerId)) ?? worker;
  }

  Future<LocalWorker?> disableWorker(String workerId) async {
    await registry.disable(workerId);
    return registry.find(workerId);
  }

  Future<LocalWorker?> testWorker(String workerId) async {
    final worker = await registry.find(workerId);
    if (worker == null) return null;
    await readiness.checkNow(
      mode: LocalWorkerProbeMode.live,
      workerTypeId: worker.workerTypeId,
    );
    return registry.find(workerId);
  }

  Future<void> refresh({bool force = false}) async {
    await catalog?.refresh(force: force);
    if (force && catalog?.refreshReadiness == null) {
      await readiness.checkNow(
          mode: LocalWorkerProbeMode.passive, includeDisabled: true);
    }
  }

  /// Checks a single Worker for catalog and Profile updates, then re-runs its
  /// availability check. Other Workers are not contacted.
  Future<void> refreshWorker(String workerTypeId) async {
    await catalog?.refreshWorker(workerTypeId);
    await readiness.checkNow(
      mode: LocalWorkerProbeMode.passive,
      workerTypeId: workerTypeId,
      includeDisabled: true,
    );
  }

  Future<void> refreshReadiness({
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
    String? workerTypeId,
  }) =>
      readiness.checkNow(mode: mode, workerTypeId: workerTypeId);

  Future<void> ensureProfile(
    String workerTypeId, {
    bool waitForActiveRefresh = false,
  }) async {
    await catalog?.ensureWorkerProfileAvailable(
      workerTypeId,
      waitForActiveRefresh: waitForActiveRefresh,
    );
  }

  Future<void> reset() => registry.reset();

  int _pendingAssignments(String workerId) =>
      _pendingAssignmentsFor?.call(workerId) ??
      (engineSupervisor == null
          ? 0
          : engineSupervisor!.activeAssignmentCountFor(workerId) +
              engineSupervisor!.queuedAssignmentCountFor(workerId));

  /// Removes a Worker from this Workspace without keeping its settings.
  ///
  /// The Worker is disabled first, so it takes no new work and Cloud stops
  /// scheduling it. When nothing is running or queued it is removed at once;
  /// otherwise a timer waits for that work to finish. Returns true when the
  /// Worker is already gone, false while removal waits.
  Future<bool> removeWorker(String workerId) async {
    if (_removals.containsKey(workerId)) return false;
    final worker = await registry.find(workerId);
    if (worker == null) return true;
    final removal = Completer<void>();
    _removals[workerId] = removal;
    try {
      if (worker.activationState != LocalWorkerActivationState.disabled) {
        await registry.disable(workerId);
      }
    } on Object {
      _removals.remove(workerId);
      rethrow;
    }
    onRemovalChanged?.call();
    if (_pendingAssignments(workerId) == 0) {
      await _finishRemoval(workerId);
      return true;
    }
    _removalTimers[workerId] =
        Timer.periodic(removalPollInterval, (_) => _pollRemoval(workerId));
    return false;
  }

  /// Completes when a pending removal has finished.
  Future<void> removalDone(String workerId) =>
      _removals[workerId]?.future ?? Future<void>.value();

  void _pollRemoval(String workerId) {
    if (_pendingAssignments(workerId) != 0) return;
    _removalTimers.remove(workerId)?.cancel();
    unawaited(_finishRemoval(workerId).catchError((Object _) {
      // The Worker stays disabled; removing it again retries.
    }));
  }

  Future<void> _finishRemoval(String workerId) async {
    final removal = _removals[workerId];
    try {
      await registry.remove(workerId);
      final stateDirectory = workerStateDirectory?.call(workerId);
      if (stateDirectory != null && await stateDirectory.exists()) {
        await stateDirectory.delete(recursive: true);
      }
      removal?.complete();
    } on Object catch (error, stackTrace) {
      removal?.completeError(error, stackTrace);
      // Observed by the caller or the poller; avoid an unhandled future.
      unawaited(removal?.future.catchError((Object _) {}));
      rethrow;
    } finally {
      _removals.remove(workerId);
      onRemovalChanged?.call();
    }
  }

  Future<bool> rollbackProfile(String workerTypeId) =>
      readiness.rollbackToolProfile(workerTypeId);

  Future<WorkspaceAssignmentResult> execute(
    WorkspaceAssignmentContext context,
  ) {
    final handler = assignmentHandler;
    if (handler == null) {
      throw StateError('Worker execution is not configured');
    }
    return handler.call(context);
  }

  Future<bool> cancel(String assignmentId, String reason) async {
    final handler = assignmentHandler;
    if (handler == null) return false;
    return handler.cancel(assignmentId, reason);
  }

  Future<bool> cancelAssignment(String assignmentId) =>
      cancel(assignmentId, 'Cancelled by Workspace Service');

  /// Workspace-wide parallel slot total shared by every Worker.
  Future<int> parallelSlots() => registry.parallelSlots();

  /// Changes the total; the registry advances Worker revisions so Cloud sees it.
  Future<int> setParallelSlots(int slots) async {
    final applied = await registry.setParallelSlots(slots);
    engineSupervisor?.setParallelSlots(applied);
    return applied;
  }

  /// Shared slot pool usage, with a per-Worker breakdown, for the Workspace UI.
  Map<String, Object?> slotSnapshot() =>
      engineSupervisor?.slotSnapshot() ??
      const {'workers': <Object?>[], 'busySessions': 0};

  /// Stops all work and discards slot, Space-wait and fencing bookkeeping.
  Future<int> resetSlots() async {
    final stopped = await engineSupervisor?.resetSlots() ?? 0;
    await assignmentHandler?.resetSpaceState();
    return stopped;
  }

  Future<int> recoverOrphanedProcesses() =>
      engineSupervisor?.recoverOrphanedProcesses() ?? Future.value(0);

  Future<void> shutdown() async {
    // A pending removal leaves the Worker disabled; the user can remove it
    // again after the service restarts.
    for (final timer in _removalTimers.values) {
      timer.cancel();
    }
    _removalTimers.clear();
    await engineSupervisor?.shutdown();
  }
}

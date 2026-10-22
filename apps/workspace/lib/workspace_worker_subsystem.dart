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
  const WorkspaceWorkerSubsystem({
    required this.registry,
    required this.releaseStore,
    required this.readiness,
    this.catalog,
    this.engineSupervisor,
    this.assignmentHandler,
  });

  final LocalWorkerRegistry registry;
  final WorkerProfileStorePort releaseStore;
  final WorkerReadinessMonitor readiness;
  final WorkerCatalogCoordinator? catalog;
  final CliWorkerEngineSupervisor? engineSupervisor;
  final WorkerAssignmentHandler? assignmentHandler;

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
    await engineSupervisor?.shutdown();
  }
}

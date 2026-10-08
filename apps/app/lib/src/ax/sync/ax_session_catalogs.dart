import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Session-owned, user-wide queries. Thread eligibility is a view projection.
class AxSessionCatalogs {
  AxSessionCatalogs(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine();
  final AxDataSource? source;
  final AxSyncEngine engine;
  static final _sources = Expando<AxSessionCatalogs>();
  static AxSessionCatalogs forSource(AxDataSource? source) => source == null
      ? AxSessionCatalogs(null)
      : _sources[source] ??= AxSessionCatalogs(source);

  static final workflowKey = AxQueryKey(['workflow-catalog']);
  static final workersKey = AxQueryKey(['workers']);
  late final workflows = AxQuery<List<AxBuiltinWorkflow>>(
      key: workflowKey,
      staleTime: const Duration(minutes: 45),
      load: () async => List.unmodifiable(
          await source?.loadBuiltinWorkflowCatalog() ??
              const <AxBuiltinWorkflow>[]));
  late final workers = AxQuery<List<AxWorker>>(
      key: workersKey,
      staleTime: const Duration(seconds: 30),
      load: () async => List.unmodifiable(
          await source?.loadWorkspaceWorkerInventory() ?? const <AxWorker>[]));

  Future<List<AxBuiltinWorkflow>> ensureWorkflows() => engine.ensure(workflows);
  Future<List<AxWorker>> ensureWorkers() => engine.ensure(workers);
  Future<List<AxWorker>> refreshWorkers() => engine.refresh(workers);

  /// Explicit hook for publication/admin integrations; no invented wire event.
  Future<void> invalidateWorkflows() async {
    engine.invalidate(workflowKey);
    if (engine.isObserved(workflowKey)) {
      await engine.refreshStaleWhere((key) => key == workflowKey);
    }
  }
}

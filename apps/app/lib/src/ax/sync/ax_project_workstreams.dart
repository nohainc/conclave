import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Project-owned collections, independent of the selected navigation route.
class AxProjectWorkstreams {
  AxProjectWorkstreams(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine();
  final AxDataSource source;
  final AxSyncEngine engine;

  AxQuery<List<AxWorkstream>> query(String projectId) => AxQuery(
        key: AxQueryKey(['project', projectId, 'workstreams']),
        load: () async => List.unmodifiable(
            await source.loadProjectWorkstreams(projectId: projectId)),
      );

  List<AxWorkstream> peek(String projectId) =>
      engine.peek(query(projectId)).data ?? const [];

  Future<List<AxWorkstream>> ensure(String projectId) =>
      engine.ensure(query(projectId));

  Future<List<AxWorkstream>> refresh(String projectId) {
    engine.invalidate(query(projectId).key);
    return engine.refresh(query(projectId));
  }
}

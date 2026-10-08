import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Space-owned collections, independent of the selected navigation route.
class AxSpaceThreads {
  AxSpaceThreads(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine();
  final AxDataSource source;
  final AxSyncEngine engine;

  AxQuery<List<AxThread>> query(String spaceId) => AxQuery(
        key: AxQueryKey(['space', spaceId, 'threads']),
        load: () async =>
            List.unmodifiable(await source.loadSpaceThreads(spaceId: spaceId)),
      );

  List<AxThread> peek(String spaceId) =>
      engine.peek(query(spaceId)).data ?? const [];

  Future<List<AxThread>> ensure(String spaceId) =>
      engine.ensure(query(spaceId));

  Future<List<AxThread>> refresh(String spaceId) {
    engine.invalidate(query(spaceId).key);
    return engine.refresh(query(spaceId));
  }
}

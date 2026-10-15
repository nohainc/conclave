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
        load: () async => List.unmodifiable(sortAxThreadsByLastUpdate(
            (await source.loadSpaceThreads(spaceId: spaceId))
                .where((thread) => !thread.id.startsWith('workstream-')))),
      );

  List<AxThread> peek(String spaceId) =>
      engine.peek(query(spaceId)).data ?? const [];

  Future<List<AxThread>> ensure(String spaceId) =>
      engine.ensure(query(spaceId));

  Future<List<AxThread>> refresh(String spaceId) {
    engine.invalidate(query(spaceId).key);
    return engine.refresh(query(spaceId));
  }

  /// Clears the indicator locally first; the server marker follows and also
  /// clears it for the user's other sessions. Failures leave the next list
  /// read to restore the authoritative flag.
  Future<void> markRead(String spaceId, String threadId) async {
    final source = this.source;
    if (source is! AxThreadReadDataSource) return;
    final key = query(spaceId);
    final cached = engine.peek(key).data;
    final unread = cached?.any((t) => t.id == threadId && t.hasUnread) ?? false;
    if (unread) {
      engine.update(
          key,
          (state) => List.unmodifiable([
                for (final t in state.data ?? const <AxThread>[])
                  t.id == threadId ? t.copyWith(hasUnread: false) : t
              ]),
          fenceReads: false);
    }
    try {
      await (source as AxThreadReadDataSource).markThreadRead(threadId);
    } catch (_) {}
  }
}

import 'ax_sync_engine.dart';

/// Resource integrations map transport events to affected keys.
class AxRealtimeSync {
  const AxRealtimeSync(this.engine);
  final AxSyncEngine engine;
  void invalidate(Iterable<AxQueryKey> keys) {
    for (final key in keys.toSet()) {
      engine.invalidate(key);
    }
  }
}

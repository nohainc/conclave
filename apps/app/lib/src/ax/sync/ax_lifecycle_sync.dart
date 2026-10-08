import 'ax_sync_engine.dart';

/// Read-only foreground/network recovery. Never clears cache or replays writes.
class AxLifecycleSync {
  AxLifecycleSync(this.engine, {required this.onNotice});
  final AxSyncEngine engine;
  final void Function(String?) onNotice;
  bool _online = true;
  bool get isOnline => _online;
  bool get isOffline => !_online;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _flight;

  Future<void> connectivityChanged(bool online, {bool revalidate = true}) {
    final wasOffline = !_online;
    _online = online;
    if (_disposed) return Future.value();
    if (!online) {
      _generation++;
      onNotice('Connection lost. Cached data remains available.');
      return Future.value();
    }
    if (revalidate && wasOffline && _flight != null) {
      // An old offline read may fail after the online event. Finish that read,
      // then retry only still-stale active queries, never mutations.
      final generation = _generation;
      return _flight!.then<void>((_) async {
        if (_disposed || generation != _generation || !_online) return;
        await resume();
      });
    }
    if (!revalidate) {
      onNotice(null);
      return Future.value();
    }
    return resume();
  }

  Future<void> resume() {
    if (_disposed || !_online) return Future.value();
    if (_flight != null) return _flight!;
    final generation = _generation;
    onNotice('Refreshing cached data…');
    final read = engine.refreshActiveStale().then<void>((_) {
      if (!_disposed && generation == _generation && _online) onNotice(null);
    }, onError: (Object _, StackTrace __) {
      if (!_disposed && generation == _generation && _online) {
        onNotice('Updates unavailable. Showing cached data.');
      }
    });
    _flight = read;
    read.whenComplete(() {
      if (identical(_flight, read)) _flight = null;
    });
    return read;
  }

  void reset() {
    _generation++;
    _flight = null;
    if (!_disposed) onNotice(null);
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _flight = null;
  }
}

import 'dart:async';
import '../../ax_data.dart';
import '../ax_sync_engine.dart';
import 'ax_read_cache_backend.dart';
import 'ax_read_cache_codec.dart';
import 'ax_read_cache_platform_stub.dart'
    if (dart.library.js_interop) 'ax_read_cache_platform_web.dart' as platform;

export 'ax_read_cache_backend.dart';

/// Optional read acceleration. Storage failure never blocks Cloud or mutations.
class AxPersistentReadCache {
  AxPersistentReadCache(this.engine, this.source,
      {AxReadCacheBackend? backend,
      bool enabled = const bool.fromEnvironment('AX_PERSIST_READ_CACHE',
          defaultValue: true)})
      : backend =
            enabled ? (backend ?? platform.createAxReadCacheBackend()) : null;
  final AxSyncEngine engine;
  final AxDataSource source;
  final AxReadCacheBackend? backend;
  final codec = AxReadCacheCodec();
  String? _user;
  int _generation = 0, _revision = 0;
  bool _enabled = false;
  Timer? _timer;
  void Function()? _cancel;
  Future<void> _writes = Future.value();
  Object? lastError;
  String? get userId => _user;

  /// Call only after Cloud authenticated this exact Conclave user ID.
  Future<bool> hydrate(String userId) async {
    if (userId.isEmpty) return false;
    if (_user == userId) return false;
    detach();
    final generation = _generation;
    _user = userId;
    final storage = backend;
    if (storage == null) return false;
    try {
      await _writes.timeout(const Duration(milliseconds: 800));
      final snapshot =
          await storage.read(userId).timeout(const Duration(milliseconds: 800));
      if (_generation != generation || _user != userId) return false;
      _revision = snapshot.revision;
      var hydrated = false;
      for (final record in snapshot.records) {
        try {
          hydrated = codec.restore(record, engine, source, userId) || hydrated;
        } catch (_) {/* Discard corrupt/unsupported records individually. */}
      }
      _enabled = true;
      _cancel = engine.watchCache(_schedule);
      _schedule();
      return hydrated;
    } catch (error) {
      lastError = error;
      return false;
    }
  }

  void _schedule() {
    if (!_enabled || _user == null) return;
    _timer ??= Timer(const Duration(milliseconds: 150), () {
      _timer = null;
      unawaited(flush());
    });
  }

  List<Map<String, dynamic>> _records() {
    final records = engine.baseRecords.toList()
      ..sort((a, b) => (b.accessed ?? b.fetched ?? DateTime(1970))
          .compareTo(a.accessed ?? a.fetched ?? DateTime(1970)));
    final histories = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final record in records) {
      try {
        final value = codec.encode(record);
        if (value == null) continue;
        final key = record.key.parts;
        if (key.length == 3 &&
            (key.first == 'thread' || key.first == 'thread')) {
          if (!histories.contains(key[1]) && histories.length >= 20) continue;
          histories.add(key[1]);
        }
        result.add(value);
      } catch (_) {/* Optional non-persistable read. */}
    }
    return result;
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final user = _user, storage = backend;
    if (!_enabled || user == null || storage == null) return _writes;
    final generation = _generation, revision = _revision;
    final records = _records();
    _writes = _writes.then((_) async {
      if (generation != _generation || user != _user) return;
      try {
        if (!await storage
            .write(user, revision, records)
            .timeout(const Duration(seconds: 2))) {
          _enabled = false;
        }
      } catch (error) {
        lastError = error;
        _enabled = false;
      }
    });
    return _writes;
  }

  /// Fence timers, hydration and queued writes synchronously at auth boundaries.
  String? detach() {
    final user = _user;
    _generation++;
    _enabled = false;
    _user = null;
    _timer?.cancel();
    _timer = null;
    _cancel?.call();
    _cancel = null;
    return user;
  }

  Future<void> clearUser() {
    final user = detach(), storage = backend;
    if (user == null || storage == null) return _writes;
    _writes = _writes.then((_) async {
      try {
        await storage.clear(user).timeout(const Duration(seconds: 2));
      } catch (error) {
        lastError = error;
      }
    });
    return _writes;
  }

  void dispose() {
    final pending = flush();
    // Capture the final read state; let the queued write finish before detaching.
    unawaited(pending.whenComplete(() {
      detach();
      backend?.close();
    }));
    _cancel?.call();
    _cancel = null;
    _timer?.cancel();
    _timer = null;
  }
}

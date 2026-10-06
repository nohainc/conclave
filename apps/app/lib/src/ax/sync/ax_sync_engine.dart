import 'dart:async';

import 'ax_cache_policy.dart';
import 'ax_mutation.dart';
import 'ax_query.dart';
import 'ax_query_key.dart';

export 'ax_cache_policy.dart';
export 'ax_mutation.dart';
export 'ax_query.dart';
export 'ax_query_key.dart';

class _Entry<T> {
  _Entry(this.query);
  AxQuery<T> query;
  T? data;
  bool hasData = false;
  bool invalidated = true;
  DateTime? fetched;
  DateTime? accessed;
  Object? error;
  int generation = 0;
  Future<T>? flight;
  final listeners = <void Function()>[];
}

/// In-memory server state. Navigation and HTTP transport stay outside this layer.
/// Detached requests still resolve for their callers, but cannot commit state.
class AxSyncEngine {
  AxSyncEngine({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final _entries = <AxQueryKey, _Entry<dynamic>>{};

  _Entry<T> _entry<T>(AxQuery<T> query) {
    final existing = _entries[query.key];
    if (existing != null) {
      if (existing is! _Entry<T> ||
          existing.query.staleTime != query.staleTime) {
        throw StateError('Conflicting query definition for ${query.key}');
      }
      existing.query = query;
      return existing;
    }
    final entry = _Entry<T>(query);
    _entries[query.key] = entry;
    return entry;
  }

  bool _stale(_Entry<dynamic> entry) =>
      entry.invalidated ||
      entry.fetched == null ||
      _clock().difference(entry.fetched!) >= entry.query.staleTime;

  AxQueryState<T> _state<T>(_Entry<T> entry) => AxQueryState(
        data: entry.data,
        hasData: entry.hasData,
        isFetching: entry.flight != null,
        isStale: _stale(entry),
        lastFetchedAt: entry.fetched,
        lastAccessedAt: entry.accessed,
        error: entry.error,
        generation: entry.generation,
      );

  AxQueryState<T> peek<T>(AxQuery<T> query) {
    final entry = _entry(query);
    entry.accessed = _clock();
    return _state(entry);
  }

  /// Query-scoped observation. Does not fetch. Cancel is idempotent.
  /// Staleness is calculated on observation; no expiry timers are installed.
  void Function() watch<T>(
      AxQuery<T> query, void Function(AxQueryState<T>) listener,
      {bool fireImmediately = true}) {
    final entry = _entry(query);
    entry.accessed = _clock();
    void notify() => listener(_state(entry));
    entry.listeners.add(notify);
    if (fireImmediately) notify();
    return () => entry.listeners.remove(notify);
  }

  void _notify(_Entry<dynamic> entry) {
    for (final listener in List.of(entry.listeners)) {
      if (!entry.listeners.contains(listener)) continue;
      try {
        listener();
      } catch (error, stack) {
        // An observer cannot turn a successful server write into a failure.
        Zone.current.handleUncaughtError(error, stack);
      }
    }
  }

  Future<T> ensure<T>(AxQuery<T> query,
      {AxCachePolicy policy = AxCachePolicy.cacheAndNetwork}) {
    final entry = _entry(query);
    entry.accessed = _clock();
    if (policy != AxCachePolicy.networkOnly && entry.hasData) {
      if (policy == AxCachePolicy.cacheAndNetwork && _stale(entry)) {
        // Background failures remain visible in query state, not unhandled.
        refresh(query)
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
      return Future.value(entry.data as T);
    }
    return refresh(query);
  }

  Future<T> refresh<T>(AxQuery<T> query, {bool supersede = false}) {
    final entry = _entry(query);
    entry.accessed = _clock();
    if (!supersede && entry.flight != null) return entry.flight!;
    final generation = ++entry.generation;
    final completer = Completer<T>();
    entry.flight = completer.future;
    entry.error = null;
    bool current() =>
        identical(_entries[query.key], entry) && entry.generation == generation;
    // Install the shared future before notifying or invoking the loader.
    _notify(entry);
    Future<T>.sync(query.load).then((value) {
      if (current()) {
        entry.data = value;
        entry.hasData = true;
        entry.invalidated = false;
        entry.fetched = _clock();
        entry.flight = null;
        _notify(entry);
      }
      completer.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (current()) {
        entry.error = error;
        entry.invalidated = true;
        entry.flight = null;
        _notify(entry);
      }
      completer.completeError(error, stack);
    });
    return completer.future;
  }

  /// Synchronous authoritative patch. Fences old reads; callers own item-level
  /// optimistic overlays and do not use this operation to rollback a collection.
  void update<T>(AxQuery<T> query, T Function(AxQueryState<T>) transform,
      {bool fenceReads = true}) {
    final entry = _entry(query);
    final value = transform(_state(entry));
    if (fenceReads) {
      ++entry.generation;
      entry.flight = null;
    }
    entry.data = value;
    entry.hasData = true;
    entry.error = null;
    _notify(entry);
  }

  /// Invalidating detaches older reads and retains useful data.
  void invalidate(AxQueryKey key, {bool prefix = false}) {
    for (final item in _entries.entries.toList()) {
      if (item.key == key || (prefix && item.key.startsWith(key))) {
        final entry = item.value;
        ++entry.generation;
        entry.flight = null;
        entry.invalidated = true;
        _notify(entry);
      }
    }
  }

  Future<T> mutate<T>(AxMutation<T> mutation) async {
    final entry = _entry(mutation.query);
    final previous = _state(entry);
    // Calculate first: a throwing optimistic transform changes nothing.
    final optimistic = mutation.optimistic?.call(previous);
    final generation = ++entry.generation;
    entry.flight = null;
    entry.error = null;
    entry.invalidated = true;
    if (mutation.optimistic != null) {
      entry.data = optimistic;
      entry.hasData = true;
    }
    _notify(entry);
    bool current() =>
        identical(_entries[mutation.query.key], entry) &&
        entry.generation == generation;
    try {
      final value = await mutation.execute();
      if (current()) {
        entry.data = value;
        entry.hasData = true;
        entry.fetched = _clock();
        entry.invalidated = false;
        _notify(entry);
      }
      return value;
    } catch (error) {
      if (current()) {
        entry.data = previous.data;
        entry.hasData = previous.hasData;
        entry.fetched = previous.lastFetchedAt;
        entry.error = error;
        _notify(entry);
      }
      rethrow;
    }
  }

  /// Reset in place to preserve active subscriptions and reject late writes.
  void remove(AxQueryKey key) {
    final entry = _entries[key];
    if (entry == null) return;
    ++entry.generation;
    entry.data = null;
    entry.hasData = false;
    entry.flight = null;
    entry.fetched = null;
    entry.accessed = null;
    entry.error = null;
    entry.invalidated = true;
    _notify(entry);
    if (entry.listeners.isEmpty) _entries.remove(key);
  }

  /// Call at authentication/session boundaries before reusing this engine.
  void clear() {
    for (final key in _entries.keys.toList()) {
      remove(key);
    }
  }
}

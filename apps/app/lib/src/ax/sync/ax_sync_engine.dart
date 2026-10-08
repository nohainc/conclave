import 'dart:async';

import 'ax_cache_policy.dart';
import 'ax_mutation.dart';
import 'ax_query.dart';
import 'ax_query_key.dart';
import 'ax_sync_scope.dart';

export 'ax_cache_policy.dart';
export 'ax_mutation.dart';
export 'ax_query.dart';
export 'ax_query_key.dart';
export 'ax_sync_scope.dart';

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
  late final Future<void> Function() revalidate;
  final listeners = <void Function()>[];
  int retentionObservers = 0;
  int resetVersion = 0;
  bool legacyOptimistic = false;
  final optimistic = <int, T Function(AxQueryState<T>)>{};
  bool get hasOptimistic => optimistic.isNotEmpty;
  void clearOptimistic() => optimistic.clear();
  late final Object? Function() visibleData;
}

/// In-memory server state. Navigation and HTTP transport stay outside this layer.
/// Detached requests still resolve for their callers, but cannot commit state.
class AxSyncEngine {
  AxSyncEngine(
      {DateTime Function()? clock,
      int? maxRetainedThreads,
      this.maxRetainedHistoryItems = 200,
      this.runDetailRetention = const Duration(minutes: 5)})
      : maxRetainedThreads = maxRetainedThreads ?? 20,
        _clock = clock ?? DateTime.now {
    if (this.maxRetainedThreads < 1 || maxRetainedHistoryItems < 1) {
      throw ArgumentError.value(this.maxRetainedThreads);
    }
  }
  final int maxRetainedThreads;
  final int maxRetainedHistoryItems;
  final Duration runDetailRetention;
  final _historyOwners = <String,
      (bool Function(String), void Function(String), void Function(String))>{};
  bool _retentionScheduled = false;
  bool _collecting = false;

  /// Cache owners distinguish visible subscriptions from internal bridges and
  /// release pagination/reconciliation metadata when a history is evicted.
  void registerHistoryOwner(String resource, bool Function(String) protected,
      void Function(String) evict, void Function(String) compact) {
    _historyOwners[resource] = (protected, evict, compact);
  }

  bool _isHistory(AxQueryKey key) =>
      key.parts.length >= 3 &&
      (key.parts[0] == 'thread' || key.parts[0] == 'thread') &&
      (key.parts[2] == 'discussion' || key.parts[2] == 'work-requests');

  void scheduleRetention() {
    if (_retentionScheduled || _collecting) return;
    _retentionScheduled = true;
    scheduleMicrotask(() {
      _retentionScheduled = false;
      collectRetainedCache();
    });
  }

  /// Soft limit only while histories are visible or operations are pending.
  /// Runs on cache changes and subscription release; no Cloud deletions.
  void collectRetainedCache() {
    if (_collecting) return;
    _collecting = true;
    try {
      final groups = <String, List<AxQueryKey>>{};
      for (final key in _entries.keys) {
        if (_isHistory(key)) {
          groups.putIfAbsent(key.parts[1], () => []).add(key);
        }
      }
      DateTime lastUsed(String id) => groups[id]!
          .map((key) =>
              _entries[key]?.accessed ?? DateTime.fromMillisecondsSinceEpoch(0))
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final oldest = groups.keys.toList()
        ..sort((a, b) => lastUsed(a).compareTo(lastUsed(b)));
      var remaining = groups.length;
      for (final id in oldest) {
        if (remaining <= maxRetainedThreads) break;
        final keys = groups[id]!;
        if (keys.any((key) {
          final entry = _entries[key]!;
          final owner = _historyOwners[key.parts[2]];
          return entry.flight != null ||
              entry.hasOptimistic ||
              entry.legacyOptimistic ||
              (entry.retentionObservers > 0 || (owner?.$1(id) ?? false));
        })) {
          continue;
        }
        for (final resource in keys.map((key) => key.parts[2]).toSet()) {
          _historyOwners[resource]?.$2(id);
          remove(AxQueryKey(['thread', id, resource]), prefix: true);
        }
        remaining--;
      }
      for (final group in groups.entries) {
        for (final resource in group.value.map((key) => key.parts[2]).toSet()) {
          final owner = _historyOwners[resource];
          final entries = _entries.entries.where((entry) =>
              entry.key
                  .startsWith(AxQueryKey(['thread', group.key, resource])) ||
              entry.key
                  .startsWith(AxQueryKey(['thread', group.key, resource])));
          if (owner != null &&
              !owner.$1(group.key) &&
              entries.every((entry) =>
                  entry.value.flight == null &&
                  !entry.value.hasOptimistic &&
                  !entry.value.legacyOptimistic &&
                  entry.value.retentionObservers == 0)) {
            owner.$3(group.key);
          }
        }
      }
      final now = _clock();
      for (final key in _entries.keys.toList()) {
        final entry = _entries[key]!;
        if (key.parts.first == 'run' &&
            entry.listeners.isEmpty &&
            entry.flight == null &&
            !entry.hasOptimistic &&
            entry.accessed != null &&
            now.difference(entry.accessed!) >= runDetailRetention) {
          remove(key);
        }
      }
    } finally {
      _collecting = false;
    }
  }

  final DateTime Function() _clock;
  final mutations = AxMutationRunner();
  int _nextOptimistic = 0;
  final _cacheListeners = <void Function()>[];
  void Function() watchCache(void Function() listener) {
    _cacheListeners.add(listener);
    return () => _cacheListeners.remove(listener);
  }

  /// Authoritative values only; mutation overlays are deliberately excluded.
  List<AxCacheRecord> get baseRecords => [
        for (final item in _entries.entries)
          if (item.value.hasData && !item.value.legacyOptimistic)
            AxCacheRecord(item.key, item.value.data, item.value.fetched,
                item.value.accessed),
      ];

  /// Hydration never overwrites an existing value or an in-flight Cloud read.
  bool seed<T>(AxQuery<T> query, T data,
      {DateTime? fetched, DateTime? accessed}) {
    final entry = _entry(query);
    if (entry.hasData || entry.flight != null) return false;
    entry.data = data;
    entry.hasData = true;
    entry.fetched = fetched;
    entry.accessed = accessed;
    entry.invalidated = true;
    _notify(entry);
    return true;
  }

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
    entry.revalidate = () => refresh<T>(entry.query).then<void>((_) {});
    entry.visibleData = () => _state<T>(entry).data;
    _entries[query.key] = entry;
    scheduleRetention();
    return entry;
  }

  /// Valid across reads/patches, invalid after entity removal or session clearing.
  bool Function() fence(AxQueryKey key) {
    final entry = _entries[key];
    final reset = entry?.resetVersion;
    return () =>
        entry != null &&
        identical(_entries[key], entry) &&
        entry.resetVersion == reset;
  }

  bool _stale(_Entry<dynamic> entry) =>
      entry.invalidated ||
      entry.fetched == null ||
      _clock().difference(entry.fetched!) >= entry.query.staleTime;

  AxQueryState<T> _state<T>(_Entry<T> entry, {bool includeOptimistic = true}) {
    var state = AxQueryState<T>(
        data: entry.data,
        hasData: entry.hasData,
        isFetching: entry.flight != null,
        isStale: _stale(entry),
        lastFetchedAt: entry.fetched,
        lastAccessedAt: entry.accessed,
        error: entry.error,
        generation: entry.generation);
    if (includeOptimistic) {
      for (final transform in entry.optimistic.values) {
        state = AxQueryState<T>(
            data: transform(state),
            hasData: true,
            isFetching: state.isFetching,
            isStale: state.isStale,
            lastFetchedAt: state.lastFetchedAt,
            lastAccessedAt: state.lastAccessedAt,
            error: state.error,
            generation: state.generation);
      }
    }
    return state;
  }

  /// Independent overlay over the newest authoritative base, retained during
  /// realtime reads. Rollback removes only this operation's change.
  AxOptimisticUpdate<T> optimisticUpdate<T>(
      AxQuery<T> query, T Function(AxQueryState<T>) transform) {
    final entry = _entry(query);
    transform(_state(entry)); // Fail before publishing an invalid transform.
    final token = ++_nextOptimistic;
    final reset = entry.resetVersion;
    entry.optimistic[token] = transform;
    bool current() =>
        identical(_entries[query.key], entry) && entry.resetVersion == reset;
    _notify(entry);
    return AxOptimisticUpdate<T>(
      isCurrent: current,
      rollback: () {
        if (!current()) return;
        entry.optimistic.remove(token);
        _notify(entry);
      },
      commit: (change) {
        if (!current()) return;
        // Calculate before removing the overlay, from the current server base.
        final value = change(_state(entry, includeOptimistic: false));
        entry.optimistic.remove(token);
        ++entry.generation;
        entry.flight = null;
        entry.data = value;
        entry.hasData = true;
        entry.error = null;
        _notify(entry);
      },
    );
  }

  AxQueryState<T> peek<T>(AxQuery<T> query) {
    final entry = _entry(query);
    entry.accessed = _clock();
    return _state(entry);
  }

  /// Query-scoped observation. Does not fetch. Cancel is idempotent.
  /// Staleness is calculated on observation; no expiry timers are installed.
  void Function() watch<T>(
      AxQuery<T> query, void Function(AxQueryState<T>) listener,
      {bool fireImmediately = true, bool retain = true}) {
    final entry = _entry(query);
    entry.accessed = _clock();
    void notify() => listener(_state(entry));
    entry.listeners.add(notify);
    if (retain) entry.retentionObservers++;
    if (fireImmediately) notify();
    return () {
      if (entry.listeners.remove(notify) && retain) {
        entry.retentionObservers--;
      }
      scheduleRetention();
    };
  }

  void _notify(_Entry<dynamic> entry) {
    scheduleRetention();
    for (final listener in List.of(_cacheListeners)) {
      listener();
    }
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
    final visible = _state(entry);
    if (policy != AxCachePolicy.networkOnly && visible.hasData) {
      if (policy == AxCachePolicy.cacheAndNetwork && _stale(entry)) {
        // Background failures remain visible in query state, not unhandled.
        refresh(query)
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
      return Future.value(visible.data as T);
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
        entry.legacyOptimistic = false;
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

  /// Scope invalidation keeps cached data and immutable cursor pages intact.
  void invalidateScope(AxSyncScope scope) {
    for (final item in _entries.entries.toList()) {
      if (scope.matches(item.key)) {
        invalidate(item.key);
      }
    }
  }

  Iterable<AxQueryKey> get relevantKeys => _entries.entries
      .where((item) =>
          item.value.hasData ||
          item.value.flight != null ||
          item.value.listeners.isNotEmpty)
      .map((item) => item.key)
      .toList(growable: false);

  bool isObserved(AxQueryKey key) =>
      _entries[key]?.listeners.isNotEmpty ?? false;

  /// Refresh entries already marked stale without fencing the recovery itself.
  Future<void> refreshStaleWhere(bool Function(AxQueryKey) matches) async {
    final entries = _entries.entries
        .where((item) =>
            matches(item.key) &&
            item.value.invalidated &&
            (item.value.hasData ||
                item.value.listeners.isNotEmpty ||
                item.value.flight != null))
        .toList();
    await Future.wait(entries.map((item) => item.value.revalidate()));
  }

  /// Lifecycle recovery uses age and real view subscriptions, not internal
  /// history bridges. Cached values and ongoing requests remain intact.
  Future<void> refreshActiveStale() async {
    final entries = _entries.entries
        .where((item) {
          final key = item.key;
          final entry = item.value;
          if (_isHistory(key) && key.parts.length != 3) return false;
          final owner = _isHistory(key) ? _historyOwners[key.parts[2]] : null;
          final active = entry.retentionObservers > 0 ||
              (owner?.$1(key.parts[1]) ?? false);
          return active && _stale(entry);
        })
        .map((item) => item.value)
        .toList();
    await Future.wait(entries.map((entry) => entry.revalidate()));
  }

  /// Read existing collections without registering or loading new queries.
  Map<AxQueryKey, T> cachedValues<T>() => Map.unmodifiable({
        for (final item in _entries.entries)
          if (item.value.hasData && item.value.data is T)
            item.key: item.value.visibleData() as T,
      });

  /// Revalidate only registered, hydrated or observed queries. Older history
  /// pages are deliberately excluded by the caller's key predicate.
  Future<void> revalidateWhere(bool Function(AxQueryKey) matches) async {
    final entries = _entries.entries
        .where((item) =>
            matches(item.key) &&
            (item.value.hasData ||
                item.value.flight != null ||
                item.value.listeners.isNotEmpty))
        .toList();
    await Future.wait(entries.map((item) {
      invalidate(item.key);
      return item.value.revalidate();
    }));
  }

  Future<T> mutate<T>(AxMutation<T> mutation) {
    late _Entry<T> entry;
    late int generation;
    return mutations.run(AxMutationOperation<T, AxQueryState<T>>(
      rejectSuperseded: false,
      optimisticUpdate: () {
        entry = _entry(mutation.query);
        final previous = _state(entry);
        final optimistic = mutation.optimistic?.call(previous);
        generation = ++entry.generation;
        entry.flight = null;
        entry.error = null;
        entry.invalidated = true;
        if (mutation.optimistic != null) {
          entry.legacyOptimistic = true;
          entry.data = optimistic;
          entry.hasData = true;
        }
        _notify(entry);
        return previous;
      },
      isCurrent: (_) =>
          identical(_entries[mutation.query.key], entry) &&
          entry.generation == generation,
      execute: (_) => mutation.execute(),
      commit: (value, _) {
        entry.legacyOptimistic = false;
        entry.data = value;
        entry.hasData = true;
        entry.fetched = _clock();
        entry.invalidated = false;
        _notify(entry);
      },
      rollback: (error, _, previous) {
        entry.legacyOptimistic = false;
        entry.data = previous.data;
        entry.hasData = previous.hasData;
        entry.fetched = previous.lastFetchedAt;
        entry.error = error;
        _notify(entry);
      },
    ));
  }

  /// Reset in place to preserve active subscriptions and reject late writes.
  void remove(AxQueryKey key, {bool prefix = false}) {
    if (prefix) {
      for (final candidate in _entries.keys
          .where((candidate) => candidate.startsWith(key))
          .toList()) {
        remove(candidate);
      }
      return;
    }
    final entry = _entries[key];
    if (entry == null) return;
    ++entry.generation;
    ++entry.resetVersion;
    entry.clearOptimistic();
    entry.legacyOptimistic = false;
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
    mutations.reset();
    for (final key in _entries.keys.toList()) {
      remove(key);
    }
  }
}

/// A query-scoped mutation overlay, fenced by remove/clear rather than reads.
class AxOptimisticUpdate<T> {
  AxOptimisticUpdate(
      {required this.isCurrent, required this.commit, required this.rollback});
  final bool Function() isCurrent;
  final void Function(T Function(AxQueryState<T>) change) commit;
  final void Function() rollback;
}

class AxCacheRecord {
  const AxCacheRecord(this.key, this.data, this.fetched, this.accessed);
  final AxQueryKey key;
  final Object? data;
  final DateTime? fetched, accessed;
}

import 'dart:convert';
import 'ax_idempotency.dart';
import 'dart:async';
import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_sync_engine.dart';

class AxDiscussionHistory {
  AxDiscussionHistory(
      {Iterable<AxDiscussionMessage> messages = const [],
      this.olderCursor,
      this.newestCursor,
      this.initialLoaded = false,
      Iterable<String> deletedMessageIds = const []})
      : messages = List.unmodifiable(messages),
        deletedMessageIds = Set.unmodifiable(deletedMessageIds);
  final List<AxDiscussionMessage> messages;
  final String? olderCursor;
  final String? newestCursor;
  final bool initialLoaded;

  /// Locally observed server deletions. These tombstones prevent a stale
  /// in-flight read or persisted snapshot from resurrecting a message.
  final Set<String> deletedMessageIds;
}

class AxDiscussionState {
  const AxDiscussionState(
      {required this.messages,
      required this.hasData,
      required this.isFetching,
      required this.loadingOlder,
      this.olderCursor,
      this.error});
  final List<AxDiscussionMessage> messages;
  final bool hasData, isFetching, loadingOlder;
  final String? olderCursor;
  final Object? error;
}

class _DiscussionContext {
  final pending = <String, AxDiscussionMessage>{};
  final pendingDeletes = <String, int>{};
  final listeners = <void Function()>[];
  Future<void>? olderFlight;
  Object? olderError;
  Object? realtimeError;
  void Function()? cancel;
}

/// Session-owned paginated server history with independent message overlays.
/// Disposing a screen cancels its subscription, never its cached messages.
class AxDiscussionCache {
  AxDiscussionCache(this.source,
      {AxSyncEngine? engine, bool registerRetention = true})
      : engine = engine ?? AxSyncEngine() {
    if (registerRetention) {
      this
          .engine
          .registerHistoryOwner('discussion', isObserved, _evict, _compact);
    }
  }
  void _evict(String id) {
    final context = _contexts.remove(id);
    context?.cancel?.call();
  }

  void _compact(String id) {
    final history = engine.cachedValues<AxDiscussionHistory>()[query(id).key];
    if (history == null ||
        history.messages.length <= engine.maxRetainedHistoryItems) {
      return;
    }
    engine.update(
        query(id),
        (_) => AxDiscussionHistory(
            messages: history.messages
                .skip(history.messages.length - engine.maxRetainedHistoryItems),
            newestCursor: history.newestCursor,
            deletedMessageIds: history.deletedMessageIds));
    // Discussion cursors are opaque. Revalidate the head to obtain a safe
    // frontier rather than inventing a cursor for the retained oldest message.
    engine.invalidate(query(id).key);
  }

  final AxDataSource? source;
  final AxSyncEngine engine;
  static final _sources = Expando<AxDiscussionCache>();
  static AxDiscussionCache forSource(AxDataSource? source) {
    if (source == null) return AxDiscussionCache(null);
    return _sources[source] ??= AxDiscussionCache(source);
  }

  final _contexts = <String, _DiscussionContext>{};
  final _attempts = AxMutationAttempts();
  int _temporaryId = 0;

  _DiscussionContext _context(String id) => _contexts.putIfAbsent(id, () {
        final context = _DiscussionContext();
        context.cancel = engine.watch(query(id), (_) => _emit(context),
            fireImmediately: false, retain: false);
        return context;
      });
  void _emit(_DiscussionContext context) {
    engine.scheduleRetention();
    for (final listener in List.of(context.listeners)) {
      if (context.listeners.contains(listener)) listener();
    }
  }

  AxQuery<AxDiscussionHistory> query(String id,
          {bool reconcileNewest = true}) =>
      AxQuery(
        key: AxQueryKey(['thread', id, 'discussion']),
        load: () => _synchronize(id, reconcileNewest: reconcileNewest),
      );
  AxDiscussionHistory _history(String id) =>
      engine.peek(query(id)).data ?? AxDiscussionHistory();

  List<AxDiscussionMessage> _merge(
      Iterable<AxDiscussionMessage> old, Iterable<AxDiscussionMessage> added,
      {Iterable<String> deletedMessageIds = const []}) {
    final deleted = deletedMessageIds.toSet();
    final map = {
      for (final message in old)
        if (!deleted.contains(message.id)) message.id: message
    };
    for (final message in added) {
      if (deleted.contains(message.id)) continue;
      final previous = map[message.id];
      if (previous == null ||
          ((message.editedAt ?? message.createdAt)
                  .compareTo(previous.editedAt ?? previous.createdAt) >=
              0)) {
        map[message.id] = message;
      }
    }
    return map.values.toList()
      ..sort((a, b) {
        final time = a.createdAt.compareTo(b.createdAt);
        return time == 0 ? a.id.compareTo(b.id) : time;
      });
  }

  bool _isAtOrAfter(AxDiscussionMessage value, AxDiscussionMessage boundary) {
    final created = value.createdAt.compareTo(boundary.createdAt);
    return created > 0 ||
        (created == 0 && value.id.compareTo(boundary.id) >= 0);
  }

  Future<AxDiscussionHistory> _synchronize(String id,
      {required bool reconcileNewest, bool reconcileAll = false}) async {
    final previous = _history(id);
    final ds = source;
    if (ds == null) {
      return AxDiscussionHistory(
          messages: previous.messages,
          initialLoaded: true,
          deletedMessageIds: previous.deletedMessageIds);
    }
    final additions = <AxDiscussionMessage>[];
    String? newestCursor = previous.newestCursor;
    // Catch up every new page after the last known server anchor, so a long
    // absence cannot leave a hole between cached history and the newest window.
    if (previous.newestCursor != null) {
      String? cursor = previous.newestCursor;
      final seen = <String>{};
      while (cursor != null) {
        if (!seen.add(cursor)) {
          throw const AxApiException('Discussion cursor repeated');
        }
        final page = await ds.loadDiscussionPage(threadId: id, after: cursor);
        additions.addAll(page.messages);
        newestCursor = page.newestCursor ?? newestCursor;
        cursor = page.nextCursor;
      }
    }
    final forwardIds = additions.map((message) => message.id).toSet();
    // Reopening reconciles edits; reconnects need only new messages.
    final head = reconcileNewest || previous.newestCursor == null
        ? await ds.loadDiscussionPage(threadId: id)
        : null;
    if (head != null) additions.addAll(head.messages);
    var olderCursor =
        previous.initialLoaded ? previous.olderCursor : head?.nextCursor;
    if (reconcileAll && head != null) {
      var cursor = head.nextCursor;
      final seen = <String>{};
      while (cursor != null) {
        if (!seen.add(cursor)) {
          throw const AxApiException('Discussion cursor repeated');
        }
        final page = await ds.loadDiscussionPage(threadId: id, before: cursor);
        additions.addAll(page.messages);
        cursor = page.nextCursor;
      }
      olderCursor = null;
    }
    final current = _history(id);
    var messages = _merge(current.messages, additions,
        deletedMessageIds: current.deletedMessageIds);
    if (reconcileAll && head != null) {
      // A full reconciliation is authoritative for the complete history.
      // Keep only rows returned by the server (while still honoring local
      // deletion tombstones).
      final serverIds = additions.map((message) => message.id).toSet();
      messages =
          messages.where((message) => serverIds.contains(message.id)).toList();
    } else if (head != null && head.messages.isNotEmpty) {
      // The head page is authoritative only for its represented range. Do
      // not remove older pages merely because they are outside this window.
      final headIds = head.messages.map((message) => message.id).toSet();
      final oldest = head.messages.first;
      messages = messages
          .where((message) =>
              headIds.contains(message.id) ||
              forwardIds.contains(message.id) ||
              !_isAtOrAfter(message, oldest))
          .toList();
    }
    return AxDiscussionHistory(
        messages: messages,
        initialLoaded: true,
        deletedMessageIds: current.deletedMessageIds,
        olderCursor: olderCursor,
        newestCursor:
            head?.newestCursor ?? newestCursor ?? current.newestCursor);
  }

  AxDiscussionState peek(String id) {
    final state = engine.peek(query(id));
    final history = state.data ?? AxDiscussionHistory();
    final context = _context(id);
    final map = {
      for (final message in history.messages) message.id: message,
      ...context.pending
    };
    return AxDiscussionState(
        messages: List.unmodifiable(_merge(const [], map.values,
            deletedMessageIds: history.deletedMessageIds)),
        hasData: state.hasData ||
            history.initialLoaded ||
            context.pending.isNotEmpty,
        isFetching: state.isFetching,
        loadingOlder: context.olderFlight != null,
        olderCursor: history.olderCursor,
        error: context.realtimeError ?? context.olderError ?? state.error);
  }

  /// The engine subscription bridges cache notifications and survives disposal;
  /// only view listeners and pending writes make this Discussion active.
  bool isObserved(String id) {
    final context = _contexts[id];
    return context != null &&
        (context.listeners.isNotEmpty ||
            context.pending.isNotEmpty ||
            context.olderFlight != null);
  }

  void Function() watch(String id, void Function(AxDiscussionState) listener) {
    final context = _context(id);
    void callback() => listener(peek(id));
    context.listeners.add(callback);
    return () {
      context.listeners.remove(callback);
      engine.scheduleRetention();
    };
  }

  Future<AxDiscussionHistory> synchronize(String id,
      {bool reconcileNewest = true, bool reconcileAll = false}) {
    _context(id);
    final queryValue = query(id, reconcileNewest: reconcileNewest);
    if (!reconcileAll) return engine.refresh(queryValue);
    return engine.refresh(AxQuery<AxDiscussionHistory>(
        key: queryValue.key,
        load: () => _synchronize(id,
            reconcileNewest: reconcileNewest, reconcileAll: true)));
  }

  /// Changes to older loaded messages use one detail read; creation follows the
  /// existing forward cursor and never reloads immutable older pages.
  Future<void> reconcileSignal(String id, String type, String entityId) async {
    final context = _contexts[id];
    final ds = source;
    if (context == null || ds == null) return;
    if (type == 'discussion.created') {
      engine.invalidate(query(id).key);
      await synchronize(id, reconcileNewest: false);
      return;
    }
    if (type == 'discussion.deleted') {
      // A delete event is authoritative. Do not issue a detail read for a
      // record that no longer exists, and fence reads so an older response
      // cannot put it back into the cache.
      engine.update(query(id), (state) {
        final history = state.data ?? AxDiscussionHistory();
        final deleted = {...history.deletedMessageIds, entityId};
        context.pendingDeletes.remove(entityId);
        return AxDiscussionHistory(
            messages: history.messages.where((m) => m.id != entityId),
            initialLoaded: history.initialLoaded,
            olderCursor: history.olderCursor,
            newestCursor: history.newestCursor,
            deletedMessageIds: deleted);
      });
      context.realtimeError = null;
      _emit(context);
      return;
    }
    if (type != 'discussion.updated') return;
    if (!_history(id).messages.any((message) => message.id == entityId)) return;
    try {
      final message = await ds.loadDiscussionMessage(messageId: entityId);
      if (!identical(_contexts[id], context)) return;
      if (message.id != entityId || message.threadId != id) {
        throw const AxApiException('Discussion message identity mismatch');
      }
      context.realtimeError = null;
      engine.update(query(id), (state) {
        final history = state.data ?? AxDiscussionHistory();
        return AxDiscussionHistory(
            messages: _merge(history.messages, [message]),
            initialLoaded: history.initialLoaded,
            olderCursor: history.olderCursor,
            newestCursor: history.newestCursor,
            deletedMessageIds: history.deletedMessageIds);
      });
    } catch (error) {
      if (identical(_contexts[id], context)) {
        context.realtimeError = error;
        _emit(context);
      }
      rethrow;
    }
  }

  void _background(String id) {
    unawaited(synchronize(id)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> loadOlder(String id) {
    final context = _context(id);
    if (context.olderFlight != null) return context.olderFlight!;
    final cursor = _history(id).olderCursor;
    if (cursor == null || source == null) return Future.value();
    final completer = Completer<void>();
    context.olderFlight = completer.future;
    context.olderError = null;
    _emit(context);
    () async {
      try {
        final page =
            await source!.loadDiscussionPage(threadId: id, before: cursor);
        if (page.nextCursor == cursor) {
          throw const AxApiException('Discussion cursor repeated');
        }
        if (identical(_contexts[id], context)) {
          engine.update(query(id), (state) {
            final current = state.data ?? AxDiscussionHistory();
            return AxDiscussionHistory(
                messages: _merge(current.messages, page.messages,
                    deletedMessageIds: current.deletedMessageIds),
                initialLoaded: current.initialLoaded,
                olderCursor: page.nextCursor,
                newestCursor: current.newestCursor,
                deletedMessageIds: current.deletedMessageIds);
          });
        }
        completer.complete();
      } catch (error, stack) {
        if (identical(_contexts[id], context)) context.olderError = error;
        completer.completeError(error, stack);
      } finally {
        context.olderFlight = null;
        if (identical(_contexts[id], context)) _emit(context);
      }
    }();
    return completer.future;
  }

  void _patch(String id, AxDiscussionMessage message) {
    engine.update(query(id), (state) {
      final current = state.data ?? AxDiscussionHistory();
      final messages = {
        for (final value in current.messages) value.id: value,
        message.id: message
      };
      return AxDiscussionHistory(
          messages: _merge(const [], messages.values,
              deletedMessageIds: current.deletedMessageIds),
          initialLoaded: current.initialLoaded,
          olderCursor: current.olderCursor,
          newestCursor: current.newestCursor,
          deletedMessageIds: current.deletedMessageIds);
    });
  }

  Future<void> send(String id, String text,
      {String? userId,
      String? userName,
      List<Map<String, dynamic>> attachments = const []}) async {
    final context = _context(id);
    final scope = 'thread:$id:send-discussion';
    final payload = jsonEncode([text, attachments]);
    final key = _attempts.keyFor(scope, payload);
    final temp = AxDiscussionMessage(
        id: 'temp-${DateTime.now().microsecondsSinceEpoch}-${++_temporaryId}',
        threadId: id,
        authorUserId: userId ?? '',
        authorName: userName ?? 'You',
        body: text,
        attachments: attachments,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        isMe: true);
    final fence = engine.fence(query(id).key);
    return engine.mutations
        .run(AxMutationOperation<AxDiscussionMessage, _DiscussionContext>(
          rejectSuperseded: false,
          key: AxQueryKey(['mutation', 'discussion-send', key]),
          optimisticUpdate: () {
            context.pending[temp.id] = temp;
            _emit(context);
            return context;
          },
          isCurrent: (context) => identical(_contexts[id], context) && fence(),
          execute: (_) async {
            final saved = source == null
                ? temp.copyWith(id: temp.id.replaceFirst('temp-', 'local-'))
                : await source!.sendDiscussionMessage(
                    threadId: id,
                    text: text,
                    attachments: attachments,
                    idempotencyKey: key);
            if (saved.id.isEmpty || saved.threadId != id) {
              throw const AxApiException(
                  'Discussion response identity does not match');
            }
            return saved;
          },
          commit: (saved, context) {
            _attempts.complete(scope, payload, key);
            context.pending.remove(temp.id);
            _patch(id, saved);
          },
          rollback: (_, __, context) {
            context.pending.remove(temp.id);
            _emit(context);
          },
          invalidate: (_, __) async {
            _background(id);
          },
        ))
        .then<void>((_) {});
  }

  Future<void> edit(String id, String messageId, String text) async {
    final context = _context(id);
    if (context.pending.containsKey(messageId)) {
      throw StateError('Message update already pending');
    }
    final original =
        _history(id).messages.where((m) => m.id == messageId).firstOrNull;
    if (original == null) throw StateError('Message is not saved');
    final fence = engine.fence(query(id).key);
    return engine.mutations
        .run(AxMutationOperation<AxDiscussionMessage, _DiscussionContext>(
          key: AxQueryKey(['mutation', 'discussion', messageId]),
          rejectSuperseded: false,
          optimisticUpdate: () {
            context.pending[messageId] = original.copyWith(body: text);
            _emit(context);
            return context;
          },
          isCurrent: (context) => identical(_contexts[id], context) && fence(),
          execute: (_) async {
            final saved = source == null
                ? original.copyWith(body: text)
                : await source!.editDiscussionMessage(
                    messageId: messageId,
                    text: text,
                    references: original.references);
            if (saved.id != messageId || saved.threadId != id) {
              throw const AxApiException(
                  'Discussion response identity does not match');
            }
            return saved;
          },
          commit: (saved, context) {
            context.pending.remove(messageId);
            _patch(id, saved);
          },
          rollback: (_, __, context) {
            context.pending.remove(messageId);
            _emit(context);
          },
          invalidate: (_, __) async {
            _background(id);
          },
        ))
        .then<void>((_) {});
  }

  Future<void> delete(String id, String messageId) async {
    if (source == null) {
      final original =
          _history(id).messages.where((m) => m.id == messageId).firstOrNull;
      if (original != null) {
        _patch(
            id,
            AxDiscussionMessage(
                id: original.id,
                threadId: id,
                authorUserId: original.authorUserId,
                authorName: original.authorName,
                body: 'Message removed',
                createdAt: original.createdAt,
                isMe: original.isMe,
                eventType: 'message.removed',
                editedAt: DateTime.now().toUtc().toIso8601String()));
      }
      return;
    }
    try {
      await source!.deleteDiscussionMessage(messageId: messageId);
    } on AxApiException catch (error) {
      if (error.statusCode != 404) rethrow;
      await reconcileSignal(id, 'discussion.deleted', messageId);
      return;
    }
    await reconcileSignal(id, 'discussion.updated', messageId);
  }

  /// Clears the Thread's Chat remotely first; a failure preserves the visible
  /// history. The server may hold messages this session never loaded, so an
  /// empty local history still calls the server.
  Future<void> clearHistory(String id) async {
    await source?.clearThreadChatHistory(threadId: id);
    resetHistory(id);
    await synchronize(id);
  }

  /// Apply a confirmed remote clear: tombstone every known message so a stale
  /// in-flight read cannot bring it back.
  void resetHistory(String id) {
    final history = _history(id);
    final context = _context(id);
    final deletedIds = {
      ...history.deletedMessageIds,
      // A delayed self-clear event may arrive after its replacement notice
      // has already been fetched. Drop the view, but let that notice reload.
      ...history.messages
          .where((m) => m.eventType != 'conversation.cleared')
          .map((m) => m.id),
    };

    engine.update(
      query(id),
      (_) => AxDiscussionHistory(
        deletedMessageIds: deletedIds,
        initialLoaded: true,
      ),
    );

    _emit(context);
  }

  /// Session boundary only; never call from widget disposal.
  void clear() {
    _attempts.clear();
    final ids = _contexts.keys.toList();
    for (final context in _contexts.values) {
      context.cancel?.call();
      context.pending.clear();
      context.pendingDeletes.clear();
    }
    _contexts.clear();
    for (final id in ids) {
      engine.remove(query(id).key);
    }
  }
}

import 'package:web/web.dart' as web;

import 'ax_thread_view_state.dart';
import 'ax_thread_view_state_store_base.dart';

AxThreadViewStateStore createAxThreadViewStateStore() =>
    LocalStorageAxThreadViewStateStore();

/// Browser-local persistence for Thread view state. Cloud never sees this.
class LocalStorageAxThreadViewStateStore implements AxThreadViewStateStore {
  static const _prefix = 'conclave-ax-thread-view-v1:';

  String _key(String userId, String threadId) =>
      '$_prefix${Uri.encodeComponent(userId)}:${Uri.encodeComponent(threadId)}';

  @override
  Future<AxThreadViewState?> load({
    required String userId,
    required String threadId,
  }) async {
    try {
      final raw = web.window.localStorage.getItem(_key(userId, threadId));
      return raw == null ? null : AxThreadViewState.decode(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save({
    required String userId,
    required String threadId,
    required AxThreadViewState state,
  }) async {
    try {
      web.window.localStorage.setItem(_key(userId, threadId), state.encode());
    } catch (_) {
      // Browser storage can be disabled or full; view state remains in memory.
    }
  }

  @override
  Future<void> clearUser(String userId) async {
    final userPrefix = '$_prefix${Uri.encodeComponent(userId)}:';
    try {
      final keys = <String>[];
      final storage = web.window.localStorage;
      for (var index = 0; index < storage.length; index++) {
        final key = storage.key(index);
        if (key != null && key.startsWith(userPrefix)) keys.add(key);
      }
      for (final key in keys) {
        storage.removeItem(key);
      }
    } catch (_) {
      // Best effort; no server state is affected.
    }
  }

  @override
  void dispose() {}
}

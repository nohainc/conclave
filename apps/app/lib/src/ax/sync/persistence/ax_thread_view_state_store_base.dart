import 'ax_thread_view_state.dart';

abstract interface class AxThreadViewStateStore {
  Future<AxThreadViewState?> load({
    required String userId,
    required String threadId,
  });

  Future<void> save({
    required String userId,
    required String threadId,
    required AxThreadViewState state,
  });

  Future<void> clearUser(String userId);
  void dispose();
}

/// In-memory fallback for non-browser targets and deterministic tests.
class MemoryAxThreadViewStateStore implements AxThreadViewStateStore {
  final _values = <String, Map<String, AxThreadViewState>>{};

  @override
  Future<AxThreadViewState?> load({
    required String userId,
    required String threadId,
  }) async =>
      _values[userId]?[threadId];

  @override
  Future<void> save({
    required String userId,
    required String threadId,
    required AxThreadViewState state,
  }) async {
    (_values[userId] ??= {})[threadId] = state;
  }

  @override
  Future<void> clearUser(String userId) async => _values.remove(userId);

  @override
  void dispose() => _values.clear();
}

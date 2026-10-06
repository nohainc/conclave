import 'ax_query.dart';

/// A targeted optimistic mutation. Queries affected indirectly can be
/// invalidated by the caller after the authoritative operation succeeds.
class AxMutation<T> {
  const AxMutation(
      {required this.query, required this.execute, this.optimistic});
  final AxQuery<T> query;
  final Future<T> Function() execute;
  final T Function(AxQueryState<T> previous)? optimistic;
}

/// One explicit mutation attempt. Invalidation reconciles confirmed writes;
/// a failed reconciliation must never roll back or replay the server operation.
class AxMutationOperation<Result, Context> {
  const AxMutationOperation({
    required this.optimisticUpdate,
    required this.execute,
    required this.commit,
    required this.rollback,
    required this.isCurrent,
    this.invalidate,
    this.cancel,
    this.key,
    this.rejectSuperseded = true,
  });
  final Context Function() optimisticUpdate;
  final Future<Result> Function(Context context) execute;
  final void Function(Result result, Context context) commit;
  final void Function(Object error, StackTrace stack, Context context) rollback;
  final bool Function(Context context) isCurrent;
  final Future<void> Function(Result result, Context context)? invalidate;
  final void Function(Context context)? cancel;
  final Object? key;
  final bool rejectSuperseded;
}

class AxMutationSuperseded implements Exception {
  const AxMutationSuperseded();
  @override
  String toString() =>
      'Mutation no longer belongs to the current session/entity';
}

/// No retry queue, persistence, backoff, or connectivity replay. Duplicate
/// operations with the same key are rejected instead of starting another POST.
class AxMutationRunner {
  final _running = <Object, Object>{};
  void reset() => _running.clear();
  bool isRunning(Object key) => _running.containsKey(key);

  Future<Result> run<Result, Context>(
      AxMutationOperation<Result, Context> operation) async {
    final key = operation.key;
    if (key != null && _running.containsKey(key)) {
      throw StateError('Mutation already pending');
    }
    final lease = Object();
    if (key != null) _running[key] = lease;
    try {
      final context = operation.optimisticUpdate();
      if (!operation.isCurrent(context)) {
        operation.cancel?.call(context);
        throw const AxMutationSuperseded();
      }
      late Result result;
      try {
        // Exactly one call, including on ambiguous network failures.
        result = await operation.execute(context);
      } catch (error, stack) {
        if (operation.isCurrent(context)) {
          operation.rollback(error, stack, context);
        } else {
          operation.cancel?.call(context);
        }
        rethrow;
      }
      if (!operation.isCurrent(context)) {
        operation.cancel?.call(context);
        if (operation.rejectSuperseded) throw const AxMutationSuperseded();
        return result;
      }
      operation.commit(result, context);
      if (operation.isCurrent(context) && operation.invalidate != null) {
        try {
          await operation.invalidate!(result, context);
        } catch (_) {
          // Reads expose their own error state. The server write succeeded.
        }
      }
      return result;
    } finally {
      if (key != null && identical(_running[key], lease)) _running.remove(key);
    }
  }
}

import 'dart:async';

class WorkerDeadlineController {
  WorkerDeadlineController(
    Duration timeout, {
    FutureOr<void> Function()? onCancel,
  }) : _deadline = DateTime.now().add(timeout),
       _onCancel = onCancel;

  final DateTime _deadline;
  final FutureOr<void> Function()? _onCancel;
  final Completer<void> _cancelled = Completer<void>();

  Duration get remaining {
    final duration = _deadline.difference(DateTime.now());
    return duration.isNegative ? Duration.zero : duration;
  }

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  Future<T> run<T>(Future<T> Function() action) async {
    if (isCancelled) throw const WorkerCancelledException();
    if (remaining == Duration.zero)
      throw TimeoutException('Worker deadline exceeded');
    return Future.any([
      action().timeout(remaining),
      _cancelled.future.then<T>((_) async {
        await _onCancel?.call();
        throw const WorkerCancelledException();
      }),
    ]);
  }
}

class WorkerCancelledException implements Exception {
  const WorkerCancelledException();

  @override
  String toString() => 'Worker assignment was cancelled';
}

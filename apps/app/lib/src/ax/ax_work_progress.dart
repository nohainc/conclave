import 'ax_work_activity.dart';

/// Presentation-ready live progress for one Worker response.
///
/// The Work Request status is authoritative for the status chip and for every
/// lifecycle decision. Worker Activity is the faster, observational signal: it
/// supplies the current action, the execution start time and liveness. Activity
/// never advances a request state and never marks a request terminal.
///
/// This is a pure value so the combination rules are testable without a
/// widget tree. The caller supplies `now`; nothing here reads the clock.
class AxWorkProgress {
  const AxWorkProgress._({
    required this.status,
    required this.statusLabel,
    required this.currentAction,
    required this.startedAt,
    required this.endedAt,
    required this.serverElapsed,
    required this.isTerminal,
    required this.isExecuting,
    required this.isOptimistic,
    required this.isStale,
    required this.lastSignalAt,
    required this.stoppedWithoutResponse,
  });

  /// Request statuses after which no further execution progress is expected.
  static const terminalStatuses = {
    'completed',
    'failed',
    'cancelled',
    'timed_out',
    'lost',
  };

  /// How long a running execution may stay silent before the header says so.
  static const defaultStaleAfter = Duration(seconds: 45);

  /// Effective status key from the authoritative Work Request projection.
  final String status;
  final String statusLabel;

  /// One line describing what the Worker is doing now. Null once terminal.
  final String? currentAction;

  /// Execution start on this device's clock, when known.
  final DateTime? startedAt;

  /// Terminal execution time on this device's clock, when a terminal activity
  /// was received. Freezes the elapsed time before the request status catches
  /// up.
  final DateTime? endedAt;

  /// Server-reported duration, used when activity timestamps are unavailable.
  final Duration? serverElapsed;

  final bool isTerminal;

  /// True while the Worker flow shows an execution in progress for the
  /// request, even before the request or step status has caught up. Used to
  /// attribute the response to the Worker as soon as it starts.
  final bool isExecuting;

  /// Kept as a projection field for callers that render diagnostic metadata.
  /// It is always false because activity is observational, not authoritative.
  final bool isOptimistic;

  /// True when the execution is running but has been silent for too long.
  final bool isStale;

  final DateTime? lastSignalAt;

  /// True when the request failed and no Worker activity ever arrived.
  final bool stoppedWithoutResponse;

  /// The header ticks and shows elapsed time only for unfinished requests.
  /// Terminal requests show the server-reported duration elsewhere.
  bool get showsLiveElapsed => !isTerminal && startedAt != null;

  /// True while a timer should keep the elapsed value current.
  bool get isTicking => showsLiveElapsed && endedAt == null;

  factory AxWorkProgress.resolve({
    required String requestStatus,
    required List<AxWorkActivity> activities,
    required DateTime now,
    DateTime? stepStartedAt,
    int? serverElapsedMs,
    Duration clockOffset = Duration.zero,
    Duration staleAfter = defaultStaleAfter,
  }) {
    final terminal = terminalStatuses.contains(requestStatus);

    // Only the latest attempt describes the current execution. A retry must
    // not inherit the failed attempt's action or start time.
    final attemptId = activities.isEmpty ? null : activities.last.attemptId;
    final attempt = attemptId == null
        ? const <AxWorkActivity>[]
        : activities.where((a) => a.attemptId == attemptId).toList();
    final terminalExecution =
        attempt.where((a) => a.isTerminalExecution).lastOrNull;
    // Provider diagnostics describe the adapter, not the Worker's work, so they
    // never become the current action.
    final unfinished = attempt
        .where((a) =>
            !a.isFinished &&
            a.type != 'execution.started' &&
            a.details['diagnostic'] == null)
        .lastOrNull;

    DateTime shift(DateTime value) => value.add(clockOffset);

    final startActivity =
        attempt.where((a) => a.type == 'execution.started').firstOrNull ??
            attempt.firstOrNull;
    final startedAt =
        startActivity != null ? shift(startActivity.timestamp) : stepStartedAt;
    final endedAt =
        terminalExecution != null ? shift(terminalExecution.timestamp) : null;
    final lastSignalAt = attempt.isEmpty
        ? null
        : shift(attempt
            .map((a) => a.timestamp)
            .reduce((a, b) => a.isAfter(b) ? a : b));

    final status = requestStatus;
    const optimistic = false;

    // A terminal marker from a previous attempt may still be present while a
    // retry is queued. It must not make the new attempt look like it is
    // wrapping up; only an already-started authoritative request can do that.
    final wrappingUp = !terminal &&
        terminalExecution != null &&
        !const {'queued', 'starting', 'acknowledged'}.contains(requestStatus);
    String? action;
    if (!terminal) {
      if (wrappingUp) {
        action = 'Wrapping up…';
      } else if (unfinished != null) {
        action = unfinished.title;
      } else {
        action = switch (status) {
          'queued' || 'starting' || 'acknowledged' => 'Starting worker…',
          'running' => 'Working…',
          'waiting' => 'Waiting to continue…',
          _ => 'Recovering worker connection…',
        };
      }
    }

    final stale = !terminal &&
        status == 'running' &&
        !wrappingUp &&
        lastSignalAt != null &&
        now.difference(lastSignalAt) > staleAfter;

    return AxWorkProgress._(
      status: status,
      statusLabel: _label(status),
      currentAction: action,
      startedAt: startedAt,
      endedAt: endedAt,
      serverElapsed: serverElapsedMs == null
          ? null
          : Duration(milliseconds: serverElapsedMs),
      isTerminal: terminal,
      isExecuting: !terminal && attempt.isNotEmpty,
      isOptimistic: optimistic,
      isStale: stale,
      lastSignalAt: lastSignalAt,
      stoppedWithoutResponse:
          const {'failed', 'timed_out', 'lost'}.contains(requestStatus) &&
              activities.isEmpty,
    );
  }

  /// Elapsed time at [now]. Never negative, even with clock skew.
  Duration? elapsedAt(DateTime now) {
    final start = startedAt;
    if (start == null) return isTerminal ? serverElapsed : null;
    final end = endedAt ?? (isTerminal ? null : now);
    if (end == null) return serverElapsed;
    final value = end.difference(start);
    return value.isNegative ? Duration.zero : value;
  }

  static String formatDuration(Duration value) {
    final seconds = value.inSeconds.clamp(0, 864000);
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  static String _label(String status) => switch (status) {
        'queued' => 'Queued',
        'starting' || 'acknowledged' => 'Starting',
        'running' => 'Running',
        'waiting' => 'Waiting',
        'recovering' => 'Recovering',
        'completed' => 'Completed',
        'failed' => 'Failed',
        'cancelled' => 'Cancelled',
        'timed_out' => 'Timed out',
        'lost' => 'Lost',
        _ => 'Recovering',
      };
}

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/ax/ax_work_activity.dart';
import 'package:conclave_app/src/ax/ax_work_progress.dart';

final _base = DateTime.utc(2026, 10, 13, 12);

AxWorkActivity activity(
  int sequence,
  String type, {
  String status = 'running',
  String title = 'Working step',
  String attempt = 'attempt-1',
  int atSeconds = 0,
}) =>
    AxWorkActivity(
      eventId: 'event-$attempt-$sequence',
      assignmentId: 'assignment-1',
      attemptId: attempt,
      executionId: 'execution-1',
      workerId: 'chatgpt',
      activitySequence: sequence,
      streamSequence: sequence,
      type: type,
      status: status,
      title: title,
      timestamp: _base.add(Duration(seconds: atSeconds)),
      activityId: type.startsWith('tool.') ? 'tool-$sequence' : null,
    );

AxWorkProgress resolve(
  String status,
  List<AxWorkActivity> activities, {
  int nowSeconds = 10,
  DateTime? stepStartedAt,
  int? serverElapsedMs,
  Duration clockOffset = Duration.zero,
}) =>
    AxWorkProgress.resolve(
      requestStatus: status,
      activities: activities,
      now: _base.add(Duration(seconds: nowSeconds)),
      stepStartedAt: stepStartedAt,
      serverElapsedMs: serverElapsedMs,
      clockOffset: clockOffset,
    );

void main() {
  test('keeps a pre-start request in its authoritative Cloud state', () {
    final progress = resolve('queued', [
      activity(1, 'execution.started', title: 'Execution started'),
      activity(2, 'tool.started', title: 'Reading files', atSeconds: 2),
    ]);

    expect(progress.status, 'queued');
    expect(progress.statusLabel, 'Queued');
    expect(progress.isOptimistic, isFalse);
    expect(progress.currentAction, 'Reading files');
  });

  test('does not promote a retry queued after a failed attempt', () {
    final progress = resolve('queued', [
      activity(1, 'execution.started'),
      activity(2, 'execution.failed', status: 'failed', atSeconds: 3),
    ]);

    expect(progress.status, 'queued');
    expect(progress.isOptimistic, isFalse);
    expect(progress.currentAction, 'Starting worker…');
  });

  test('uses only the latest attempt for the current action and start', () {
    final progress = resolve(
      'running',
      [
        activity(1, 'execution.started', attempt: 'attempt-1'),
        activity(2, 'tool.started',
            title: 'Old attempt tool', attempt: 'attempt-1', atSeconds: 1),
        activity(3, 'execution.started', attempt: 'attempt-2', atSeconds: 20),
        activity(4, 'tool.started',
            title: 'New attempt tool', attempt: 'attempt-2', atSeconds: 21),
      ],
      nowSeconds: 25,
    );

    expect(progress.currentAction, 'New attempt tool');
    expect(progress.elapsedAt(_base.add(const Duration(seconds: 25))),
        const Duration(seconds: 5));
  });

  test('falls back to a generic action between tools', () {
    final progress = resolve('running', [
      activity(1, 'execution.started', status: 'completed'),
      activity(2, 'tool.completed', status: 'completed', atSeconds: 1),
    ]);

    expect(progress.currentAction, 'Working…');
  });

  test('a terminal activity freezes elapsed time but not the request status',
      () {
    final activities = [
      activity(1, 'execution.started'),
      activity(2, 'execution.completed', status: 'completed', atSeconds: 8),
    ];
    final progress = resolve('running', activities, nowSeconds: 30);

    expect(progress.status, 'running');
    expect(progress.isTerminal, isFalse);
    expect(progress.currentAction, 'Wrapping up…');
    expect(progress.isTicking, isFalse);
    expect(progress.showsLiveElapsed, isTrue);
    expect(progress.elapsedAt(_base.add(const Duration(seconds: 30))),
        const Duration(seconds: 8));
    expect(progress.elapsedAt(_base.add(const Duration(minutes: 5))),
        const Duration(seconds: 8));
  });

  test('request status is authoritative once terminal', () {
    final progress = resolve(
      'completed',
      [activity(1, 'tool.started', title: 'Still marked running')],
      serverElapsedMs: 12000,
    );

    expect(progress.statusLabel, 'Completed');
    expect(progress.currentAction, isNull);
    expect(progress.showsLiveElapsed, isFalse);
    expect(progress.isTicking, isFalse);
    expect(progress.isOptimistic, isFalse);
  });

  test('uses the server duration when a terminal request has no timestamps',
      () {
    final progress = resolve('failed', const [], serverElapsedMs: 4000);

    expect(progress.stoppedWithoutResponse, isTrue);
    expect(progress.elapsedAt(_base), const Duration(seconds: 4));
  });

  test('applies clock offset and never reports negative elapsed time', () {
    final shifted = resolve(
      'running',
      [activity(1, 'execution.started')],
      nowSeconds: 10,
      clockOffset: const Duration(seconds: 3),
    );
    expect(shifted.elapsedAt(_base.add(const Duration(seconds: 10))),
        const Duration(seconds: 7));

    final future = resolve(
      'running',
      [activity(1, 'execution.started')],
      nowSeconds: 1,
      clockOffset: const Duration(seconds: 30),
    );
    expect(
        future.elapsedAt(_base.add(const Duration(seconds: 1))), Duration.zero);
  });

  test('marks a silent running execution as stale only after the threshold',
      () {
    final activities = [activity(1, 'tool.started', title: 'Long build')];

    expect(resolve('running', activities, nowSeconds: 30).isStale, isFalse);
    final stale = resolve('running', activities, nowSeconds: 90);
    expect(stale.isStale, isTrue);
    expect(stale.currentAction, 'Long build');
  });

  test('uses the step start time for workers that emit no activity', () {
    final progress = resolve(
      'running',
      const [],
      stepStartedAt: _base,
      nowSeconds: 6,
    );

    expect(progress.currentAction, 'Working…');
    expect(progress.isTicking, isTrue);
    expect(progress.elapsedAt(_base.add(const Duration(seconds: 6))),
        const Duration(seconds: 6));
    expect(progress.isStale, isFalse);
  });

  test('shows no elapsed time before any start time is known', () {
    final progress = resolve('queued', const []);

    expect(progress.showsLiveElapsed, isFalse);
    expect(progress.elapsedAt(_base), isNull);
    expect(progress.currentAction, 'Starting worker…');
  });

  test('reports an execution in progress while the request has not caught up',
      () {
    final live = resolve('running', [activity(1, 'tool.started')]);
    expect(live.isExecuting, isTrue);

    expect(resolve('running', const []).isExecuting, isFalse);
    expect(resolve('completed', [activity(1, 'tool.started')]).isExecuting,
        isFalse);
  });

  test('never shows a provider diagnostic as the current action', () {
    final diagnostic = AxWorkActivity(
      eventId: 'diagnostic',
      assignmentId: 'assignment-1',
      attemptId: 'attempt-1',
      executionId: 'execution-1',
      workerId: 'gemini',
      activitySequence: 2,
      streamSequence: 2,
      type: 'model.status',
      status: 'updated',
      title: 'Provider activity needs attention',
      timestamp: _base.add(const Duration(seconds: 2)),
      details: const {'diagnostic': 'unsupported_step_type'},
    );

    expect(
      resolve('running', [
        activity(1, 'tool.started', title: 'Reading files'),
        diagnostic
      ]).currentAction,
      'Reading files',
    );
    expect(resolve('running', [diagnostic]).currentAction, 'Working…');
  });

  test('keeps the model narration as the headline while a tool runs', () {
    final narration = AxWorkActivity(
      eventId: 'narration-1',
      assignmentId: 'assignment-1',
      attemptId: 'attempt-1',
      executionId: 'execution-1',
      workerId: 'claude',
      activitySequence: 2,
      streamSequence: 2,
      type: 'message.updated',
      status: 'updated',
      title: 'Step 4: running sleep 20',
      timestamp: _base.add(const Duration(seconds: 2)),
      activityId: 'claude-msg-1',
      details: const {'preview': 'Step 4: running sleep 20'},
    );

    expect(
      resolve('running', [
        activity(1, 'execution.started'),
        narration,
      ]).currentAction,
      'Step 4: running sleep 20',
    );
    expect(
      resolve('running', [
        activity(1, 'execution.started'),
        narration,
        activity(3, 'tool.started', title: 'Running a command', atSeconds: 3),
      ]).currentAction,
      'Step 4: running sleep 20 · Running a command',
    );
  });

  test('shows narration over an older thinking marker, not a newer one', () {
    AxWorkActivity narrationAt(int sequence) => AxWorkActivity(
          eventId: 'narration-$sequence',
          assignmentId: 'assignment-1',
          attemptId: 'attempt-1',
          executionId: 'execution-1',
          workerId: 'claude',
          activitySequence: sequence,
          // Live-only events carry stream sequence 0.
          streamSequence: 0,
          type: 'message.updated',
          status: 'updated',
          title: 'Step 2: reading the README',
          timestamp: _base.add(Duration(seconds: sequence)),
          activityId: 'claude-msg-$sequence',
          details: const {'preview': 'Step 2: reading the README'},
        );
    final thinking = activity(1, 'model.started', title: 'Thinking');

    expect(
      resolve('running', [narrationAt(5), thinking]).currentAction,
      'Step 2: reading the README',
    );
    expect(
      resolve('running', [narrationAt(0), thinking]).currentAction,
      'Thinking',
    );
  });
}

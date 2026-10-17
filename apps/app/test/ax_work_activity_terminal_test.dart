import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/ax/ax_work_activity.dart';
import 'package:conclave_app/src/ax/ax_work_models.dart';
import 'package:conclave_app/src/ax/ax_work_progress.dart';

void main() {
  test('does not show an unfinished activity after terminal failure', () {
    final store = AxWorkActivityStore();
    final request = AxWorkRequest.fromJson({
      'id': 'request-1',
      'prompt': 'inspect the repository',
      'workflowId': 'direct',
      'workflowVersion': 1,
      'status': 'failed',
      'createdAt': '2026-10-13T00:00:00Z',
      'requestedByName': 'Team member',
      'steps': [
        {
          'kind': 'implement',
          'status': 'failed',
          'assignmentId': 'assignment-1',
          'workerId': 'worker-1',
        },
      ],
      'activities': [
        {
          'eventId': 'tool-started',
          'assignmentId': 'assignment-1',
          'attemptId': 'attempt-1',
          'executionId': 'execution-1',
          'workerId': 'chatgpt',
          'activitySequence': 1,
          'activityType': 'tool.started',
          'activityStatus': 'running',
          'title': 'Running repository checks',
          'timestamp': '2026-10-13T00:00:01Z',
        },
      ],
    });

    final activities = store.forRequest(request);
    expect(activities.single.status, 'interrupted');

    final progress = AxWorkProgress.resolve(
      requestStatus: request.status,
      activities: activities,
      now: DateTime.utc(2026, 10, 13, 0, 1),
    );
    expect(progress.statusLabel, 'Failed');
    expect(progress.currentAction, isNull);
    expect(progress.isExecuting, isFalse);
  });

  test('lifecycle rows of a completed request are not shown as failed', () {
    final store = AxWorkActivityStore();
    Map<String, Object?> row(String id, String type, String status, int n) => {
          'eventId': id,
          'assignmentId': 'assignment-1',
          'attemptId': 'attempt-1',
          'executionId': 'execution-1',
          'workerId': 'chatgpt',
          'activitySequence': n,
          'activityType': type,
          'activityStatus': status,
          'title': id,
          'timestamp': '2026-10-13T00:00:0${n}Z',
        };
    final request = AxWorkRequest.fromJson({
      'id': 'request-2',
      'prompt': 'say hi',
      'workflowId': 'direct',
      'workflowVersion': 1,
      'status': 'completed',
      'createdAt': '2026-10-13T00:00:00Z',
      'requestedByName': 'Team member',
      'steps': [
        {
          'kind': 'implement',
          'status': 'completed',
          'assignmentId': 'assignment-1',
          'workerId': 'worker-1',
        },
      ],
      'activities': [
        row('started', 'execution.started', 'running', 1),
        row('thinking', 'model.started', 'running', 2),
        row('writing', 'message.updated', 'updated', 3),
        row('done', 'execution.completed', 'completed', 4),
      ],
    });
    final activities = store.forRequest(request);
    expect(activities, hasLength(4));
    expect(activities.where((a) => a.isError), isEmpty);
    expect(activities.every((a) => a.isFinished), isTrue);
  });
}

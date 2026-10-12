import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/ax/ax_work_activity.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';

Map<String, dynamic> activityEvent({
  required String eventId,
  required int streamSequence,
  required int activitySequence,
  required String type,
  required String status,
  String activityId = 'tool-1',
  String title = 'Running repository checks',
}) =>
    {
      'eventId': eventId,
      'type': 'assignment.activity',
      'version': '1.0',
      'timestamp': DateTime.utc(2026, 10, 12, 18)
          .add(Duration(seconds: activitySequence))
          .toIso8601String(),
      'workspaceId': 'workspace-1',
      'threadId': 'thread-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'workspaceRuntimeId': 'runtime-1',
      'sequence': streamSequence,
      'payload': {
        'entityId': 'assignment-1',
        'workerId': 'chatgpt',
        'sourceEventId': eventId,
        'executionId': 'execution-1',
        'activityId': activityId,
        'activitySequence': activitySequence,
        'activityType': type,
        'activityStatus': status,
        'title': title,
        if (type == 'tool.started') 'details': {'toolName': 'shell'},
      },
    };

void main() {
  test('deduplicates replay and updates the matching tool row', () {
    final store = AxWorkActivityStore();
    expect(
      store.handle(
        activityEvent(
          eventId: 'started',
          streamSequence: 4,
          activitySequence: 1,
          type: 'tool.started',
          status: 'running',
        ),
        threadId: 'thread-1',
      ),
      isTrue,
    );
    expect(
      store.handle(
        activityEvent(
          eventId: 'completed',
          streamSequence: 5,
          activitySequence: 2,
          type: 'tool.completed',
          status: 'completed',
          title: 'Repository checks completed',
        ),
        threadId: 'thread-1',
      ),
      isTrue,
    );
    expect(
      store.handle(
        activityEvent(
          eventId: 'completed',
          streamSequence: 5,
          activitySequence: 2,
          type: 'tool.completed',
          status: 'completed',
          title: 'Repository checks completed',
        ),
        threadId: 'thread-1',
      ),
      isFalse,
    );

    final activities = store.forAssignment('assignment-1');
    expect(activities, hasLength(1));
    expect(activities.single.status, 'completed');
    expect(activities.single.title, 'Repository checks completed');
  });

  test('ignores activity from another Thread and keeps a bounded timeline', () {
    final store = AxWorkActivityStore();
    expect(
      store.handle(
        activityEvent(
          eventId: 'other-thread',
          streamSequence: 1,
          activitySequence: 1,
          type: 'tool.started',
          status: 'running',
        )..['threadId'] = 'thread-2',
        threadId: 'thread-1',
      ),
      isFalse,
    );
    for (var index = 0; index < 520; index++) {
      store.handle(
        activityEvent(
          eventId: 'event-$index',
          streamSequence: index + 1,
          activitySequence: index + 1,
          type: 'model.started',
          status: 'running',
          activityId: 'activity-$index',
          title: 'Worker update $index',
        ),
        threadId: 'thread-1',
      );
    }
    expect(store.forAssignment('assignment-1'), hasLength(512));
  });

  testWidgets('shows Worker identity, elapsed time and expandable activity',
      (tester) async {
    final activities = [
      AxWorkActivity(
        eventId: 'start',
        assignmentId: 'assignment-1',
        attemptId: 'attempt-1',
        executionId: 'execution-1',
        workerId: 'chatgpt',
        activitySequence: 1,
        streamSequence: 1,
        type: 'tool.started',
        status: 'running',
        title: 'Executing repository checks',
        timestamp: DateTime.now().subtract(const Duration(seconds: 4)),
        details: const {'toolName': 'shell'},
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AxWorkerActivityPanel(
            workerName: 'ChatGPT',
            providerToolName: 'Codex CLI',
            requestStatus: 'running',
            activities: activities,
          ),
        ),
      ),
    );

    expect(find.text('ChatGPT · Codex CLI'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Executing repository checks'), findsOneWidget);
    expect(find.textContaining('Elapsed:'), findsOneWidget);
    await tester.tap(find.text('Executing repository checks'));
    await tester.pump();
    expect(find.text('toolName: shell'), findsOneWidget);
  });
}

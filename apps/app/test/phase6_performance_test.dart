import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/ax/ax_work_activity.dart';
import 'package:conclave_app/src/ax/ax_work_models.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';

AxWorkRequest _request(String id, String assignmentId) => AxWorkRequest(
      id: id,
      requestedByName: 'You',
      prompt: 'Request $id',
      workflowId: 'direct',
      workflowVersion: 1,
      status: 'running',
      createdAt: '2026-10-14T12:00:00Z',
      steps: [
        AxWorkRequestStep(
          kind: 'implement',
          status: 'running',
          workerId: 'worker-$id',
          assignmentId: assignmentId,
        ),
      ],
    );

Map<String, dynamic> _activityEvent({
  required String eventId,
  required String assignmentId,
  required int sequence,
}) =>
    {
      'eventId': eventId,
      'type': 'assignment.activity',
      'timestamp': DateTime.utc(2026, 10, 14, 12)
          .add(Duration(milliseconds: sequence))
          .toIso8601String(),
      'threadId': 'thread-phase6',
      'assignmentId': assignmentId,
      'attemptId': 'attempt-$assignmentId',
      'sequence': sequence,
      'payload': {
        'entityId': assignmentId,
        'executionId': 'execution-$assignmentId',
        'workerId': 'worker-$assignmentId',
        'activitySequence': sequence,
        'activityType': 'tool.started',
        'activityStatus': 'running',
        'activityId': 'activity-$eventId',
        'title': 'Running fixture operation $sequence',
      },
    };

void main() {
  testWidgets('Phase 6 virtualizes 1,000 Chat and 500 Work entries',
      (tester) async {
    final chatController = ScrollController();
    final workController = ScrollController();
    addTearDown(chatController.dispose);
    addTearDown(workController.dispose);
    var chatBuilt = 0;
    var workBuilt = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 520,
          child: Row(
            children: [
              Expanded(
                child: AxTimelineContainer(
                  scrollKey: const ValueKey('phase6-chat'),
                  controller: chatController,
                  itemCount: 1000,
                  itemBuilder: (context, index) {
                    chatBuilt++;
                    return SizedBox(
                      key: ValueKey('phase6-chat-$index'),
                      height: index.isEven ? 44 : 116,
                      child: Text('Chat $index'),
                    );
                  },
                ),
              ),
              Expanded(
                child: AxTimelineContainer(
                  scrollKey: const ValueKey('phase6-work'),
                  controller: workController,
                  itemCount: 500,
                  itemBuilder: (context, index) {
                    workBuilt++;
                    return SizedBox(
                      key: ValueKey('phase6-work-$index'),
                      height: index.isEven ? 72 : 168,
                      child: Text('Work $index'),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(chatBuilt, lessThan(100));
    expect(workBuilt, lessThan(100));
    expect(find.byKey(const ValueKey('phase6-chat-999')), findsNothing);
    expect(find.byKey(const ValueKey('phase6-work-499')), findsNothing);

    await tester.drag(
        find.byKey(const ValueKey('phase6-chat')), const Offset(0, -900));
    await tester.drag(
        find.byKey(const ValueKey('phase6-work')), const Offset(0, -900));
    await tester.pump();

    expect(chatBuilt, lessThan(220));
    expect(workBuilt, lessThan(220));
  });

  testWidgets('Phase 6 activity bursts rebuild only the affected Worker',
      (tester) async {
    final store = AxWorkActivityStore(notifyInterval: Duration.zero);
    addTearDown(store.dispose);
    final requests = [
      for (var index = 0; index < 5; index++)
        _request('request-$index', 'assignment-$index'),
    ];
    final builds = List<int>.filled(requests.length, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          children: [
            for (var index = 0; index < requests.length; index++)
              ListenableBuilder(
                listenable: store.listenableForRequest(requests[index]),
                builder: (context, child) {
                  builds[index]++;
                  return Text(
                      '${requests[index].id}: ${store.forRequest(requests[index]).length}');
                },
              ),
          ],
        ),
      ),
    );
    final initialBuilds = List<int>.from(builds);

    for (var sequence = 1; sequence <= 100; sequence++) {
      expect(
        store.handle(
          _activityEvent(
            eventId: 'event-$sequence',
            assignmentId: 'assignment-0',
            sequence: sequence,
          ),
          threadId: 'thread-phase6',
        ),
        isTrue,
      );
    }
    await tester.pump();

    expect(builds[0], greaterThan(initialBuilds[0]));
    expect(builds.skip(1), everyElement(equals(initialBuilds[1])));
    expect(store.forAssignment('assignment-0'), hasLength(100));
  });

  testWidgets('Phase 6 large Markdown and off-bottom updates remain stable',
      (tester) async {
    final controller = ScrollController();
    final updates = ValueNotifier<int>(0);
    addTearDown(controller.dispose);
    addTearDown(updates.dispose);

    final markdown = List.generate(
      160,
      (index) => '### Result $index\n\n```dart\nfinal value$index = true;\n```',
    ).join('\n\n');

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 520,
          child: ListenableBuilder(
            listenable: updates,
            builder: (context, _) => CustomScrollView(
              controller: controller,
              slivers: [
                SliverToBoxAdapter(
                  child: ConclaveMarkdownBody(data: markdown),
                ),
                SliverList.builder(
                  itemCount: 100,
                  itemBuilder: (context, index) => SizedBox(
                    height: 48,
                    child: Text('Activity ${updates.value}.$index'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();
    final readingOffset = controller.offset;
    updates.value++;
    await tester.pump();

    expect(controller.offset, closeTo(readingOffset, 1));
    expect(tester.takeException(), isNull);
  });
}

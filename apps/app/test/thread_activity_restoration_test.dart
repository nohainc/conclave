import 'dart:async';

import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

Map<String, dynamic> activity(String thread, int sequence) => {
      'eventId': '$thread-event-$sequence',
      'assignmentId': '$thread-assignment',
      'attemptId': '$thread-attempt',
      'executionId': '$thread-execution',
      'workerId': 'worker',
      'activitySequence': sequence,
      'activityType': 'tool.completed',
      'activityStatus': 'completed',
      'title': '$thread operation $sequence',
      'timestamp': '2026-10-17T10:00:0${sequence}Z',
    };

class ActivitySource extends AxFixtureDataSource {
  final histories = <String, List<Map<String, dynamic>>>{'a': [], 'b': []};
  final details = <String>[];

  AxWorkRequest request(String thread) => AxWorkRequest(
        id: thread,
        requestedByName: 'You',
        prompt: 'Work in $thread',
        workflowId: 'direct',
        workflowVersion: 2,
        status: 'running',
        createdAt: '2026-10-17T10:00:00Z',
        steps: [
          AxWorkRequestStep(
              kind: 'implement',
              status: 'running',
              workerId: 'worker',
              assignmentId: '$thread-assignment'),
        ],
      );

  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [request(threadId)];

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
      {required String workRequestId}) async {
    details.add(workRequestId);
    return AxWorkRequestStatus(
        id: workRequestId,
        threadId: workRequestId,
        status: 'running',
        steps: request(workRequestId).steps,
        activityHistory: List.of(histories[workRequestId]!));
  }
}

void main() {
  testWidgets('switching concurrent running threads restores prior operations',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = ActivitySource();
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);

    Future<void> open(String id, {bool replacePage = false}) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: replacePage ? ValueKey(id) : null,
        initialTab: 1,
        space: const AxSpace(
            id: 'space',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: AxThread(
            id: id,
            spaceId: 'space',
            name: id,
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: data,
        realtimeEvents: events.stream,
        onBackToSpace: () {},
        onArchive: () {},
      ))));
      // Running activity animates continuously, so pump fixed frames.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    void completeOperation(String id, int sequence) {
      final row = activity(id, sequence);
      data.histories[id]!.add(row);
      events.add({
        'type': 'assignment.activity',
        'threadId': id,
        'assignmentId': row['assignmentId'],
        'attemptId': row['attemptId'],
        'eventId': row['eventId'],
        'sequence': sequence,
        'timestamp': row['timestamp'],
        'payload': row,
      });
    }

    await open('a');
    completeOperation('a', 1);
    await tester.pump();
    expect(find.text('a operation 1'), findsOneWidget);
    await open('b');
    expect(find.text('a operation 1'), findsNothing);
    completeOperation('b', 1);
    completeOperation('a', 2); // Arrives while the other Thread is visible.
    await tester.pump();
    expect(find.text('b operation 1'), findsOneWidget);
    await open('a');
    expect(find.text('a operation 1'), findsOneWidget);
    expect(find.text('a operation 2'), findsOneWidget);
    expect(find.text('b operation 1'), findsNothing);
    await open('b', replacePage: true); // Also cover disposed/recreated pages.
    expect(find.text('b operation 1'), findsOneWidget);
    expect(find.text('a operation 1'), findsNothing);
    expect(data.details, containsAll(['a', 'b']));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

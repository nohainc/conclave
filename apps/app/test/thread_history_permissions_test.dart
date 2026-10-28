import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'ax_fixture_data.dart';

class _HistorySource extends AxFixtureDataSource {
  AxDiscussionMessage message = const AxDiscussionMessage(
      id: 'message',
      threadId: 'thread',
      authorUserId: 'other',
      authorName: 'Maya',
      body: 'Shared message',
      createdAt: '2026-10-25T12:00:00Z');
  @override
  Future<AxDiscussionPage> loadDiscussionPage(
          {required String threadId,
          int limit = 50,
          String? before,
          String? after}) async =>
      AxDiscussionPage(messages: [message]);
  @override
  Future<AxDiscussionMessage> loadDiscussionMessage(
          {required String messageId}) async =>
      message;
  @override
  Future<void> deleteDiscussionMessage({required String messageId}) async {
    message = AxDiscussionMessage(
        id: message.id,
        threadId: message.threadId,
        authorUserId: message.authorUserId,
        authorName: message.authorName,
        body: 'Message removed by Alex · Space owner',
        eventType: 'message.removed',
        createdAt: message.createdAt,
        editedAt: '2026-10-25T13:00:00Z');
  }
}

void main() {
  tearDown(ThreadPage.resetWorkQueues);
  Future<void> show(WidgetTester tester,
      {required _HistorySource source,
      String role = 'owner',
      bool archived = false,
      Future<void> Function()? restore,
      Future<void> Function()? reset}) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: AxSpace(
          id: 'space', name: 'Space', branch: '', lastActivity: '', role: role),
      thread: AxThread(
          id: 'thread',
          spaceId: 'space',
          name: 'Thread',
          lead: 'other',
          status: archived ? 'archived' : 'active',
          archived: archived,
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: source,
      currentUserId: 'owner',
      currentUserName: 'Alex',
      showAiHistory: false,
      onBackToSpace: () {},
      onArchive: () {},
      onRestore: restore,
      onClearAiHistory: reset,
    ))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'owner moderation preserves sender and replaces content with a protected notice',
      (tester) async {
    final source = _HistorySource();
    await show(tester, source: source);
    await tester.tap(find.byTooltip('Message actions'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Shared message'), findsNothing);
    expect(find.textContaining('Maya ·'), findsOneWidget);
    expect(find.textContaining('Message removed by Alex · Space owner'),
        findsOneWidget);
    expect(find.byTooltip('Message actions'), findsNothing);
  });
  testWidgets('viewer can reset context with AI History hidden',
      (tester) async {
    var resets = 0;
    await show(tester, source: _HistorySource(), role: 'viewer',
        reset: () async {
      resets++;
    });
    await tester.tap(find.byTooltip('Reset AI context'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The visible conversation stays available'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(resets, 1);
  });
  testWidgets('archived thread replaces composer with restore for viewers',
      (tester) async {
    var restores = 0;
    await show(tester, source: _HistorySource(), role: 'viewer', archived: true,
        restore: () async {
      restores++;
    });
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Restore thread'));
    await tester.pumpAndSettle();
    expect(restores, 1);
  });
}

import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_work_models.dart';
import 'package:conclave_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:conclave_app/src/features/spaces/timeline_follow_anchor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final nestedResponse in [false, true]) {
    testWidgets(
        '${nestedResponse ? 'Work response' : 'Chat message'} reveals its beginning and preserves it during growth',
        (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final anchor = AxTimelineFollowAnchor();
      var height = 0.0;
      var extraMessage = false;
      final firstNew = nestedResponse ? ('request', 'response') : 'new-message';
      Widget view() => MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: AxTimelineContainer(
                    scrollKey: const ValueKey('history'),
                    controller: controller,
                    itemCount: nestedResponse
                        ? 1
                        : 10 + (height > 0 ? 1 : 0) + (extraMessage ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (nestedResponse) {
                        return Column(children: [
                          const SizedBox(
                              height: 700, child: Text('Request and activity')),
                          if (height > 0)
                            SizedBox(
                              key: anchor.keyFor(firstNew),
                              height: height,
                              child: const Align(
                                  alignment: Alignment.topLeft,
                                  child: Text('Opening line')),
                            ),
                          if (extraMessage) const SizedBox(height: 900),
                        ]);
                      }
                      if (index < 10) {
                        return SizedBox(height: 70, child: Text('Old $index'));
                      }
                      if (index == 10) {
                        return SizedBox(
                          key: anchor.keyFor(firstNew),
                          height: height,
                          child: const Align(
                              alignment: Alignment.topLeft,
                              child: Text('Opening line')),
                        );
                      }
                      return const SizedBox(
                          height: 900, child: Text('Later message'));
                    },
                  ),
                ),
              ),
            ),
          );
      Future<void> reveal() async {
        for (var attempt = 0; attempt < 4; attempt++) {
          if (!anchor.reveal(controller)) break;
          await tester.pump();
        }
        await tester.pump();
      }

      await tester.pumpWidget(view());
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      anchor.observe(firstNew, controller);
      height = 1200;
      await tester.pumpWidget(view());
      await reveal();
      final viewport = tester.getRect(find.byKey(const ValueKey('history')));
      expect(tester.getTopLeft(find.text('Opening line')).dy,
          closeTo(viewport.top, 1));
      expect(controller.position.extentAfter, greaterThan(500));
      anchor.observe('later-message', controller);
      height = 1800;
      extraMessage = true;
      await tester.pumpWidget(view());
      await reveal();
      expect(tester.getTopLeft(find.text('Opening line')).dy,
          closeTo(viewport.top, 1));
      expect(controller.position.extentAfter, greaterThan(1000));
    });
  }
  testWidgets(
      'ThreadPage reveals incoming Chat and Work openings and respects manual scrolling',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chat = AxDiscussionCache(null);
    final work = AxWorkHistoryCache(null);
    AxDiscussionMessage message(String id, String body) => AxDiscussionMessage(
          id: id,
          threadId: 'thread',
          authorUserId: 'other',
          body: body,
          createdAt: id.startsWith('old-')
              ? '2026-10-15T00:00:00.000Z'
              : '2026-10-15T00:01:00.000Z',
        );
    AxWorkRequest request({String? response}) => AxWorkRequest(
          id: 'request',
          requestedByName: 'You',
          prompt: 'A short request',
          workflowId: 'direct',
          workflowVersion: 2,
          status: 'completed',
          createdAt: '2026-10-15T00:00:00.000Z',
          steps: const [],
          finalText: response,
        );
    final old = List.generate(
        15, (index) => message('old-$index', 'Earlier message $index'));
    chat.engine.update(chat.query('thread'),
        (_) => AxDiscussionHistory(messages: old, initialLoaded: true));
    work.engine.update(work.query('thread'),
        (_) => AxWorkHistory(requests: [request()], initialLoaded: true));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 'thread',
          spaceId: 'space',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      discussionCache: chat,
      workHistoryCache: work,
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pumpAndSettle();
    final longChat =
        'Chat opening\n\n${List.filled(80, 'Chat body paragraph.').join('\n\n')}';
    final longWork =
        'Work opening\n\n${List.filled(80, 'Work body paragraph.').join('\n\n')}';
    chat.engine.update(
        chat.query('thread'),
        (_) => AxDiscussionHistory(
            messages: [...old, message('incoming', longChat)],
            initialLoaded: true));
    work.replace('thread', [request(response: longWork)]);
    await tester.pumpAndSettle();
    for (final tab in ['chat', 'work']) {
      final history = find.byKey(ValueKey('$tab-history-scroll'));
      final rect = tester.getRect(history);
      final opening = tester.getRect(find
          .textContaining('${tab == 'chat' ? 'Chat' : 'Work'} opening',
              findRichText: true)
          .first);
      expect(opening.top, greaterThanOrEqualTo(rect.top - 1));
      expect(opening.top + 24, lessThan(rect.bottom));
      final controller = tester.widget<CustomScrollView>(history).controller!;
      expect(controller.position.extentAfter, greaterThan(500));
    }
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    await tester.drag(history, const Offset(0, 150));
    await tester.pumpAndSettle();
    final controller = tester.widget<CustomScrollView>(history).controller!;
    final readingOffset = controller.offset;
    chat.engine.update(
        chat.query('thread'),
        (_) => AxDiscussionHistory(messages: [
              ...old,
              message('incoming', longChat),
              message('later', 'Later Chat')
            ], initialLoaded: true));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(readingOffset, 1));
    await tester.pumpWidget(const SizedBox());
    chat.clear();
    work.clear();
  });

  testWidgets('short incoming messages fit fully above the composer',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final anchor = AxTimelineFollowAnchor();
    Widget view(bool incoming) => MaterialApp(
            home: Scaffold(
                body: SizedBox(
          height: 300,
          child: ListView(
              controller: controller,
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 700),
                if (incoming)
                  SizedBox(
                      key: anchor.keyFor('short'),
                      height: 60,
                      child: const Text('Short message')),
              ]),
        )));
    await tester.pumpWidget(view(false));
    controller.jumpTo(controller.position.maxScrollExtent);
    anchor.observe('short', controller);
    await tester.pumpWidget(view(true));
    anchor.reveal(controller);
    await tester.pump();
    expect(controller.position.extentAfter, 0);
    expect(tester.getTopLeft(find.text('Short message')).dy,
        greaterThanOrEqualTo(0));
  });
}

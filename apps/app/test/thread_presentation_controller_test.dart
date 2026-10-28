import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/ax/ax_work_activity.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:syntila_app/src/ax/sync/ax_work_history.dart';
import 'package:syntila_app/src/features/spaces/thread_presentation_controller.dart';

AxWorkRequest request(String id, {required String status}) => AxWorkRequest(
      id: id,
      requestedByName: 'You',
      prompt: 'Prompt $id',
      workflowId: 'direct',
      workflowVersion: 1,
      status: status,
      createdAt: '2026-10-14T12:00:00Z',
      steps: const [],
    );

void main() {
  test('batches duplicate cosmetic cache notifications by presentation slice',
      () async {
    final discussionCache = AxDiscussionCache(null);
    final workHistoryCache = AxWorkHistoryCache(null);
    final activityStore = AxWorkActivityStore();
    final controller = ThreadPresentationController(
      activityStore: activityStore,
    );
    controller.attach(
      threadId: 'thread-1',
      discussionCache: discussionCache,
      workHistoryCache: workHistoryCache,
    );

    var chatNotifications = 0;
    var workNotifications = 0;
    controller.chat.addListener(() => chatNotifications++);
    controller.work.addListener(() => workNotifications++);

    discussionCache.engine.update(
      discussionCache.query('thread-1'),
      (_) => AxDiscussionHistory(initialLoaded: true),
    );
    discussionCache.engine.update(
      discussionCache.query('thread-1'),
      (_) => AxDiscussionHistory(initialLoaded: true),
    );
    workHistoryCache.engine.update(
      workHistoryCache.query('thread-1'),
      (_) => AxWorkHistory(initialLoaded: true),
    );
    workHistoryCache.engine.update(
      workHistoryCache.query('thread-1'),
      (_) => AxWorkHistory(initialLoaded: true),
    );

    // The controller starts the initial Chat synchronization on attach, so
    // that prompt cache transition may already have published one Chat slice.
    expect(chatNotifications, lessThanOrEqualTo(1));
    expect(workNotifications, 0);
    await Future<void>.delayed(Duration.zero);
    expect(chatNotifications, 1);
    expect(workNotifications, 1);

    controller.dispose();
    activityStore.dispose();
  });

  test('publishes terminal lifecycle changes synchronously', () {
    final discussionCache = AxDiscussionCache(null);
    final workHistoryCache = AxWorkHistoryCache(null);
    final activityStore = AxWorkActivityStore();
    final controller = ThreadPresentationController(
      activityStore: activityStore,
    );
    controller.attach(
      threadId: 'thread-1',
      discussionCache: discussionCache,
      workHistoryCache: workHistoryCache,
    );

    var executionNotifications = 0;
    controller.execution.addListener(() => executionNotifications++);
    workHistoryCache.engine.update(
      workHistoryCache.query('thread-1'),
      (_) => AxWorkHistory(
        requests: [request('request-1', status: 'failed')],
        initialLoaded: true,
      ),
    );

    expect(executionNotifications, 1);
    expect(controller.execution.value!.terminalRequestIds, {'request-1'});

    controller.dispose();
    activityStore.dispose();
  });

  test('publishes local Work presentation changes without cache mutations',
      () async {
    final discussionCache = AxDiscussionCache(null);
    final workHistoryCache = AxWorkHistoryCache(null);
    final activityStore = AxWorkActivityStore();
    final controller = ThreadPresentationController(
      activityStore: activityStore,
    );
    controller.attach(
      threadId: 'thread-1',
      discussionCache: discussionCache,
      workHistoryCache: workHistoryCache,
    );

    var workNotifications = 0;
    controller.work.addListener(() => workNotifications++);
    controller.markWorkChanged();
    await Future<void>.delayed(Duration.zero);

    expect(workNotifications, 1);
    expect(controller.work.value?.revision, 1);

    controller.dispose();
    activityStore.dispose();
  });

  test('ignores cache callbacks from a previous Thread generation', () async {
    final firstDiscussionCache = AxDiscussionCache(null);
    final secondDiscussionCache = AxDiscussionCache(null);
    final workHistoryCache = AxWorkHistoryCache(null);
    final activityStore = AxWorkActivityStore();
    final controller = ThreadPresentationController(
      activityStore: activityStore,
    );
    controller.attach(
      threadId: 'thread-1',
      discussionCache: firstDiscussionCache,
      workHistoryCache: workHistoryCache,
    );
    controller.attach(
      threadId: 'thread-2',
      discussionCache: secondDiscussionCache,
      workHistoryCache: workHistoryCache,
    );
    final generation = controller.generation;

    firstDiscussionCache.engine.update(
      firstDiscussionCache.query('thread-1'),
      (_) => AxDiscussionHistory(initialLoaded: true),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.generation, generation);
    expect(controller.chat.value!.generation, generation);

    controller.dispose();
    activityStore.dispose();
  });
}

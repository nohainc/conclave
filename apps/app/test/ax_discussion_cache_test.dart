import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'ax_fixture_data.dart';
import 'package:conclave_app/src/ax/sync/ax_realtime_cache_router.dart';

AxDiscussionMessage message(String id, String body,
        {String ws = 'w', String? editedAt}) =>
    AxDiscussionMessage(
        id: id,
        workstreamId: ws,
        authorUserId: 'me',
        body: body,
        createdAt: '2026-10-06T00:00:00.000Z',
        editedAt: editedAt);

class DiscussionSource extends AxFixtureDataSource {
  final queuedPages = <Completer<AxDiscussionPage>>[];
  final pages = <({String ws, String? before, String? after, int limit})>[];
  final detailLoads = <String>[];
  final queuedDetails = <Completer<AxDiscussionMessage>>[];
  @override
  Future<AxDiscussionMessage> loadDiscussionMessage(
      {required String messageId}) {
    detailLoads.add(messageId);
    if (queuedDetails.isNotEmpty) return queuedDetails.removeAt(0).future;
    return Future.value(
        server.firstWhere((message) => message.id == messageId));
  }

  final sends = <Completer<AxDiscussionMessage>>[];
  final edits = <Completer<AxDiscussionMessage>>[];
  List<AxDiscussionMessage> server = [];
  @override
  Future<AxDiscussionPage> loadDiscussionPage(
      {required String workstreamId,
      int limit = 50,
      String? before,
      String? after}) {
    pages.add((ws: workstreamId, before: before, after: after, limit: limit));
    if (queuedPages.isNotEmpty) return queuedPages.removeAt(0).future;
    return Future.value(AxDiscussionPage(
        messages: server.where((m) => m.workstreamId == workstreamId)));
  }

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String workstreamId,
      required String text,
      List<String> references = const [],
      String? idempotencyKey}) {
    final request = Completer<AxDiscussionMessage>();
    sends.add(request);
    return request.future;
  }

  @override
  Future<AxDiscussionMessage> editDiscussionMessage(
      {required String messageId,
      required String text,
      List<String> references = const []}) {
    final request = Completer<AxDiscussionMessage>();
    edits.add(request);
    return request.future;
  }
}

void main() {
  late DiscussionSource source;
  late AxDiscussionCache cache;
  setUp(() {
    source = DiscussionSource();
    cache = AxDiscussionCache(source);
  });
  Future<void> drain() => Future<void>.delayed(Duration.zero);

  test('5,000 Discussion messages: recent 50 and one requested older page only',
      () async {
    final server = List.generate(
        5000, (i) => message(i.toString().padLeft(4, '0'), 'Message $i'));
    final head = Completer<AxDiscussionPage>();
    source.queuedPages.add(head);
    final first = cache.synchronize('w');
    final pageSize = source.pages.single.limit;
    expect(pageSize, 50);
    head.complete(AxDiscussionPage(
        messages: server.sublist(5000 - pageSize),
        nextCursor: 'older',
        newestCursor: 'latest'));
    await first;
    await drain();
    expect(source.pages, hasLength(1));
    expect(cache.peek('w').messages, hasLength(pageSize));
    final previous = Completer<AxDiscussionPage>();
    source.queuedPages.add(previous);
    final next = cache.loadOlder('w');
    expect(source.pages, hasLength(2));
    expect(source.pages.last.before, 'older');
    expect(source.pages.last.limit, pageSize);
    previous.complete(AxDiscussionPage(
        messages: server.sublist(5000 - 2 * pageSize, 5000 - pageSize),
        nextCursor: 'even-older'));
    await next;
    await drain();
    expect(source.pages, hasLength(2));
    expect(cache.peek('w').messages, hasLength(2 * pageSize));
    expect(cache.peek('w').messages.map((row) => row.id).toSet(),
        hasLength(2 * pageSize));
  });

  test('remote edits merge an older loaded message through one detail read',
      () async {
    final head = Completer<AxDiscussionPage>();
    source.queuedPages.add(head);
    final first = cache.synchronize('w');
    head.complete(AxDiscussionPage(
        messages: [message('new', 'recent')], nextCursor: 'older'));
    await first;
    final oldPage = Completer<AxDiscussionPage>();
    source.queuedPages.add(oldPage);
    final older = cache.loadOlder('w');
    oldPage.complete(AxDiscussionPage(
        messages: [message('old', 'old body')], nextCursor: 'oldest'));
    await older;
    final pages = source.pages.length;
    source.server = [
      message('old', 'remote edit', editedAt: '2026-10-06T01:00:00.000Z')
    ];
    await cache.reconcileSignal('w', 'discussion.updated', 'old');
    expect(source.detailLoads, ['old']);
    expect(source.pages.length, pages);
    expect(cache.peek('w').olderCursor, 'oldest');
    expect(cache.peek('w').messages.map((message) => message.body),
        ['recent', 'remote edit']);
  });
  test('creation signals use only the newest known cursor', () async {
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    final first = cache.synchronize('w');
    initial.complete(AxDiscussionPage(
        messages: [message('one', 'cached')],
        newestCursor: 'anchor',
        nextCursor: 'older'));
    await first;
    final next = Completer<AxDiscussionPage>();
    source.queuedPages.add(next);
    final signal = cache.reconcileSignal('w', 'discussion.created', 'two');
    next.complete(AxDiscussionPage(
        messages: [message('two', 'new')], newestCursor: 'next'));
    await signal;
    expect(source.pages.map((page) => page.after), [null, 'anchor']);
    expect(cache.peek('w').olderCursor, 'older');
    expect(cache.peek('w').messages.length, 2);
  });
  test('unloaded edit targets do not fetch history', () async {
    source.server = [message('one', 'one')];
    await cache.synchronize('w');
    await cache.reconcileSignal('w', 'discussion.updated', 'unloaded');
    expect(source.detailLoads, isEmpty);
    expect(source.pages.length, 1);
  });
  test('late detail responses cannot repopulate a cleared session', () async {
    source.server = [message('one', 'old')];
    await cache.synchronize('w');
    final detail = Completer<AxDiscussionMessage>();
    source.queuedDetails.add(detail);
    final signal = cache.reconcileSignal('w', 'discussion.updated', 'one');
    cache.clear();
    detail.complete(message('one', 'late'));
    await signal;
    expect(cache.peek('w').messages, isEmpty);
  });
  test(
      'failed detail reconciliation preserves cached data and reports the error',
      () async {
    source.server = [message('one', 'cached')];
    await cache.synchronize('w');
    final detail = Completer<AxDiscussionMessage>();
    source.queuedDetails.add(detail);
    final signal = cache.reconcileSignal('w', 'discussion.updated', 'one');
    detail.completeError(StateError('offline'));
    await expectLater(signal, throwsStateError);
    expect(cache.peek('w').messages.single.body, 'cached');
    expect(cache.peek('w').error, isA<StateError>());
  });
  test('reopening retains cache and deduplicates initial synchronization',
      () async {
    source.server = [message('1', 'cached')];
    final first = cache.synchronize('w');
    expect(identical(first, cache.synchronize('w')), isTrue);
    await first;
    expect(source.pages, hasLength(1));
    final pending = Completer<AxDiscussionPage>();
    source.queuedPages.add(pending);
    final sync = cache.synchronize('w');
    expect(cache.peek('w').messages.single.body, 'cached');
    expect(cache.peek('w').isFetching, isTrue);
    pending.complete(AxDiscussionPage(messages: [message('2', 'new')]));
    await sync;
    expect(cache.peek('w').messages.map((m) => m.body), ['cached', 'new']);
  });
  test(
      'catchup follows forward cursors and refreshes newest edits without dropping older history',
      () async {
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    final sync = cache.synchronize('w');
    initial.complete(AxDiscussionPage(
        messages: [message('1', 'old')],
        nextCursor: 'older',
        newestCursor: 'anchor'));
    await sync;
    final forward1 = Completer<AxDiscussionPage>(),
        forward2 = Completer<AxDiscussionPage>(),
        head = Completer<AxDiscussionPage>();
    source.queuedPages.addAll([forward1, forward2, head]);
    final refresh = cache.synchronize('w');
    forward1.complete(AxDiscussionPage(
        messages: [message('2', 'new2')], nextCursor: 'forward'));
    await drain();
    forward2.complete(AxDiscussionPage(messages: [message('3', 'new3')]));
    await drain();
    head.complete(AxDiscussionPage(messages: [
      message('1', 'edited', editedAt: '2026-10-06T01:00:00.000Z'),
      message('3', 'new3')
    ], newestCursor: 'latest'));
    await refresh;
    expect(source.pages.map((p) => p.after), [null, 'anchor', 'forward', null]);
    expect(cache.peek('w').messages.map((m) => m.body),
        ['edited', 'new2', 'new3']);
    expect(cache.peek('w').olderCursor, 'older');
  });
  test('incremental reconnect fetches only new pages and advances anchor',
      () async {
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    final first = cache.synchronize('w');
    initial.complete(AxDiscussionPage(
        messages: [message('1', 'one')],
        nextCursor: 'older',
        newestCursor: 'anchor'));
    await first;
    final next = Completer<AxDiscussionPage>();
    final last = Completer<AxDiscussionPage>();
    source.queuedPages.addAll([next, last]);
    final sync = cache.synchronize('w', reconcileNewest: false);
    expect(identical(sync, cache.synchronize('w', reconcileNewest: false)),
        isTrue);
    next.complete(AxDiscussionPage(
        messages: [message('2', 'two')],
        nextCursor: 'continuation',
        newestCursor: 'two'));
    await drain();
    last.complete(AxDiscussionPage(
        messages: [message('3', 'three')], newestCursor: 'three'));
    await sync;
    expect(source.pages.map((p) => p.after), [null, 'anchor', 'continuation']);
    expect(
        source.pages.every((p) => p.before == null && p.limit == 50), isTrue);
    expect(cache.peek('w').messages.map((m) => m.id), ['1', '2', '3']);
    expect(cache.peek('w').olderCursor, 'older');
    final empty = Completer<AxDiscussionPage>();
    source.queuedPages.add(empty);
    final again = cache.synchronize('w', reconcileNewest: false);
    expect(source.pages.last.after, 'three');
    empty.complete(AxDiscussionPage(messages: [], newestCursor: 'three'));
    await again;
    expect(source.pages.length, 4);
    expect(cache.peek('w').messages.length, 3);
  });
  test('older pagination shares future and prepends without duplicates',
      () async {
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    final sync = cache.synchronize('w');
    initial.complete(
        AxDiscussionPage(messages: [message('2', 'two')], nextCursor: 'older'));
    await sync;
    final older = Completer<AxDiscussionPage>();
    source.queuedPages.add(older);
    final first = cache.loadOlder('w');
    expect(identical(first, cache.loadOlder('w')), isTrue);
    expect(cache.peek('w').loadingOlder, isTrue);
    expect(source.pages.last.before, 'older');
    older.complete(
        AxDiscussionPage(messages: [message('1', 'one'), message('2', 'two')]));
    await first;
    expect(cache.peek('w').messages.map((m) => m.id), ['1', '2']);
    expect(cache.peek('w').olderCursor, isNull);
    expect(cache.peek('w').loadingOlder, isFalse);
  });
  test('older failure retains cursor and messages for retry', () async {
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    final sync = cache.synchronize('w');
    initial.complete(
        AxDiscussionPage(messages: [message('2', 'two')], nextCursor: 'older'));
    await sync;
    final older = Completer<AxDiscussionPage>();
    source.queuedPages.add(older);
    final load = cache.loadOlder('w');
    final check = expectLater(load, throwsStateError);
    older.completeError(StateError('offline'));
    await check;
    expect(cache.peek('w').messages.single.body, 'two');
    expect(cache.peek('w').olderCursor, 'older');
    expect(cache.peek('w').error, isStateError);
  });
  test(
      'send overlays appear immediately, reconcile IDs and tolerate out-of-order results',
      () async {
    await cache.synchronize('w');
    final first = cache.send('w', 'first', userId: 'me');
    final second = cache.send('w', 'second', userId: 'me');
    expect(cache.peek('w').messages.map((m) => m.body), ['first', 'second']);
    expect(cache.peek('w').messages.every((m) => m.id.startsWith('temp-')),
        isTrue);
    source.sends[1].complete(message('s2', 'server second'));
    await second;
    source.sends[0].complete(message('s1', 'server first'));
    await first;
    await drain();
    expect(cache.peek('w').messages.map((m) => m.id), ['s1', 's2']);
    expect(cache.peek('w').messages.map((m) => m.body),
        ['server first', 'server second']);
  });
  test('failed send removes only its own temporary message', () async {
    await cache.synchronize('w');
    final first = cache.send('w', 'failed');
    final check = expectLater(first, throwsStateError);
    final second = cache.send('w', 'saved');
    source.sends[1].complete(message('s2', 'saved'));
    await second;
    source.sends[0].completeError(StateError('denied'));
    await check;
    await drain();
    expect(cache.peek('w').messages.map((m) => m.body), ['saved']);
  });
  test('edit overlay survives reads and rolls back on failure', () async {
    source.server = [message('1', 'original')];
    await cache.synchronize('w');
    final edit = cache.edit('w', '1', 'optimistic');
    final check = expectLater(edit, throwsStateError);
    expect(cache.peek('w').messages.single.body, 'optimistic');
    await cache.synchronize('w');
    expect(cache.peek('w').messages.single.body, 'optimistic');
    source.edits.single.completeError(StateError('denied'));
    await check;
    expect(cache.peek('w').messages.single.body, 'original');
  });
  test('edit response reconciles body and fences stale in-flight refresh',
      () async {
    source.server = [message('1', 'original')];
    await cache.synchronize('w');
    final stale = Completer<AxDiscussionPage>();
    source.queuedPages.add(stale);
    final read = cache.synchronize('w');
    final edit = cache.edit('w', '1', 'optimistic');
    source.edits.single.complete(message('1', 'server normalized',
        editedAt: '2026-10-06T01:00:00.000Z'));
    await edit;
    stale.complete(AxDiscussionPage(messages: [message('1', 'old')]));
    await read;
    await drain();
    expect(cache.peek('w').messages.single.body, 'server normalized');
  });
  test('one failed edit cannot undo another successful edit', () async {
    source.server = [message('1', 'one'), message('2', 'two')];
    await cache.synchronize('w');
    final first = cache.edit('w', '1', 'bad');
    final check = expectLater(first, throwsStateError);
    final second = cache.edit('w', '2', 'new');
    source.edits[1]
        .complete(message('2', 'new', editedAt: '2026-10-06T01:00:00.000Z'));
    await second;
    source.edits[0].completeError(StateError('denied'));
    await check;
    await drain();
    expect(cache.peek('w').messages.map((m) => m.body), ['one', 'new']);
  });
  test('session clear fences pending reads and writes', () async {
    final page = Completer<AxDiscussionPage>();
    source.queuedPages.add(page);
    final read = cache.synchronize('w');
    final write = cache.send('w', 'pending');
    cache.clear();
    page.complete(AxDiscussionPage(messages: [message('1', 'old session')]));
    source.sends.single.complete(message('2', 'old write'));
    await read;
    await write;
    expect(cache.peek('w').messages, isEmpty);
  });
  test('Workstream observers are isolated and cancelable', () async {
    var a = 0, b = 0;
    final cancel = cache.watch('w', (_) => a++);
    cache.watch('other', (_) => b++);
    await cache.synchronize('w');
    expect(a, 2);
    expect(b, 0);
    cancel();
    await cache.synchronize('w');
    expect(a, 2);
  });

  Widget page(String id, {Stream<Map<String, dynamic>>? realtime}) =>
      MaterialApp(
          home: Scaffold(
              body: WorkstreamPage(
                  key: ValueKey(id),
                  project: const AxProject(
                      id: 'p', name: 'Project', branch: '', lastActivity: ''),
                  workstream: AxWorkstream(
                      id: id,
                      projectId: 'p',
                      name: id,
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: source,
                  discussionCache: cache,
                  realtimeEvents: realtime,
                  currentUserId: 'me',
                  onBackToProject: () {},
                  onArchive: () {})));
  Future<void> size(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('reconnect events use only the incremental cursor',
      (tester) async {
    await size(tester);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final router = AxRealtimeCacheRouter(cache.engine,
        discussionResynchronize: (id) async {
      await cache.synchronize(id, reconcileNewest: false);
    });
    final subscription = events.stream.listen((event) {
      unawaited(router.handle(event));
    });
    addTearDown(subscription.cancel);
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    await tester.pumpWidget(page('w', realtime: events.stream));
    initial.complete(AxDiscussionPage(
        messages: [message('1', 'cached')], newestCursor: 'anchor'));
    await tester.pumpAndSettle();
    final forward = Completer<AxDiscussionPage>();
    source.queuedPages.add(forward);
    events.add({
      'type': 'reconnect.required',
      'scope': {'kind': 'workstream', 'workstreamId': 'w'}
    });
    await tester.pump();
    expect(source.pages.last.after, 'anchor');
    expect(find.text('cached'), findsOneWidget);
    forward.complete(AxDiscussionPage(
        messages: [message('2', 'new')], newestCursor: 'latest'));
    await tester.pumpAndSettle();
    expect(source.pages.length, 2);
    expect(find.text('cached'), findsOneWidget);
    expect(find.text('new'), findsOneWidget);
  });
  testWidgets(
      'failed initial Chat read shows the cause, not an empty conversation, and retries',
      (tester) async {
    await size(tester);
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    await tester.pumpWidget(page('w'));
    initial.completeError(StateError('Discussion endpoint unavailable'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Discussion endpoint unavailable'), findsOneWidget);
    expect(find.text('Retry Chat sync'), findsOneWidget);
    expect(find.text('No chat messages yet'), findsNothing);
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.byTooltip('Copy Chat error'));
    await tester.pump();
    expect(copied,
        'Chat could not synchronize: Bad state: Discussion endpoint unavailable');
    source.server = [message('recovered', 'Recovered Chat')];
    await tester.tap(find.text('Retry Chat sync'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered Chat'), findsOneWidget);
    expect(find.text('Retry Chat sync'), findsNothing);
    expect(find.textContaining('Chat could not synchronize:'), findsNothing);
  });

  testWidgets(
      'scrolling to the beginning loads older messages once and retains viewport',
      (tester) async {
    await size(tester);
    final initial = Completer<AxDiscussionPage>();
    source.queuedPages.add(initial);
    await tester.pumpWidget(page('w'));
    initial.complete(AxDiscussionPage(
        messages: List.generate(50,
            (i) => message('m${i.toString().padLeft(3, '0')}', 'Message $i')),
        nextCursor: 'older',
        newestCursor: 'latest'));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    final controller =
        tester.widget<SingleChildScrollView>(history).controller!;
    expect(controller.offset, greaterThan(0));
    final older = Completer<AxDiscussionPage>();
    source.queuedPages.add(older);
    await tester.drag(history, const Offset(0, 12000));
    await tester.pump();
    expect(source.pages.last.before, 'older');
    expect(source.pages.length, 2);
    older.complete(AxDiscussionPage(
        messages: List.generate(50,
            (i) => message('a${i.toString().padLeft(3, '0')}', 'Older $i'))));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    await tester.drag(history, const Offset(0, 12000));
    await tester.pumpAndSettle();
    expect(source.pages.length, 2);
    expect(cache.peek('w').messages.length, 100);
  });
  testWidgets(
      'destroyed Chat page reopens cached messages while network is pending',
      (tester) async {
    await size(tester);
    source.server = [message('1', 'Cached Chat')];
    await tester.pumpWidget(page('w'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page('other'));
    await tester.pumpAndSettle();
    final sync = Completer<AxDiscussionPage>();
    source.queuedPages.add(sync);
    await tester.pumpWidget(page('w'));
    await tester.pump();
    expect(find.text('Cached Chat'), findsOneWidget);
    expect(find.text('Loading Chat…'), findsNothing);
    sync.complete(AxDiscussionPage(messages: [message('2', 'New Chat')]));
    await tester.pumpAndSettle();
    expect(find.text('Cached Chat'), findsOneWidget);
    expect(find.text('New Chat'), findsOneWidget);
  });
  testWidgets(
      'pending send survives destruction and replaces temporary ID after return',
      (tester) async {
    await size(tester);
    await tester.pumpWidget(page('w'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Pending Chat');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(find.text('Pending Chat'), findsOneWidget);
    await tester.pumpWidget(page('other'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page('w'));
    await tester.pumpAndSettle();
    expect(find.text('Pending Chat'), findsOneWidget);
    source.sends.single.complete(message('saved', 'Saved Chat'));
    await tester.pumpAndSettle();
    expect(find.text('Pending Chat'), findsNothing);
    expect(find.text('Saved Chat'), findsOneWidget);
    expect(cache.peek('w').messages.single.id, 'saved');
  });
  testWidgets(
      'failed optimistic edit restores previous text and shows existing error',
      (tester) async {
    await size(tester);
    source.server = [message('1', 'Original Chat')];
    await tester.pumpWidget(page('w'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Original Chat'), 'Optimistic edit');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Optimistic edit'), findsOneWidget);
    source.edits.single.completeError(StateError('denied'));
    await tester.pumpAndSettle();
    expect(find.text('Original Chat'), findsOneWidget);
    expect(find.textContaining('Failed to update message:'), findsOneWidget);
  });
  testWidgets('failed send removes temporary text and shows existing error',
      (tester) async {
    await size(tester);
    await tester.pumpWidget(page('w'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Failed Chat');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    source.sends.single.completeError(StateError('denied'));
    await tester.pumpAndSettle();
    expect(find.text('Failed Chat'), findsNothing);
    expect(find.textContaining('Failed to save message:'), findsOneWidget);
  });
}

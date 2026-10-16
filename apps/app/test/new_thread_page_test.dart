import 'dart:async';

import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/app_shell.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'package:conclave_app/src/ax/ax_work_models.dart';
import 'package:conclave_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';
import 'package:conclave_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

const space = AxSpace(
    id: 'space-new',
    name: 'Space',
    branch: '',
    lastActivity: '',
    role: 'collaborator');
const created = AxThread(
    id: 'thread-created',
    spaceId: 'space-new',
    name: 'Created',
    lead: '',
    status: 'active',
    brief: '',
    primaryWorkspace: '',
    queueStatus: '');

Finder get _messageFields => find.descendant(
    of: find.byType(ThreadPage), matching: find.byType(TextField));

void main() {
  test('Thread names use opening words and are bounded to 22 characters', () {
    expect(threadNameFromMessage('  Fix  the\nlogin flow  '),
        'Fix the login flow');
    expect(
        threadNameFromMessage('Please improve the login screen and settings'),
        'Please improve the');
    expect(threadNameFromMessage('abcdefghijklmnopqrstuvwxyz1234567890'),
        'abcdefghijklmnopqrstuv');
    expect(threadNameFromMessage('😀' * 40).characters.length, 22);
    expect(threadNameFromMessage('   '), 'New Thread');
  });

  for (final wide in [false, true]) {
    testWidgets('draft header and tabs sit above inputs wide=$wide',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(wide ? 1200 : 800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = _Source();
      var creations = 0;
      String? createdName;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NewThreadPage(
        space: space.copyWith(description: 'Description at the top'),
        dataSource: source,
        discussionCache: AxDiscussionCache.forSource(source),
        workHistoryCache: AxWorkHistoryCache.forSource(source),
        threadViewStateStore: MemoryAxThreadViewStateStore(),
        createThread: (value) async {
          creations++;
          createdName = value;
          return created;
        },
        onOpenThread: (_) {},
      ))));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('new-thread-name'));
      expect(tester.getRect(find.text('Description at the top')).bottom,
          lessThan(tester.getRect(name).top));
      expect(find.byKey(const ValueKey('chat-history-scroll')), findsNothing);
      expect(find.byKey(const ValueKey('work-history-scroll')), findsNothing);
      expect(find.byTooltip('Bold'), findsOneWidget);
      expect(find.byTooltip('Show Markdown controls'), findsNothing);
      expect(find.byTooltip('Hide Markdown controls'), findsNothing);
      expect(find.text('Preview'), findsOneWidget);
      final tabs = find.byType(TabBar);
      expect(tabs, wide ? findsNWidgets(2) : findsOneWidget);
      for (var i = 0; i < (wide ? 2 : 1); i++) {
        expect(
            tester.getRect(_messageFields.at(i)).top -
                tester.getRect(tabs.at(i)).bottom,
            closeTo(17, 2));
      }
      final create = find.widgetWithText(TextButton, 'Create Thread');
      expect(tester.widget<TextButton>(create).onPressed, isNull);
      await tester.enterText(name, '   ');
      await tester.pump();
      expect(tester.widget<TextButton>(create).onPressed, isNull);
      await tester.enterText(name, 'Named Thread');
      await tester.pump();
      expect(tester.widget<TextButton>(create).onPressed, isNotNull);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(creations, 1);
      expect(createdName, 'Named Thread');
      expect(source.sends, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('first send uses the optional explicit Thread name',
      (tester) async {
    final source = _Source();
    String? name;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NewThreadPage(
      space: space,
      dataSource: source,
      discussionCache: AxDiscussionCache.forSource(source),
      workHistoryCache: AxWorkHistoryCache.forSource(source),
      threadViewStateStore: MemoryAxThreadViewStateStore(),
      createThread: (value) async {
        name = value;
        return created;
      },
      onOpenThread: (_) {},
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Description at the top'), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('new-thread-name')), '  Custom name  ');
    await tester.enterText(_messageFields.first, 'A different request');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(name, 'Custom name');
    expect(source.sends, ['chat:thread-created:A different request']);
  });

  for (final work in [false, true]) {
    testWidgets(
        'first ${work ? 'Work' : 'Chat'} send creates before submitting',
        (tester) async {
      if (work) {
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
      }
      final source = _Source();
      final stateStore = MemoryAxThreadViewStateStore();
      var creations = 0;
      String? name;
      AxThread? opened;
      final ready = Completer<AxThread>();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NewThreadPage(
        space: space,
        dataSource: source,
        discussionCache: AxDiscussionCache.forSource(source),
        workHistoryCache: AxWorkHistoryCache.forSource(source),
        threadViewStateStore: stateStore,
        currentUserId: 'user',
        createThread: (value) {
          creations++;
          name = value;
          return ready.future;
        },
        onOpenThread: (thread) => opened = thread,
      ))));
      await tester.pumpAndSettle();
      expect(creations, 0);
      expect(source.historyReads, isEmpty);
      if (work) {
        await tester.enterText(_messageFields.first, 'Unsent Chat draft');
        await tester.tap(find.text('Work').first);
        await tester.pumpAndSettle();
      }
      const prompt = 'Please improve the login screen and settings';
      await tester.enterText(
          work ? _messageFields.last : _messageFields.first, prompt);
      final send = find.byTooltip(work ? 'Send request' : 'Send message');
      await tester.tap(send);
      await tester.pump();
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.send_rounded).last)
              .onPressed,
          isNull);
      expect(creations, 1);
      expect(name, 'Please improve the');
      expect(source.sends, isEmpty);
      ready.complete(created);
      await tester.pumpAndSettle();
      expect(source.sends, [
        work ? 'work:thread-created:$prompt' : 'chat:thread-created:$prompt'
      ]);
      expect(opened?.id, created.id);
      final saved = await stateStore.load(userId: 'user', threadId: created.id);
      expect(saved?.tabIndex, work ? 1 : 0);
      if (work) expect(saved?.chatDraft, 'Unsent Chat draft');
      expect(work ? saved?.workDraft : saved?.chatDraft, '');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Space route shows a draft and navigates after its first send',
      (tester) async {
    final source = _ShellSource();
    await tester.pumpWidget(ConclaveAppShell(
      services: const DefaultPlatformServices(),
      dataSource: source,
      initialUri: Uri.parse('/spaces/space-new'),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(NewThreadPage), findsOneWidget);
    expect(source.creations, 0);
    expect(source.historyReads, isEmpty);
    await tester.enterText(
        find
            .descendant(of: find.byType(ThreadPage), matching: _messageFields)
            .first,
        'Start this conversation');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(source.creations, 1);
    expect(source.sends, ['chat:thread-created:Start this conversation']);
    expect(find.byType(NewThreadPage), findsNothing);
    expect(find.byType(ThreadPage), findsOneWidget);
    expect(tester.widget<ThreadPage>(find.byType(ThreadPage)).thread.id,
        created.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation failure preserves draft without sending',
      (tester) async {
    final source = _Source();
    var creations = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: NewThreadPage(
      space: space,
      dataSource: source,
      discussionCache: AxDiscussionCache.forSource(source),
      workHistoryCache: AxWorkHistoryCache.forSource(source),
      threadViewStateStore: MemoryAxThreadViewStateStore(),
      createThread: (_) async {
        creations++;
        if (creations == 1) throw StateError('Offline');
        return created;
      },
      onOpenThread: (_) {},
    ))));
    await tester.pumpAndSettle();
    await tester.enterText(_messageFields.first, 'Retry creation');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(source.sends, isEmpty);
    expect(tester.widget<TextField>(_messageFields.first).controller!.text,
        'Retry creation');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    expect(creations, 2);
    expect(source.sends, ['chat:thread-created:Retry creation']);
  });

  for (final work in [false, true]) {
    testWidgets('failed ${work ? 'Work' : 'Chat'} send retries the same Thread',
        (tester) async {
      final source = _Source()..failSend = true;
      var creations = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NewThreadPage(
        space: space,
        dataSource: source,
        discussionCache: AxDiscussionCache.forSource(source),
        workHistoryCache: AxWorkHistoryCache.forSource(source),
        threadViewStateStore: MemoryAxThreadViewStateStore(),
        createThread: (_) async {
          creations++;
          return created;
        },
        onOpenThread: (_) {},
      ))));
      await tester.pumpAndSettle();
      if (work) {
        await tester.tap(find.text('Work').first);
        await tester.pumpAndSettle();
      }
      await tester.enterText(_messageFields.first, 'Keep this draft');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_messageFields.first).controller!.text,
          'Keep this draft');
      source.failSend = false;
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(creations, 1);
      expect(source.sends.length, 2);
      expect(source.sentKeys.toSet().length, 1);
      expect(tester.takeException(), isNull);
    });
  }
}

class _Source extends AxFixtureDataSource {
  final sends = <String>[];
  final sentKeys = <String?>[];
  final historyReads = <String>[];
  bool failSend = false;

  @override
  Future<List<AxDiscussionMessage>> discussionRows(
      {required String threadId}) async {
    historyReads.add(threadId);
    return [];
  }

  @override
  Future<List<AxWorkRequest>> workRequestRows(
      {required String threadId, bool activeOnly = false}) async {
    historyReads.add(threadId);
    return [];
  }

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String threadId,
      required String text,
      List<String> references = const [],
      String? idempotencyKey}) async {
    sends.add('chat:$threadId:$text');
    sentKeys.add(idempotencyKey);
    if (failSend) throw StateError('Offline');
    return super.sendDiscussionMessage(
        threadId: threadId,
        text: text,
        references: references,
        idempotencyKey: idempotencyKey);
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'version': 2,
          'name': 'Work',
          'steps': [
            {'kind': 'implement', 'order': 0}
          ]
        }),
      ];

  @override
  Future<String> createWorkRequest(
      {required String threadId,
      required String workflowId,
      required String prompt,
      List<Map<String, dynamic>> attachments = const [],
      String? idempotencyKey}) async {
    sends.add('work:$threadId:$prompt');
    sentKeys.add(idempotencyKey);
    if (failSend) throw StateError('Offline');
    return 'request-saved';
  }
}

class _ShellSource extends _Source {
  int creations = 0;
  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      [space];
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async =>
      creations == 0 ? [] : [created];
  @override
  Future<AxThread> createThread(
      {required String spaceId,
      required String name,
      String? idempotencyKey}) async {
    creations++;
    return created;
  }
}

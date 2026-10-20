import 'dart:async';

import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';

import 'ax_fixture_data.dart';
import 'conversation_turn_fixture.dart';
import 'package:conclave_app/src/features/common/conclave_markdown_body.dart';
import 'package:conclave_app/src/features/common/markdown_composer.dart';

void main() {
  for (final workflow in [
    ('chat', 1, 'chat', 0),
    ('direct', 2, 'implement', 1)
  ]) {
    testWidgets('${workflow.$1} keeps run and step metadata internal',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final turn = {
        ...turnFixture().toJson(),
        'workflowId': workflow.$1,
        'workflowVersion': workflow.$2,
        'stepKind': workflow.$3,
        'modelName': 'Original Model Name',
        'catalogRevision': 'a' * 64
      };
      final request = AxWorkRequest.fromJson({
        'id': 'R',
        'conversationId': 'conversation-C',
        'requestedByName': 'You',
        'requestedByUserId': 'user-owner',
        'prompt': 'Hello from the user',
        'workflowId': workflow.$1,
        'workflowVersion': workflow.$2,
        'status': 'completed',
        'createdAt': '2026-10-07T10:00:00Z',
        'turns': [turn],
        'workflowRun': {
          'schemaVersion': 1,
          'id': 'internal-workflow-run',
          'conversationId': 'conversation-C',
          'userMessageId': 'message-user-R',
          'triggerMessageId': 'message-user-R',
          'workRequestId': 'R',
          'workflowId': workflow.$1,
          'workflowVersion': workflow.$2,
          'status': 'completed',
          'startedAt': '2026-10-07T10:00:00Z',
          'completedAt': '2026-10-07T10:01:00Z',
          'runtimeRunIds': ['internal-runtime-run'],
          'workerTurnIds': [turn['id']],
          'createdAt': 'now',
          'updatedAt': 'now',
          'stepRuns': [
            {
              'schemaVersion': 1,
              'id': 'internal-step-run',
              'workflowRunId': 'internal-workflow-run',
              'taskId': 'task-R',
              'stepId': workflow.$3,
              'role': workflow.$3,
              'workerId': 'worker-a',
              'modelId': 'model-x',
              'effort': 'medium',
              'workerSessionId': 'internal-session',
              'baseContextRevision': 0,
              'status': 'completed',
              'result': '**Recorded answer**',
              'workerTurnIds': [turn['id']]
            },
            for (final role in ['verify', 'correct'])
              {
                'schemaVersion': 1,
                'id': 'internal-$role-step',
                'workflowRunId': 'internal-workflow-run',
                'taskId': 'task-$role',
                'stepId': role,
                'role': role,
                'workerId': 'future-worker',
                'modelId': 'future-model',
                'effort': 'high',
                'workerSessionId': null,
                'baseContextRevision': 0,
                'status': 'queued',
                'result': null,
                'workerTurnIds': []
              }
          ]
        },
        'steps': [
          {
            'kind': workflow.$3,
            'status': 'completed',
            'workerId': 'worker-a',
            'workerTypeId': 'chatgpt',
            'workerDisplayName': 'ChatGPT',
            'assignmentId': turn['assignmentId'],
            'model': 'model-x',
            'reasoningEffort': 'medium'
          }
        ],
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
                  space: const AxSpace(
                      id: 'space-1',
                      name: 'Space',
                      branch: '',
                      lastActivity: '',
                      role: 'owner'),
                  thread: const AxThread(
                      id: 'thread-1',
                      spaceId: 'space-1',
                      name: 'Stream',
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: _SimpleConversationDataSource(request),
                  currentUserId: 'user-owner',
                  currentUserName: 'You',
                  initialTab: 1,
                  onBackToSpace: _noop,
                  onArchive: _noop))));
      await tester.pumpAndSettle();
      await _openAiHistory(tester);
      expect(_inAiHistory(find.text('Hello from the user')), findsOneWidget);
      expect(find.text('ChatGPT'), findsWidgets);
      expect(find.byTooltip('Original Model Name · Medium'), findsWidgets);
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Image && widget.semanticLabel == 'ChatGPT icon'),
          findsWidgets);
      expect(
          tester
              .widgetList<ConclaveMarkdownBody>(
                  find.byType(ConclaveMarkdownBody))
              .map((body) => body.data),
          contains('**Recorded answer**'));
      for (final label in [
        'Workflow run',
        'Step 1/1',
        'Execution graph',
        'Agent orchestration',
        'internal-workflow-run',
        'internal-step-run',
        'internal-runtime-run',
        'internal-session',
        'Implement'
      ]) {
        expect(find.textContaining(label), findsNothing);
      }
      expect(find.byTooltip('Report issue'), findsNothing);
    });
  }

  for (final workflow in ['chat', 'direct']) {
    for (final code in [
      'session_resume_failed',
      'context_limit_exceeded',
      'execution_failed',
      'unknown_code'
    ]) {
      testWidgets('$workflow $code hides technical diagnostics',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const raw = 'Session C123 failed with resume status XYZ';
        final step = AxWorkRequestStep(
            kind: workflow == 'chat' ? 'chat' : 'implement',
            status: 'failed',
            workerId: 'worker-a',
            workerDisplayName: 'ChatGPT',
            errorCode: code,
            errorMessage: raw,
            assignmentId: 'secret-assignment',
            sessionPolicy: 'durable_session',
            engineVersion: 'secret-engine-version');
        final request = AxWorkRequest(
            id: 'failed-request',
            requestedByName: 'User',
            prompt: 'Continue',
            workflowId: workflow,
            workflowVersion: workflow == 'chat' ? 1 : 2,
            status: 'failed',
            createdAt: '2026-10-07T10:00:00Z',
            error: raw,
            steps: [step]);
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
              id: 'space-1',
              name: 'Space',
              branch: '',
              lastActivity: '',
              role: 'owner'),
          thread: const AxThread(
              id: 'stream-1',
              spaceId: 'space-1',
              name: 'Stream',
              lead: '',
              status: 'active',
              brief: '',
              primaryWorkspace: '',
              queueStatus: ''),
          dataSource: _ContinuityFailureDataSource(request, step),
          onBackToSpace: _noop,
          onArchive: _noop,
        ))));
        await tester.pumpAndSettle();
        final friendly = code == 'session_resume_failed'
            ? 'The worker could not continue the previous conversation. Please retry your request.'
            : code == 'context_limit_exceeded'
                ? 'This conversation exceeds the supported context limit. Start a new Thread with the relevant context.'
                : 'Your request could not be completed. Please retry.';
        expect(find.text(friendly), findsOneWidget);
        expect(find.textContaining('C123'), findsNothing);
        for (final hidden in [
          raw,
          code,
          'secret-assignment',
          'secret-engine-version',
          'Advanced technical details',
          'Session mode'
        ]) {
          expect(find.textContaining(hidden), findsNothing);
        }
        expect(find.textContaining('restored'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final workflow in ['chat', 'direct']) {
    testWidgets('$workflow response details use immutable model and effort',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = [
        for (final config in [
          ('X', 'model-x', 'medium'),
          ('Y', 'model-y', 'high'),
          ('Default', null, null)
        ])
          AxWorkRequest.fromJson({
            'id': config.$1,
            'requestedByName': 'User',
            'prompt': 'Request ${config.$1}',
            'workflowId': workflow,
            'workflowVersion': workflow == 'chat' ? 1 : 2,
            'workflowName': workflow == 'chat' ? 'Chat' : 'Work',
            'status': 'completed',
            'createdAt': '2026-10-07T10:00:00Z',
            'turns': [
              turnFixture(
                      id: config.$1,
                      requestId: config.$1,
                      model: config.$2,
                      effort: config.$3)
                  .toJson()
                ..['workflowId'] = workflow
                ..['workflowVersion'] = workflow == 'chat' ? 1 : 2
            ],
            'steps': [
              {
                'kind': 'implement',
                'status': 'completed',
                'workerId': 'worker-a',
                'assignmentId': 'assignment-${config.$1}',
                'workerTypeId': 'gemini',
                'workerDisplayName': 'Wrong current worker',
                'model': 'wrong-current-model',
                'reasoningEffort': 'low'
              }
            ],
          })
      ];
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: _WorkHistoryDataSource(rows),
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      expect(_inConversation(find.text('ChatGPT')), findsNWidgets(3));
      expect(find.textContaining('model-x'), findsNothing);
      expect(find.textContaining('model-y'), findsNothing);
      expect(
          _inConversation(find.byTooltip('model-x · Medium')), findsOneWidget);
      expect(_inConversation(find.byTooltip('model-y · High')), findsOneWidget);
      expect(_inConversation(find.byTooltip('Default model · Default effort')),
          findsOneWidget);
      expect(find.text('Default model · Default effort'), findsNothing);
      await tester.tap(_inConversation(find.byTooltip('model-x · Medium')));
      await tester.pumpAndSettle();
      expect(find.text('model-x · Medium'), findsOneWidget);
      expect(find.textContaining('Model changed'), findsNothing);
      expect(find.textContaining('Effort changed'), findsNothing);
      expect(find.text('Wrong current worker'), findsNothing);
      expect(find.textContaining('wrong-current-model'), findsNothing);
    });
  }

  testWidgets('composer does not resurrect obsolete Thread execution choices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final choices in [
      (true, false, true),
      (false, true, true),
      (true, true, false)
    ]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: ValueKey(choices),
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: '',
            workConfig: {
              'defaultWorkflowId': 'policy-fixture',
              'bindings': {
                'policy-binding': {'workerId': 'w-chatgpt', 'model': 'o3'}
              },
            }),
        dataSource: _PolicyWorkflowDataSource(
            model: choices.$1, effort: choices.$2, binding: choices.$3),
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      expect(find.text('o3'), findsNothing);
      expect(find.byTooltip('Choose model'), findsNothing);
      expect(find.byTooltip('Choose reasoning effort'), findsNothing);
    }
  });
  testWidgets('history names remain accurate without a loaded catalog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: _SnapshotHistoryDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
    ))));
    await tester.pumpAndSettle();
    await _openAiHistory(tester);
    for (final name in ['Direct', 'Work', 'Chat']) {
      expect(find.text('· $name'), findsOneWidget);
    }
  });
  testWidgets('single Work workflow switches directly from Chat with Markdown',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _CurrentWorkflowUiDataSource();
    final submission = Completer<String>();
    String? sentWorkflow;
    String? sentSource;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: data,
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (source, workflow, _, key) {
        sentSource = source;
        sentWorkflow = workflow;
        return submission.future;
      },
    ))));
    await tester.pumpAndSettle();
    final markdown = tester
        .widgetList<ConclaveMarkdownBody>(find.byType(ConclaveMarkdownBody))
        .map((body) => body.data)
        .toList();
    expect(markdown, containsAll(['**Chat answer**', '**Work answer**']));
    await _askAi(tester);
    await tester.tap(find.byKey(const ValueKey('work-choose-workflow')));
    await tester.pumpAndSettle();
    expect(find.byType(ConclaveMenuEntry<String>), findsNothing);
    expect(find.text('Direct'), findsNothing);
    final chatToggle = find.byKey(const ValueKey('work-toggle-chat'));
    final workButton = find.byKey(const ValueKey('work-choose-workflow'));
    final attachments = find.byKey(const ValueKey('work-add-attachments'));
    expect(tester.getTopRight(attachments).dx,
        closeTo(tester.getTopLeft(chatToggle).dx, 0.1));
    expect(tester.getTopRight(chatToggle).dx,
        closeTo(tester.getTopLeft(workButton).dx, 0.1));
    expect(
        find.descendant(
            of: workButton, matching: find.byIcon(Icons.keyboard_arrow_down)),
        findsNothing);
    expect(find.descendant(of: chatToggle, matching: find.byType(Icon)),
        findsNothing);
    final inactiveChatText = tester.widget<Text>(
        find.descendant(of: chatToggle, matching: find.text('Chat')));
    final inactiveChatColor = inactiveChatText.style!.color!;
    expect(inactiveChatColor.a, 0.5);
    expect(
        tester
            .widget<Material>(find.descendant(
                of: chatToggle, matching: find.byType(Material)))
            .color,
        Colors.transparent);
    await tester.tap(chatToggle);
    await tester.pumpAndSettle();
    final activeChatText = tester.widget<Text>(
        find.descendant(of: chatToggle, matching: find.text('Chat')));
    expect(activeChatText.style!.color!.a, 1.0);

    const source = '## Question\n\n**Explain** this `code`.';
    await tester.enterText(find.byType(TextField).first, source);
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(sentWorkflow, 'chat');
    expect(sentSource, source);
    expect(data.discussionWrites, 0);
    await tester.pumpWidget(const SizedBox());
    submission.complete('chat-saved');
    await tester.pump();
  });
  testWidgets('current Work selection preserves historical Direct labels',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final submission = Completer<String>();
    String? sentWorkflow;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'stream-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: _VersionedWorkflowDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (_, workflow, ___, key) {
        sentWorkflow = workflow;
        return submission.future;
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.text('· Direct'), findsOneWidget);
    await _askAi(tester);
    await tester.tap(find.byKey(const ValueKey('work-choose-workflow')));
    await tester.pumpAndSettle();
    expect(find.byType(ConclaveMenuEntry<String>), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('work-choose-workflow')),
            matching: find.byIcon(Icons.keyboard_arrow_down)),
        findsNothing);
    expect(find.byTooltip('Work settings'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'New work');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(sentWorkflow, 'direct');
    expect(find.text('· Work'), findsOneWidget);
    expect(find.text('· Direct'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    submission.complete('saved-new');
    await tester.pump();
  });

  testWidgets('Thread is one conversation with an optional AI History panel',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [600.0, 999.0, 1000.0, 1800.0]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
        child: SizedBox(
            width: width,
            child: ThreadPage(
              key: ValueKey(width),
              space: const AxSpace(
                  id: 'space-1',
                  name: 'Space',
                  branch: '',
                  lastActivity: '',
                  role: 'owner'),
              thread: const AxThread(
                  id: 'thread-1',
                  spaceId: 'space-1',
                  name: 'Stream',
                  lead: '',
                  status: 'active',
                  brief: '',
                  primaryWorkspace: '',
                  queueStatus: ''),
              dataSource: _PinnedHistoryDataSource(),
              onBackToSpace: _noop,
              onArchive: _noop,
            )),
      ))));
      await tester.pumpAndSettle();
      final chat = find.byKey(const ValueKey('chat-history-scroll'));
      final work = find.byKey(const ValueKey('work-history-scroll'));
      final history = find.byKey(const ValueKey('thread-AI History-pane'));
      expect(find.byType(TabBar), findsNothing);
      expect(tester.getSize(chat).width, lessThanOrEqualTo(800));
      expect(
          tester
              .widget<Padding>(
                  find.byKey(const ValueKey('thread-Conversation-padding')))
              .padding,
          const EdgeInsets.fromLTRB(20, 0, 20, 20));
      expect(work, findsNothing);
      expect(find.byType(MarkdownComposer), findsOneWidget);
      final mode = find.byKey(const ValueKey('conversation-composer-mode'));
      expect(find.descendant(of: find.byType(MarkdownComposer), matching: mode),
          findsOneWidget);
      expect(tester.getRect(mode).right,
          lessThanOrEqualTo(tester.getRect(find.byType(TextField)).left));
      final messageSwitch =
          tester.getRect(find.byKey(const ValueKey('composer-mode-message')));
      final aiSwitch =
          tester.getRect(find.byKey(const ValueKey('composer-mode-ai')));
      expect(messageSwitch.center.dx, aiSwitch.center.dx);
      expect(messageSwitch.bottom, lessThanOrEqualTo(aiSwitch.top));
      bool selected(String mode) => tester
          .widget<IconButton>(find.byKey(ValueKey('composer-mode-$mode')))
          .isSelected!;
      expect(selected('message'), isTrue);
      expect(selected('ai'), isFalse);
      expect(messageSwitch.width, 28);
      await tester.tap(find.byKey(const ValueKey('composer-mode-ai')));
      await tester.pumpAndSettle();
      expect(selected('ai'), isTrue);
      expect(find.descendant(of: find.byType(MarkdownComposer), matching: mode),
          findsOneWidget);
      expect(find.byKey(const ValueKey('emoji-picker-button')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('composer-mode-message')));
      await tester.pumpAndSettle();
      expect(selected('message'), isTrue);

      final conversationTab = find.byKey(const ValueKey('conversation-tab'));
      final historyTab = find.byKey(const ValueKey('ai-history-toggle'));
      Color? tabColor(Finder tab) =>
          tester.widget<TextButton>(tab).style!.foregroundColor!.resolve({});
      expect(tabColor(conversationTab), Colors.white);
      expect(tabColor(historyTab), Colors.grey);
      expect(
          find.descendant(
              of: conversationTab,
              matching: find.byIcon(Icons.chat_bubble_outline_rounded)),
          findsOneWidget);
      expect(tester.getRect(conversationTab).right,
          lessThanOrEqualTo(tester.getRect(historyTab).left));

      await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
      await tester.pump();
      final visibility = find.byKey(const ValueKey('thread-view-visibility'));
      expect(tester.widget<Opacity>(visibility).opacity, 0);
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(visibility).opacity, 1);
      final workPosition = tester
          .state<ScrollableState>(find
              .descendant(of: work, matching: find.byType(Scrollable))
              .first)
          .position;
      final settledOffset = workPosition.pixels;
      await tester.pump();
      expect(workPosition.pixels, settledOffset);
      expect(work, findsOneWidget);
      expect(
          tabColor(find.byKey(const ValueKey('ai-history-tab'))), Colors.white);
      expect(tabColor(find.byKey(const ValueKey('ai-history-conversation'))),
          Colors.grey);
      expect(find.text('Read-only'), findsNothing);
      expect(find.byTooltip('Close AI History'), findsNothing);
      // AI History never accepts input.
      expect(find.descendant(of: history, matching: find.byType(TextField)),
          findsNothing);
      // Only one pane is shown at any width.
      expect(chat, findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ai-history-conversation')));
      await tester.pump();
      expect(tester.widget<Opacity>(visibility).opacity, 0);
      await tester.pumpAndSettle();
      expect(tester.widget<Opacity>(visibility).opacity, 1);
      expect(work, findsNothing);
      expect(chat, findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('edited chat messages show the modified marker and time',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          space: const AxSpace(
            id: 'space-1',
            name: 'Space One',
            branch: '',
            lastActivity: 'today',
            role: 'collaborator',
          ),
          thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Research',
            lead: 'Owner',
            status: 'active',
            brief: 'Understand the problem.',
            primaryWorkspace: 'Workspace One',
            queueStatus: 'Idle',
          ),
          dataSource:
              _DiscussionDataSource(editedAt: '2026-10-06T12:00:00.000Z'),
          currentUserId: 'user-owner',
          onBackToSpace: _noop,
          onArchive: _noop,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Edited 2026-10-06 ·'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) =>
          widget is Text && widget.data?.startsWith('2026-10-05 ·') == true),
      findsNothing,
    );
  });

  testWidgets(
      'Work appears before validation and progress becomes result or error',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final reject in [false, true]) {
      final data = _SlowSubmissionDataSource();
      const previous = AxWorkRequest(
        id: 'previous-response',
        requestedByName: 'You',
        prompt: 'Earlier request',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'completed',
        createdAt: '2026-10-05T10:00:00Z',
        steps: [],
        finalText: 'Earlier completed response',
      );
      data.requests = [previous];
      final submitted = Completer<String>();
      var sends = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: ValueKey(reject),
        initialTab: 1,
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: data,
        currentUserId: 'user-owner',
        onBackToSpace: _noop,
        onArchive: _noop,
        onRunWork: (_, __, ___, key) {
          sends++;
          return submitted.future;
        },
      ))));
      await tester.pumpAndSettle();
      await _askAi(tester);
      final previousBody = find.byWidgetPredicate((widget) =>
          widget is ConclaveMarkdownBody &&
          widget.data == 'Earlier completed response');
      final previousElement = tester.element(previousBody);
      void expectPreviousUnchanged() {
        expect(tester.element(previousBody), same(previousElement));
        expect(tester.widget<ConclaveMarkdownBody>(previousBody).data,
            'Earlier completed response');
        expect(
            tester.widget<ConclaveMarkdownBody>(previousBody).key,
            const ValueKey(
                ('previous-response', 'Earlier completed response')));
      }

      await tester.enterText(
          find.byType(TextField).first, '**Immediate request**');
      await tester
          .tap(find.byKey(const ValueKey('composer-send-Send request')));
      await tester.pump();
      expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          isEmpty);
      expect(
          _inConversation(find.byType(ConclaveMarkdownBody)).evaluate().where(
              (element) =>
                  (element.widget as ConclaveMarkdownBody).data ==
                  '**Immediate request**'),
          hasLength(1));
      expect(
          _inConversation(find.byType(ConclaveMarkdownBody)).evaluate().any(
              (element) =>
                  (element.widget as ConclaveMarkdownBody).data ==
                  'Checking that everything is ready…'),
          isTrue);
      expectPreviousUnchanged();
      // A concurrent history insertion moves the completed response while the
      // new request is still displaying progress.
      AxWorkHistoryCache.forSource(data).patchRequest(
          'thread-1',
          const AxWorkRequest(
            id: 'older-response',
            requestedByName: 'You',
            prompt: 'Older request',
            workflowId: 'direct',
            workflowVersion: 1,
            status: 'completed',
            createdAt: '2026-10-04T10:00:00Z',
            steps: [],
            finalText: 'Older completed response',
          ));
      await tester.pump();
      expectPreviousUnchanged();
      expect(sends, 0);
      expect(find.byTooltip('Refresh Work history'), findsNothing);
      final pendingInput =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(pendingInput.enabled, isTrue);
      await tester.tap(find.byType(TextField).first);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.enterText(find.byType(TextField).first, 'Next draft');
      expect(pendingInput.controller!.text, 'Next draft');
      expect(
          tester
              .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.send_rounded))
              .onPressed,
          isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sends, 0);
      // Leave the input empty so validation failure restores the original.
      await tester.enterText(find.byType(TextField).first, '');
      await AxWorkHistoryCache.forSource(data).refresh('thread-1');
      await tester.pumpAndSettle();
      expect(
          _inConversation(find.byType(ConclaveMarkdownBody)).evaluate().where(
              (element) =>
                  (element.widget as ConclaveMarkdownBody).data ==
                  '**Immediate request**'),
          hasLength(1));
      data.ready.complete(reject ? ['Space access is required.'] : []);
      await tester.pumpAndSettle();
      if (reject) {
        expect(sends, 0);
        expect(
            _inConversation(find.textContaining('Space access is required.')),
            findsOneWidget);
        expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            '**Immediate request**');
      } else {
        expect(sends, 1);
        expect(tester.widget<TextField>(find.byType(TextField).first).enabled,
            isTrue);
        await tester.enterText(
            find.byType(TextField).first, 'Draft while sending');
        expect(
            _inConversation(find.byType(ConclaveMarkdownBody)).evaluate().any(
                (element) =>
                    (element.widget as ConclaveMarkdownBody).data ==
                    'Sending your request…'),
            isTrue);
        data.requests = [
          previous,
          const AxWorkRequest(
              id: 'saved-1',
              requestedByName: 'You',
              requestedByUserId: 'user-owner',
              prompt: '**Immediate request**',
              workflowId: 'direct',
              workflowVersion: 1,
              status: 'running',
              createdAt: '2026-10-06T10:00:00Z',
              steps: [],
              finalText: null)
        ];
        submitted.complete('saved-1');
        await tester.pumpAndSettle();
        expectPreviousUnchanged();
        expect(
            _inConversation(find
                .textContaining('A previous request is still in progress.')),
            findsNothing);
        expect(find.text('Cancel pending request'), findsNothing);
        expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'Draft while sending');
        await tester.enterText(find.byType(TextField).first, 'Next request');
        expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'Next request');
        expect(
            tester
                .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.send_rounded))
                .onPressed,
            isNotNull);
        await tester
            .tap(find.byKey(const ValueKey('composer-send-Send request')));
        await tester.pumpAndSettle();
        // Sending while a request processes queues the message.
        expect(sends, 1);
        expect(find.byKey(const ValueKey('work-queue-panel')), findsOneWidget);
        expect(find.text('Next request'), findsOneWidget);
        await tester.tap(find.byTooltip('Send now'));
        await tester.pumpAndSettle();
        expect(find.text('Cancel previous request?'), findsOneWidget);
        expect(find.text('Cancel and send'), findsOneWidget);
        await tester.tap(find.text('Cancel and send'));
        await tester.pumpAndSettle();
        expect(sends, 2);
        expect(data.cancelledWorkRequestIds, ['saved-1']);
        data.requests = [
          previous,
          const AxWorkRequest(
            id: 'saved-1',
            requestedByName: 'You',
            requestedByUserId: 'user-owner',
            prompt: '**Immediate request**',
            workflowId: 'direct',
            workflowVersion: 1,
            status: 'completed',
            createdAt: '2026-10-06T10:00:00Z',
            steps: [],
            finalText: 'Completed answer',
          )
        ];
        await AxWorkHistoryCache.forSource(data).refresh('thread-1');
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.send_rounded))
                .onPressed,
            isNotNull);
        expect(
            _inConversation(find.byType(ConclaveMarkdownBody)).evaluate().any(
                (element) =>
                    (element.widget as ConclaveMarkdownBody).data ==
                    'Completed answer'),
            isTrue);
        expect(
            _inConversation(find.byType(ConclaveMarkdownBody)).evaluate().where(
                (element) =>
                    (element.widget as ConclaveMarkdownBody).data ==
                    '**Immediate request**'),
            hasLength(1));
      }
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('messages sent while a request runs are queued and sent next',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _SlowSubmissionDataSource()..ready.complete([]);
    AxWorkRequest running(String status) => AxWorkRequest(
          id: 'running-1',
          requestedByName: 'You',
          requestedByUserId: 'user-owner',
          prompt: 'First request',
          workflowId: 'direct',
          workflowVersion: 1,
          status: status,
          createdAt: '2026-10-06T10:00:00Z',
          steps: const [],
          finalText: status == 'completed' ? 'First answer' : null,
        );
    data.requests = [running('running')];
    final prompts = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: data,
      currentUserId: 'user-owner',
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (prompt, __, ___, key) async {
        prompts.add(prompt);
        return 'saved-${prompts.length}';
      },
    ))));
    await tester.pumpAndSettle();
    await _askAi(tester);
    final send = find.byKey(const ValueKey('composer-send-Send request'));
    for (final text in ['Second', 'Third', 'Dropped']) {
      await tester.enterText(find.byType(TextField).first, text);
      await tester.tap(send);
      await tester.pumpAndSettle();
    }
    expect(prompts, isEmpty);
    expect(find.text('Cancel previous request?'), findsNothing);
    expect(find.byKey(const ValueKey('work-queue-panel')), findsOneWidget);
    expect(find.textContaining('Queued · 3'), findsOneWidget);

    // Remove one; edit another back into the composer and queue it again.
    await tester.tap(find.byTooltip('Remove from queue').last);
    await tester.pumpAndSettle();
    expect(find.text('Dropped'), findsNothing);
    await tester.tap(find.byTooltip('Edit').last);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Third');
    await tester.enterText(find.byType(TextField).first, 'Third edited');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.textContaining('Queued · 2'), findsOneWidget);

    data.requests = [running('completed')];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pumpAndSettle();
    // Only the head of the queue is sent; the next waits for it to finish.
    expect(prompts, ['Second']);
    expect(find.textContaining('Queued · 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('sending a queued message scrolls to the latest content',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _SlowSubmissionDataSource()..ready.complete([]);
    final longAnswer = List.generate(80, (i) => 'Answer line $i').join('\n\n');
    AxWorkRequest running(String status) => AxWorkRequest(
          id: 'running-1',
          requestedByName: 'You',
          requestedByUserId: 'user-owner',
          prompt: 'First request',
          workflowId: 'direct',
          workflowVersion: 1,
          status: status,
          createdAt: '2026-10-06T10:00:00Z',
          steps: const [],
          finalText: status == 'completed' ? 'Done' : null,
        );
    final earlier = AxWorkRequest(
      id: 'earlier-1',
      requestedByName: 'You',
      requestedByUserId: 'user-owner',
      prompt: 'Earlier request',
      workflowId: 'direct',
      workflowVersion: 1,
      status: 'completed',
      createdAt: '2026-10-06T09:00:00Z',
      steps: const [],
      finalText: longAnswer,
    );
    data.requests = [earlier, running('running')];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: data,
      currentUserId: 'user-owner',
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (prompt, __, ___, key) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return 'saved-1';
      },
    ))));
    await tester.pumpAndSettle();
    await _askAi(tester);
    await tester.enterText(find.byType(TextField).first, 'Queued follow-up');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();

    ScrollPosition history() => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((state) => state.position)
        .where((position) => position.maxScrollExtent > 0)
        .reduce((a, b) => a.maxScrollExtent >= b.maxScrollExtent ? a : b);
    // The reader scrolls up while the first request is still running.
    history().jumpTo(0);
    await tester.pumpAndSettle();
    expect(history().pixels, 0);

    // It finishes; the queued message is sent and the view follows it.
    data.requests = [earlier, running('completed')];
    await AxWorkHistoryCache.forSource(data).refresh('thread-1');
    await tester.pump();
    // The reader is still scrolled up while the queued send is in flight.
    history().jumpTo(0);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('work-queue-panel')), findsNothing);
    final position = history();
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('Chat and Work controls stay fixed while history scrolls',
      (tester) async {
    for (final tab in [0, 1]) {
      final data = _PinnedHistoryDataSource();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ThreadPage(
        key: ValueKey(tab),
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Stream',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: data,
        onBackToSpace: _noop,
        onArchive: _noop,
      ))));
      await tester.pumpAndSettle();
      // Work Requests are part of the one conversation; tab 1 composes them.
      if (tab == 1) await _askAi(tester);
      final history = find.byKey(const ValueKey('chat-history-scroll'));
      final field = find.byType(TextField).last;
      final before = tester.getRect(field);
      final scrollable =
          find.descendant(of: history, matching: find.byType(Scrollable)).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.extentAfter, closeTo(0, 1));
      await tester.drag(history, const Offset(0, 250));
      await tester.pumpAndSettle();
      expect(position.extentAfter, greaterThan(24));
      final readingOffset = position.pixels;
      // Changing the composer rebuilds the page without pulling the reader down.
      await tester.enterText(field, 'A new draft');
      if (tab == 1) {
        data.requests = [
          ...data.requests,
          _workRequest('new-result', 'completed')
        ];
        await AxWorkHistoryCache.forSource(data).refresh('thread-1');
      }
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(readingOffset, 1));
      await tester.drag(history, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(position.extentAfter, lessThanOrEqualTo(24));
      if (tab == 1) {
        data.requests = [
          ...data.requests,
          _workRequest('another-result', 'completed')
        ];
        await AxWorkHistoryCache.forSource(data).refresh('thread-1');
        await tester.pumpAndSettle();
        expect(position.extentAfter, closeTo(0, 1));
      }
      expect(position.pixels, greaterThan(0));
      expect(tester.getRect(field), before);
      expect(find.ancestor(of: field, matching: history), findsNothing);
      if (tab == 1) {
        expect(find.byKey(const ValueKey('composer-send-Send request')),
            findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('conversation interleaves Work with Chat and Ask AI runs Work',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? sent;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '',
          canExecuteWork: true),
      dataSource: _ConversationMixDataSource(),
      currentUserId: 'user-owner',
      onBackToSpace: _noop,
      onArchive: _noop,
      onRunWork: (source, _, __, ___) async {
        sent = source;
        return 'request-new';
      },
    ))));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('chat-history-scroll'));
    double top(String text) => tester
        .getTopLeft(find.descendant(of: history, matching: find.text(text)))
        .dy;
    // Chat and Work read as one timeline in time order.
    expect(top('Before AI'), lessThan(top('Research auth')));
    expect(top('Research auth'), lessThan(top('Use passkeys')));
    expect(top('Use passkeys'), lessThan(top('After AI')));
    expect(find.byKey(const ValueKey('work-history-scroll')), findsNothing);
    // The live request is not a Chat message: no edit or delete.
    expect(find.byTooltip('Edit message'), findsNWidgets(2));
    expect(find.byTooltip('Delete message'), findsNWidgets(2));

    await _askAi(tester);
    await tester.enterText(find.byType(TextField).last, 'Next request');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    expect(sent, 'Next request');
  });
  testWidgets('Thread header clears the active Conversation or AI History',
      (tester) async {
    final cleared = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'space-1',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'owner'),
      thread: const AxThread(
          id: 'thread-1',
          spaceId: 'space-1',
          name: 'Stream',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: const AxFixtureDataSource(),
      onBackToSpace: _noop,
      onArchive: _noop,
      onClearConversation: () async => cleared.add('conversation'),
      onClearAiHistory: () async => cleared.add('ai'),
    ))));
    await tester.pumpAndSettle();
    final conversation =
        find.byKey(const ValueKey('clear-conversation-history'));
    final ai = find.byKey(const ValueKey('clear-ai-history'));
    expect(conversation, findsOneWidget);
    expect(ai, findsNothing);
    // Cancelling the confirmation clears nothing.
    await tester.tap(conversation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cleared, isEmpty);
    await tester.tap(conversation);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(cleared, ['conversation']);

    await _openAiHistory(tester);
    await tester.tap(ai);
    await tester.pumpAndSettle();
    expect(find.textContaining('Completed AI answers stay'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(cleared, ['conversation', 'ai']);
  });

  testWidgets('Chat shows archived AI exchanges as read-only Worker answers',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 600,
                child: ThreadPage(
                  space: const AxSpace(
                      id: 'space-1',
                      name: 'Space',
                      branch: '',
                      lastActivity: '',
                      role: 'owner'),
                  thread: const AxThread(
                      id: 'stream-1',
                      spaceId: 'space-1',
                      name: 'Chat',
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: _ArchivedAiDiscussionDataSource(),
                  currentUserId: 'user-owner',
                  onBackToSpace: _noop,
                  onArchive: _noop,
                )))));
    await tester.pumpAndSettle();
    expect(find.text('Research auth'), findsOneWidget);
    expect(find.text('Use passkeys'), findsOneWidget);
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('chat-history-scroll')),
            matching: find.byIcon(Icons.auto_awesome_rounded)),
        findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Text && widget.data?.startsWith('Asked AI · ') == true),
        findsOneWidget);
    // Archived AI entries are history: neither the request nor the answer
    // may be edited.
    expect(find.byTooltip('Edit message'), findsNothing);
    expect(find.byTooltip('Copy Markdown'), findsNWidgets(2));
  });
  testWidgets('Chat create edit and copy preserve raw Markdown',
      (tester) async {
    final ds = _MarkdownDiscussionDataSource();
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
    await tester.binding.setSurfaceSize(const Size(1300, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 600,
                child: ThreadPage(
                  space: const AxSpace(
                      id: 'space-1',
                      name: 'Space',
                      branch: '',
                      lastActivity: '',
                      role: 'owner'),
                  thread: const AxThread(
                      id: 'stream-1',
                      spaceId: 'space-1',
                      name: 'Chat',
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: ds,
                  currentUserId: 'user-owner',
                  onBackToSpace: _noop,
                  onArchive: _noop,
                )))));
    await tester.pumpAndSettle();
    const source = '  **raw**\n\n```dart\nfinal x = 1;\n```\n';
    await tester.enterText(find.byType(TextField).first, source);
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(ds.createdSource, source);
    final timestamp = find.byWidgetPredicate((widget) =>
        widget is Text && widget.data?.startsWith('2026-10-06 ·') == true);
    expect(timestamp, findsOneWidget);
    expect(tester.getTopLeft(timestamp).dx,
        lessThan(tester.getTopLeft(find.byTooltip('Edit message')).dx));
    expect(tester.getTopLeft(find.byTooltip('Edit message')).dx,
        lessThan(tester.getTopLeft(find.byTooltip('Copy Markdown')).dx));
    for (final tooltip in [
      'Delete message',
      'Edit message',
      'Copy Markdown',
    ]) {
      expect(
          find.descendant(
              of: find.byTooltip(tooltip),
              matching: find.byType(AnimatedScale)),
          findsOneWidget);
    }
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        source);
    const edited = '\n> **edited**\n- [ ] task\n  ';
    await tester.enterText(find.byType(TextField).first, edited);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(ds.editedSource, edited);
    await tester.tap(find.byTooltip('Copy Markdown'));
    await tester.pump();
    expect(copied, edited);
  });
  testWidgets('Work copies exact Markdown for prompt and fallback response',
      (tester) async {
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
    const prompt = '  **Prompt** [link](https://example.com)\n';
    const response = '\n**Response**\n\n```json\n{"ready":true}\n```\n  ';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      height: 600,
      child: ThreadPage(
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Work',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: ''),
        dataSource: _WorkHistoryDataSource([
          const AxWorkRequest(
              id: 'request-1',
              requestedByName: 'You',
              prompt: prompt,
              workflowId: 'direct',
              workflowVersion: 1,
              status: 'completed',
              createdAt: '2026-10-01T10:00:00Z',
              steps: [
                AxWorkRequestStep(
                    kind: 'implement',
                    status: 'completed',
                    workerId: null,
                    resultText: response),
              ]),
        ]),
        initialTab: 1,
        onBackToSpace: _noop,
        onArchive: _noop,
      ),
    ))));
    await tester.pumpAndSettle();
    await _openAiHistory(tester);
    final copies = find.byTooltip('Copy Markdown');
    expect(copies, findsNWidgets(2));
    expect(
        find.descendant(of: copies.first, matching: find.byType(AnimatedScale)),
        findsOneWidget);
    await tester.ensureVisible(copies.first);
    await tester.tap(copies.first);
    await tester.pump();
    expect(copied, prompt);
    expect(find.text('Prompt copied to clipboard'), findsNothing);
    await tester.ensureVisible(copies.last);
    await tester.tap(copies.last);
    await tester.pump();
    expect(copied, response);
    final timestamps = find.byWidgetPredicate((widget) =>
        widget is Text && widget.data?.startsWith('2026-10-01 ·') == true);
    expect(timestamps, findsNWidgets(2));
  });

  testWidgets('Run failure copies the complete message', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    const message =
        'Cannot run Work\n• The Space Workspace grant does not allow the access this Step needs.';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      height: 600,
      child: ThreadPage(
        space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Chat',
            lead: 'Owner',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: 'idle',
            canExecuteWork: true),
        dataSource: _WorkFormDataSource(),
        onBackToSpace: _noop,
        onArchive: _noop,
        onRunWork: (_, __, ___, key) async =>
            throw const AxApiException(message),
      ),
    ))));
    await tester.pumpAndSettle();
    await _askAi(tester);
    await tester.enterText(find.byType(TextField).last, 'Implement the change');
    await tester.ensureVisible(
        find.byKey(const ValueKey('composer-send-Send request')));
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();
    // The failure diagnostic lives in AI History.
    await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Copy error'));
    await tester.tap(find.byTooltip('Copy error'));
    await tester.pumpAndSettle();
    expect(copied, message);
    final diagnostic = tester.widget<SelectableText>(find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == message));
    final body = ConclaveMessageTypography.fromTheme(
        Theme.of(tester.element(find.byType(ThreadPage))));
    expect(diagnostic.style?.fontFamily, body.fontFamily);
    expect(diagnostic.style?.fontSize, body.fontSize);
    expect(diagnostic.style?.height, body.height);
  });
  testWidgets('Space page exposes actions and only the Threads resource',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var edited = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              description: 'Shared space for Space One',
              instructions: 'Follow standard engineering practices.',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onEdit: () => edited = true,
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify Header items
    expect(find.text('Space One'), findsOneWidget);
    expect(find.text('Shared space for Space One'), findsOneWidget);
    expect(find.text('Follow standard engineering practices.'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byTooltip('Space actions'), findsOneWidget);

    // Open 3-dots popup menu
    await tester.tap(find.byTooltip('Space actions'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(edited, isTrue);

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Each Thread is one focused area of team work.'),
        findsOneWidget);
    expect(find.byTooltip('Create Thread'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Space page updates description when switching spaces',
      (tester) async {
    const p1 = AxSpace(
      id: 'space-1',
      name: 'Space One',
      description: 'First space description',
      branch: '',
      lastActivity: 'today',
    );
    const p2 = AxSpace(
      id: 'space-2',
      name: 'Space Two',
      description: 'Second space description',
      branch: '',
      lastActivity: 'today',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: p1,
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First space description'), findsOneWidget);
    expect(find.text('Second space description'), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: p2,
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First space description'), findsNothing);
    expect(find.text('Second space description'), findsOneWidget);
  });

  testWidgets('Thread shell exposes Chat and Work with viewer-safe controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'viewer',
            ),
            thread: AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Not selected',
              queueStatus: 'Idle',
            ),
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _openAiHistory(tester);
    expect(find.text('AI History'), findsOneWidget);
    expect(find.text('Read-only'), findsNothing);
    expect(find.text('Archive'), findsNothing);
    expect(find.text('What should Conclave do?'), findsNothing);
    expect(
        find.text(
            'Ask AI to do something for the team. Nothing runs until you send the request.'),
        findsOneWidget);
    expect(find.textContaining('lease'), findsNothing);
    expect(find.textContaining('fencing'), findsNothing);
    expect(find.textContaining('Durable Object'), findsNothing);
    expect(find.textContaining('checkout key'), findsNothing);
    await _askAi(tester);
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('Viewer access can read the thread but cannot run Work.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('composer-send-Send request')),
        findsOneWidget);
  });

  testWidgets('collaborator can explicitly run Work', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    String? submittedWork;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
              canExecuteWork: true,
            ),
            dataSource: _WorkFormDataSource(),
            onBackToSpace: _noop,
            onArchive: _noop,
            onRunWork: (work, workflowId, attachments, key) async {
              submittedWork = work;
              return 'request-1';
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _askAi(tester);

    expect(find.text('What should Conclave do?'), findsNothing);
    expect(find.byKey(const ValueKey('work-add-attachments')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-add-attachments')));
    await tester.pumpAndSettle();
    expect(find.text('Add files'), findsOneWidget);
    expect(find.byTooltip('Add attachments'), findsNothing);
    expect(find.byTooltip('Choose workflow'), findsNothing);
    expect(find.byTooltip('Send request'), findsNothing);

    expect(
        find.ancestor(
            of: find.text('Add files'), matching: find.byType(InkWell)),
        findsOneWidget);

    expect(find.text('Add link'), findsNothing);
    expect(
        tester.getBottomLeft(find.text('Add files')).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('work-add-attachments')))
            .dy));
    final menu = find
        .ancestor(
            of: find.text('Add files'),
            matching: find.byWidgetPredicate(
                (widget) => widget is Material && widget.elevation == 12))
        .first;
    expect(
        tester.getBottomLeft(menu).dy,
        closeTo(
            tester
                    .getTopLeft(
                        find.byKey(const ValueKey('work-add-attachments')))
                    .dy -
                8,
            1));
    expect(
        tester.widget<Material>(menu).color,
        ConclaveColors.composerBackground(
            Theme.of(tester.element(menu)).brightness == Brightness.dark));
    expect(
        (tester.widget<Material>(menu).shape as RoundedRectangleBorder)
            .borderRadius,
        BorderRadius.circular(14));
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('work-choose-workflow')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-choose-workflow')));
    await tester.pumpAndSettle();
    expect(find.byType(ConclaveMenuEntry<String>), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('work-choose-workflow')),
            matching: find.text('Work')),
        findsOneWidget);
    const markdownPrompt =
        '  ## Implementation\n\n- **Add tests**\n\n```dart\nfinal ready = true;\n```\n';
    expect(find.byTooltip('Show Markdown controls'), findsNothing);
    expect(find.byTooltip('Bold'), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byType(TextField).first)
            .decoration
            ?.hintText,
        'Write a message...');
    await tester.enterText(find.byType(TextField).first, markdownPrompt);
    expect(
        tester
            .getTopLeft(
                find.byKey(const ValueKey('composer-send-Send request')))
            .dy,
        greaterThanOrEqualTo(
            tester.getBottomLeft(find.byType(TextField).first).dy));
    expect(
        tester
            .getCenter(find.byKey(const ValueKey('composer-send-Send request')))
            .dy,
        closeTo(
            tester
                .getCenter(find.byKey(const ValueKey('work-choose-workflow')))
                .dy,
            1));
    expect(submittedWork, isNull);
    await tester.ensureVisible(
        find.byKey(const ValueKey('composer-send-Send request')));
    await tester.tap(find.byKey(const ValueKey('composer-send-Send request')));
    await tester.pumpAndSettle();

    expect(submittedWork, markdownPrompt);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Thread Work tab uses Space Workflows without thread settings',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    final dataSource = _GenericWorkerConfigDataSource();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Not selected',
              queueStatus: 'Idle',
              canConfigureWork: true,
            ),
            dataSource: dataSource,
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 2,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byTooltip('Work settings'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Work history uses slow fallback and scoped reconnect discovery',
      (tester) async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final dataSource = _WorkHistoryDataSource([
      _workRequest('request-1', 'History before reconnect', status: 'running'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
            ),
            dataSource: dataSource,
            currentUserId: 'user-owner',
            realtimeEvents: events.stream,
            onBackToSpace: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await _openAiHistory(tester);
    expect(find.text('History before reconnect'), findsOneWidget);
    dataSource.requests = [
      const AxWorkRequest(
        id: 'request-1',
        requestedByName: 'Owner',
        prompt: 'History before reconnect',
        workflowId: 'direct',
        workflowVersion: 1,
        status: 'completed',
        createdAt: '2026-10-01T10:00:00.000Z',
        steps: [
          AxWorkRequestStep(
              kind: 'implement',
              status: 'completed',
              workerId: 'worker-1',
              resultText: 'The requested change is complete.')
        ],
      )
    ];
    // A missing WebSocket notification must not leave the reply hidden.
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.text('The requested change is complete.'), findsOneWidget);
    expect(find.text('Implement'), findsNothing);
    expect(find.text('Conclave'), findsOneWidget);
    expect(
      tester
          .widgetList<ConclaveMarkdownBody>(find.byType(ConclaveMarkdownBody))
          .map((body) => body.data),
      contains('The requested change is complete.'),
    );

    dataSource.requests = [
      _workRequest('request-1', 'History restored after reconnect'),
      _workRequest('request-2', 'Run submitted while the browser was away'),
    ];
    events.add({'type': 'reconnect.required'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(dataSource.activeOnlyCalls, contains(false));
    expect(find.text('History before reconnect'), findsNothing);
    expect(find.text('History restored after reconnect'), findsOneWidget);
    expect(
        find.text('Run submitted while the browser was away'), findsOneWidget);
    expect(find.text('Owner'), findsNothing);
  });

  testWidgets('Chat messages can be sent and copied to clipboard',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
            ),
            onBackToSpace: _noop,
            onArchive: _noop,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last,
        'The login failure reproduces on a fresh checkout.');
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('composer-send-Send message')), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(find.text('The login failure reproduces on a fresh checkout.'),
        findsOneWidget);
    expect(find.text('You'), findsNothing);

    // Verify copy message button exists and triggers
    expect(find.byTooltip('Copy Markdown'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy Markdown'));
    await tester.pumpAndSettle();
    expect(find.text('Message copied to clipboard'), findsNothing);

    // Verify edit message button allows editing in-place
    expect(find.byTooltip('Edit message'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit message'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(
            TextField, 'The login failure reproduces on a fresh checkout.'),
        'The login failure reproduces on a fresh checkout. (Updated)');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The login failure reproduces on a fresh checkout. (Updated)'),
        findsOneWidget);

    // Verify delete message button shows confirmation and removes message
    expect(find.byTooltip('Delete message'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete message'));
    await tester.pumpAndSettle();
    expect(find.text('Delete message?'), findsOneWidget);
    expect(
        find.text(
            'Are you sure you want to delete this message? This action cannot be undone.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The login failure reproduces on a fresh checkout. (Updated)'),
        findsOneWidget);

    await tester.tap(find.byTooltip('Delete message'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The login failure reproduces on a fresh checkout. (Updated)'),
        findsNothing);

    // Multiline Markdown source is submitted through the Send action.
    await tester.enterText(
        find.byType(TextField).last, 'Line 1\nLine 2 details');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(find.text('Line 1\nLine 2 details'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Chat messages show their calendar date', (tester) async {
    for (final own in [true, false]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ThreadPage(
            key: ValueKey(own),
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
            ),
            dataSource: _DiscussionDataSource(),
            currentUserId: own ? 'user-owner' : 'another-user',
            onBackToSpace: _noop,
            onArchive: _noop,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text && widget.data?.startsWith('2026-10-05 ·') == true,
        ),
        findsOneWidget,
      );
      final date = find.byWidgetPredicate((widget) =>
          widget is Text && widget.data?.startsWith('2026-10-05 ·') == true);
      final copyX = tester.getTopLeft(find.byTooltip('Copy Markdown')).dx;
      final editX = tester.getTopLeft(find.byTooltip('Edit message')).dx;
      final dateX = tester.getTopLeft(date).dx;
      final bubble = tester.widget<Container>(
          find.ancestor(of: date, matching: find.byType(Container)).first);
      final decoration = bubble.decoration as BoxDecoration;
      expect(decoration.border, isNull);
      expect(
          decoration.color,
          own
              ? ConclaveColors.ownMessageBackground(false)
              : Colors.transparent);
      if (own) {
        final deleteX = tester.getTopLeft(find.byTooltip('Delete message')).dx;
        expect(dateX, lessThan(deleteX));
        expect(deleteX, lessThan(editX));
        expect(editX, lessThan(copyX));
      } else {
        expect(copyX, lessThan(editX));
        expect(editX, lessThan(dateX));
      }
    }
  });

  testWidgets(
      'ThreadPage loads and persists discussions via dataSource and updates when switching threads',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    const dataSource = AxFixtureDataSource();
    const space = AxSpace(
      id: 'space-1',
      name: 'Space One',
      branch: '',
      lastActivity: 'today',
      role: 'collaborator',
    );
    const ws1 = AxThread(
      id: 'ws-1',
      spaceId: 'space-1',
      name: 'Alpha Thread',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Workspace One',
      queueStatus: 'Idle',
    );
    const ws2 = AxThread(
      id: 'ws-2',
      spaceId: 'space-1',
      name: 'Beta Thread',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Workspace One',
      queueStatus: 'Idle',
    );

    var activeThread = ws1;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ThreadPage(
            key: ValueKey(activeThread.id),
            space: space,
            thread: activeThread,
            dataSource: dataSource,
            currentUserId: 'user-owner',
            onBackToSpace: _noop,
            onArchive: _noop,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify initial empty state for ws1
    expect(find.text('No chat messages yet'), findsOneWidget);

    // Send a message on ws1
    await tester.enterText(find.byType(TextField).last, 'Message for Alpha');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(find.text('Message for Alpha'), findsOneWidget);

    // Switch to ws2
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            activeThread = ws2;
            return ThreadPage(
              key: ValueKey(activeThread.id),
              space: space,
              thread: activeThread,
              dataSource: dataSource,
              currentUserId: 'user-owner',
              onBackToSpace: _noop,
              onArchive: _noop,
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify ws2 does not have ws1's message and shows empty state
    expect(find.text('Message for Alpha'), findsNothing);
    expect(find.text('No chat messages yet'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Threads are ordered by their most recent update',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    const ws1 = AxThread(
      id: 'ws-1',
      spaceId: 'p-1',
      name: 'Alpha Thread',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
      updatedAt: '2026-10-01T10:00:00Z',
    );
    const ws2 = AxThread(
      id: 'ws-2',
      spaceId: 'p-1',
      name: 'Beta Thread',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
      updatedAt: '2026-10-03T10:00:00Z',
    );
    const ws3 = AxThread(
      id: 'ws-3',
      spaceId: 'p-1',
      name: 'Gamma Thread',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
      updatedAt: '2026-10-02T10:00:00Z',
    );

    const space = AxSpace(
      id: 'p-1',
      name: 'Test Space',
      branch: 'main',
      lastActivity: 'today',
      threads: [ws1, ws2, ws3],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: space,
            dataSource: _SpaceStreamsSource([ws1, ws2, ws3]),
            onOpenThread: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The read model orders newest updates first: Beta, Gamma, Alpha.
    final listTiles = find.byType(ListTile);
    expect(listTiles, findsNWidgets(3));
    final tiles = tester.widgetList<ListTile>(listTiles).toList();
    expect((tiles[0].title as Text).data, 'Beta Thread');
    expect((tiles[1].title as Text).data, 'Gamma Thread');
    expect((tiles[2].title as Text).data, 'Alpha Thread');

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Space instructions are not rendered or editable',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    AxSpace? updatedSpace;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              description: 'Initial description',
              instructions: 'Initial instructions',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
            onSpaceUpdated: (p) => updatedSpace = p,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Initial instructions'), findsNothing);
    expect(find.text('Space Instructions'), findsNothing);

    // Tap 3-dots popup menu -> Edit
    await tester.tap(find.byTooltip('Space actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Space'), findsOneWidget);

    expect(find.text('Instructions'), findsNothing);

    // Click Save
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Verify update occurred
    expect(updatedSpace, isNotNull);
    expect(updatedSpace!.instructions, 'Initial instructions');

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Space with empty instructions hides instructions section completely',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              description: 'Initial description',
              instructions: '',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Space Instructions'), findsNothing);
    expect(find.text('No instructions configured.'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Creating thread with duplicate name shows warning and stays on dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var createdCount = 0;

    final customDataSource = _DuplicateTestDataSource(
      onCreateThread: () => createdCount++,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              branch: 'main',
              lastActivity: 'today',
              threads: [
                AxThread(
                  id: 'ws-1',
                  spaceId: 'p-1',
                  name: 'Frontend Design',
                  lead: 'Owner',
                  status: 'active',
                  brief: '',
                  primaryWorkspace: '',
                  queueStatus: 'idle',
                ),
              ],
            ),
            dataSource: customDataSource,
            onOpenThread: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Tap create thread button
    await tester.tap(find.byTooltip('Create Thread'));
    await tester.pumpAndSettle();

    expect(find.text('Create Thread'), findsNWidgets(2)); // Title and Button

    // Enter existing name (case-insensitive)
    await tester.enterText(find.byType(TextField).first, 'frontend design');
    await tester.tap(find.widgetWithText(FilledButton, 'Create Thread'));
    await tester.pumpAndSettle();

    // Verify warning is displayed and dialog is still visible
    expect(
        find.text('A thread with this name already exists.'), findsOneWidget);
    expect(find.text('Create Thread'), findsNWidgets(2));
    expect(createdCount, 0);

    // Cancel dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Inviting duplicate member shows warning and stays on dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var inviteCount = 0;

    final customDataSource = _DuplicateTestDataSource(
      onInviteMember: () => inviteCount++,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            section: SpacePageSection.members,
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: customDataSource,
            onOpenThread: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Tap Share Space button
    await tester.tap(find.byTooltip('Share Space'));
    await tester.pumpAndSettle();

    expect(find.text('Invite people'), findsOneWidget); // Dialog title

    // Enter existing member email
    await tester.enterText(
        find.byKey(const ValueKey('invite-new-email')), 'alice@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Send invitation'));
    await tester.pumpAndSettle();

    // Verify warning is displayed and dialog is still visible
    expect(find.text('This user is already a member of the Space.'),
        findsOneWidget);
    expect(find.text('Invite people'), findsOneWidget);
    expect(inviteCount, 0);

    // Cancel dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Owner Members tab distinguishes Members and Pending invitations with Resend and Revoke controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));

    final customDataSource = _MembersTabTestDataSource(
      members: const [
        AxSpaceMember(
          userId: 'u-vitalii',
          email: 'vitalii@nohainc.com',
          displayName: 'Vitalii Noha',
          role: 'owner',
          createdAt: '2026-01-01',
        ),
      ],
      invitations: const [
        AxSpaceInvitation(
          id: 'pinv-1',
          spaceId: 'p-1',
          email: 'ulikossnokia@gmail.com',
          role: 'collaborator',
          status: 'pending',
          createdAt: '2026-10-07T12:00:00Z',
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            section: SpacePageSection.members,
            space: const AxSpace(
              id: 'p-1',
              name: 'Test Space',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: customDataSource,
            onOpenThread: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify distinct sections
    expect(find.text('Members (1)'), findsNothing);
    expect(find.text('Vitalii Noha'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);

    expect(find.text('Pending invitations (1)'), findsOneWidget);
    expect(find.text('ulikossnokia@gmail.com'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);

    // Resend action
    expect(find.byTooltip('Resend invitation'), findsOneWidget);
    await tester.tap(find.byTooltip('Resend invitation'));
    await tester.pumpAndSettle();
    expect(customDataSource.resendCount, 1);

    // Revoke action
    expect(find.byTooltip('Revoke invitation'), findsOneWidget);
    await tester.tap(find.byTooltip('Revoke invitation'));
    await tester.pumpAndSettle();

    // Verify confirmation dialog
    expect(find.text('Revoke invitation?'), findsOneWidget);
    expect(find.text('Cancel pending invitation for ulikossnokia@gmail.com?'),
        findsOneWidget);

    // Confirm revoke
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(customDataSource.revokeCount, 2);

    await tester.pump(const Duration(seconds: 5));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Work tab shows Worker identity and configuration before and after execution',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    final dataSource = _WorkHistoryDataSource([
      const AxWorkRequest(
        id: 'req-system',
        requestedByName: 'Vitalii',
        prompt: 'Preparing system run',
        workflowId: 'direct',
        workflowVersion: 1,
        workflowName: 'Direct Execution',
        status: 'running',
        createdAt: '2026-10-06T10:00:00Z',
        steps: [
          AxWorkRequestStep(
            kind: 'implement',
            status: 'waiting',
            executionPhase: 'delivered',
            workerId: 'w-1',
            workerTypeId: 'chatgpt',
            workerDisplayName: 'ChatGPT',
            model: 'gpt-4o',
            elapsedMs: 5000,
          )
        ],
      ),
      const AxWorkRequest(
        id: 'req-running',
        requestedByName: 'Vitalii',
        prompt: 'Work is underway',
        workflowId: 'direct',
        workflowVersion: 1,
        workflowName: 'Direct Execution',
        status: 'running',
        createdAt: '2026-10-06T10:00:30Z',
        steps: [
          AxWorkRequestStep(
              kind: 'implement',
              status: 'running',
              workerId: 'w-1',
              workerTypeId: 'chatgpt',
              workerDisplayName: 'ChatGPT')
        ],
      ),
      const AxWorkRequest(
        id: 'req-worker',
        requestedByName: 'Vitalii',
        prompt: 'Build feature',
        workflowId: 'direct',
        workflowVersion: 1,
        workflowName: 'Direct Execution',
        status: 'completed',
        createdAt: '2026-10-06T10:01:00Z',
        finalText: 'Feature implementation complete.',
        steps: [
          AxWorkRequestStep(
            kind: 'implement',
            status: 'completed',
            workerId: 'w-1',
            workerDisplayName: 'Claude 3.7 Sonnet',
            workerTypeId: 'claude',
            model: 'claude-3-7-sonnet',
            elapsedMs: 12000,
            resultText: 'Feature implementation complete.',
          )
        ],
      ),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner',
          ),
          thread: const AxThread(
            id: 'stream-1',
            spaceId: 'space-1',
            name: 'Implementation',
            lead: 'Vitalii',
            status: 'active',
            brief: '',
            primaryWorkspace: 'Workspace',
            queueStatus: 'idle',
          ),
          onBackToSpace: _noop,
          onArchive: _noop,
          dataSource: dataSource,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Delivered work shows the selected Worker before provider startup.
    expect(_inConversation(find.text('ChatGPT')), findsNWidgets(2));
    expect(find.textContaining('Direct Execution · 5s'), findsOneWidget);
    expect(find.byTooltip('gpt-4o'), findsOneWidget);

    // Worker identity stays visible; its model is available on demand.
    expect(_inConversation(find.text('Claude 3.7 Sonnet')), findsOneWidget);
    expect(find.textContaining('Direct Execution · 12s'), findsOneWidget);
    expect(find.byTooltip('claude-3-7-sonnet'), findsOneWidget);
    expect(find.textContaining('claude-3-7-sonnet'), findsNothing);
    // A running response has worker attribution before any result text exists.
    final assetImages = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .whereType<AssetImage>()
        .map((asset) => asset.assetName);
    expect(assetImages, contains('assets/worker_icons/chatgpt.png'));
    expect(assetImages, contains('assets/worker_icons/claude.png'));

    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('failed Work requests can be reported once and show confirmation',
      (tester) async {
    final request = AxWorkRequest.fromJson({
      'id': 'request-report',
      'requestedByName': 'You',
      'requestedByUserId': 'user-owner',
      'prompt': 'Please investigate this failure',
      'workflowId': 'direct',
      'workflowVersion': 1,
      'status': 'failed',
      'createdAt': '2026-10-11T10:00:00Z',
      'error': 'Run failed',
      'steps': [
        {
          'kind': 'implement',
          'status': 'failed',
          'workerId': 'worker-1',
          'assignmentId': 'assignment-report',
          'errorCode': 'provider_authentication_required',
        }
      ],
    });
    final dataSource = _IssueReportDataSource(request);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPage(
          initialTab: 1,
          space: const AxSpace(
            id: 'space-1',
            name: 'Space',
            branch: '',
            lastActivity: '',
            role: 'owner',
          ),
          thread: const AxThread(
            id: 'thread-1',
            spaceId: 'space-1',
            name: 'Thread',
            lead: '',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: '',
          ),
          dataSource: dataSource,
          currentUserId: 'user-owner',
          onBackToSpace: _noop,
          onArchive: _noop,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final reportTooltip = find
        .byTooltip('Report issue — sends sanitized technical diagnostics only');
    expect(reportTooltip, findsOneWidget);
    await tester.tap(reportTooltip);
    await tester.pumpAndSettle();
    expect(dataSource.reportCalls, 1);
    expect(find.text('Reported'), findsOneWidget);
    expect(find.textContaining('sanitized technical diagnostics were sent'),
        findsOneWidget);
    expect(
        find.byTooltip(
            'Report issue — sends sanitized technical diagnostics only'),
        findsNothing);
    expect(find.byTooltip('Retry request'), findsNothing);
  });
}

class _IssueReportDataSource extends AxFixtureDataSource {
  _IssueReportDataSource(this.request);

  final AxWorkRequest request;
  var reportCalls = 0;
  var reported = false;

  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage({
    required String threadId,
    int limit = 50,
    String? beforeCreatedAt,
    String? beforeId,
    bool activeOnly = false,
  }) async =>
      AxWorkRequestPage(requests: [request]);

  @override
  Future<AxIssueReport?> loadIssueReport({
    required String requestId,
    String? assignmentId,
  }) async =>
      reported
          ? const AxIssueReport(
              id: 'issue-1',
              publicReference: 'ISS-1',
              status: 'open',
              diagnosticState: 'partial',
              createdAt: '2026-10-11T00:00:00Z',
              updatedAt: '2026-10-11T00:00:00Z',
            )
          : null;

  @override
  Future<AxIssueReport> reportIssue({required String requestId}) async {
    reportCalls++;
    reported = true;
    return const AxIssueReport(
      id: 'issue-1',
      publicReference: 'ISS-1',
      status: 'open',
      diagnosticState: 'partial',
      createdAt: '2026-10-11T00:00:00Z',
      updatedAt: '2026-10-11T00:00:00Z',
    );
  }
}

class _DuplicateTestDataSource extends AxFixtureDataSource {
  _DuplicateTestDataSource({
    this.onCreateThread,
    this.onInviteMember,
  });

  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async => [
        AxThread.fromJson({
          'id': 'ws-1',
          'spaceId': spaceId,
          'name': 'Frontend Design',
          'status': 'active'
        })
      ];

  final VoidCallback? onCreateThread;
  final VoidCallback? onInviteMember;

  @override
  Future<List<AxWorkspace>> loadWorkspaces() async => const [
        AxWorkspace(
          id: 'ws-1',
          name: 'MacBook Pro',
          slug: 'macbook-pro',
          status: 'online',
          role: 'owner',
        ),
      ];
  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants({
    required String spaceId,
  }) async =>
      [
        {
          'id': 'grant-1',
          'workspaceId': 'ws-1',
          'workspaceName': 'MacBook Pro',
        }
      ];

  @override
  Future<List<AxSpaceMember>> loadSpaceMembers({
    required String spaceId,
  }) async =>
      const [
        AxSpaceMember(
          userId: 'u-alice',
          email: 'alice@example.com',
          displayName: 'Alice',
          role: 'collaborator',
          createdAt: '2026-01-01',
        ),
      ];

  @override
  Future<AxThread> createThread({
    required String spaceId,
    required String name,
    String? brief,
    String? lead,
    String? primaryWorkspace,
    String? idempotencyKey,
  }) async {
    onCreateThread?.call();
    return AxThread(
      id: 'ws-new',
      spaceId: spaceId,
      name: name,
      lead: lead ?? 'Owner',
      status: 'active',
      brief: brief ?? '',
      primaryWorkspace: primaryWorkspace ?? '',
      queueStatus: 'idle',
    );
  }

  @override
  Future<void> inviteSpaceMemberWithPermissions({
    required String spaceId,
    required String email,
    required String role,
    required AxSpacePermissions permissions,
  }) async {
    onInviteMember?.call();
  }
}

class _WorkHistoryDataSource extends AxFixtureDataSource {
  _WorkHistoryDataSource(this.requests);

  List<AxWorkRequest> requests;
  final List<bool> activeOnlyCalls = [];

  @override
  Future<List<AxWorkRequest>> workRequestRows({
    required String threadId,
    bool activeOnly = false,
  }) async {
    activeOnlyCalls.add(activeOnly);
    return requests;
  }
}

class _DiscussionDataSource extends AxFixtureDataSource {
  _DiscussionDataSource({this.editedAt});

  final String? editedAt;

  @override
  Future<List<AxDiscussionMessage>> discussionRows({
    required String threadId,
  }) async =>
      [
        AxDiscussionMessage(
          id: 'message-1',
          threadId: 'thread-1',
          authorUserId: 'user-owner',
          authorName: 'Vitalii',
          body: 'A dated message',
          editedAt: editedAt,
          createdAt: '2026-10-05T19:18:00.000Z',
          isMe: true,
        ),
      ];
}

class _MarkdownDiscussionDataSource extends AxFixtureDataSource {
  String? createdSource;
  String? editedSource;

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String threadId,
      required String text,
      List<String> references = const [],
      String? idempotencyKey}) async {
    createdSource = text;
    return AxDiscussionMessage(
        id: 'saved-message',
        threadId: threadId,
        authorUserId: 'user-owner',
        body: text,
        createdAt: '2026-10-06T00:00:00Z');
  }

  @override
  Future<AxDiscussionMessage> editDiscussionMessage(
      {required String messageId,
      required String text,
      List<String> references = const []}) async {
    editedSource = text;
    return AxDiscussionMessage(
        id: messageId,
        threadId: 'stream-1',
        authorUserId: 'user-owner',
        body: text,
        createdAt: '2026-10-06T00:00:00Z');
  }
}

class _ConversationMixDataSource extends _WorkFormDataSource {
  @override
  Future<List<AxDiscussionMessage>> discussionRows({
    required String threadId,
  }) async =>
      [
        for (final (id, body, at) in [
          ('m1', 'Before AI', '2026-10-06T10:00:00Z'),
          ('m2', 'After AI', '2026-10-06T12:00:00Z'),
        ])
          AxDiscussionMessage(
              id: id,
              threadId: threadId,
              authorUserId: 'user-owner',
              body: body,
              createdAt: at,
              isMe: true),
      ];

  @override
  Future<List<AxWorkRequest>> workRequestRows({
    required String threadId,
    bool activeOnly = false,
  }) async =>
      const [
        AxWorkRequest(
          id: 'R',
          requestedByName: 'You',
          requestedByUserId: 'user-owner',
          prompt: 'Research auth',
          workflowId: 'direct',
          workflowVersion: 2,
          status: 'completed',
          createdAt: '2026-10-06T11:00:00Z',
          steps: [],
          finalText: 'Use passkeys',
        ),
      ];
}

class _ArchivedAiDiscussionDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxDiscussionMessage>> discussionRows({
    required String threadId,
  }) async =>
      [
        AxDiscussionMessage.fromJson({
          'id': 'discussion-ai-request-R',
          'threadId': threadId,
          'authorUserId': 'user-owner',
          'authorName': 'Vitalii',
          'body': 'Research auth',
          'createdAt': '2026-10-06T00:00:00Z',
          'kind': 'ai_request',
          'workRequestId': 'R',
          'workerDisplayName': 'ChatGPT',
        }, currentUserId: 'user-owner'),
        AxDiscussionMessage.fromJson({
          'id': 'discussion-ai-answer-R',
          'threadId': threadId,
          'authorUserId': 'user-owner',
          'authorName': 'Vitalii',
          'body': 'Use passkeys',
          'createdAt': '2026-10-06T00:01:00Z',
          'kind': 'ai_answer',
          'workRequestId': 'R',
          'workerDisplayName': 'ChatGPT',
        }, currentUserId: 'user-owner'),
      ];
}

class _WorkFormDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Implement the requested work.',
          'steps': [
            {'kind': 'implement', 'order': 0},
          ],
        }),
      ];
}

class _GenericWorkerConfigDataSource extends _WorkFormDataSource {
  Map<String, dynamic>? savedWorkConfig;

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [
        AxWorker(
          id: 'local-worker-dynamic-test',
          workspaceId: 'workspace-1',
          workspaceName: 'Vitalii’s MacBook Pro',
          workerTypeId: 'dynamic-test-worker',
          displayName: 'Dynamic Test Worker',
          description: 'Catalog-created acceptance Worker.',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
        ),
      ];
  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants({
    required String spaceId,
  }) async =>
      [
        {'workspaceId': 'workspace-1', 'workspaceName': 'Ignored grant label'},
      ];

  @override
  Future<AxThread> updateThread({
    required String threadId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
    Map<String, dynamic>? metadata,
  }) async {
    savedWorkConfig = workConfig;
    return AxThread(
      id: threadId,
      spaceId: 'space-1',
      name: 'Implementation',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Not selected',
      queueStatus: 'Idle',
      workConfig: workConfig ?? const {},
    );
  }
}

class _PinnedHistoryDataSource extends _WorkHistoryDataSource {
  _PinnedHistoryDataSource()
      : super(List.generate(
            20,
            (i) => AxWorkRequest(
                  id: 'request-$i',
                  requestedByName: 'You',
                  prompt: 'Work prompt $i',
                  workflowId: 'direct',
                  workflowVersion: 1,
                  status: 'completed',
                  createdAt: '2026-10-06T10:00:00Z',
                  steps: const [],
                )));

  @override
  Future<List<AxDiscussionMessage>> discussionRows(
          {required String threadId}) async =>
      List.generate(
          20,
          (i) => AxDiscussionMessage(
                id: 'message-$i',
                threadId: threadId,
                authorUserId: 'user-owner',
                body: 'Chat message $i',
                createdAt: '2026-10-06T10:00:00Z',
              ));
}

class _SlowSubmissionDataSource extends _WorkFormDataSource {
  final ready = Completer<List<String>>();
  List<AxWorkRequest> requests = [];
  final cancelledWorkRequestIds = <String>[];

  @override
  Future<void> cancelWorkRequest({required String workRequestId}) async {
    cancelledWorkRequestIds.add(workRequestId);
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
      {required String workRequestId}) async {
    final value = requests.firstWhere((r) => r.id == workRequestId);
    return AxWorkRequestStatus(
        id: value.id,
        status: value.status,
        text: value.finalText,
        originalRequest: value.prompt,
        workflowId: value.workflowId,
        workflowVersion: value.workflowVersion,
        createdAt: value.createdAt,
        steps: value.steps);
  }

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) =>
      ready.future;
  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      requests;
}

class _VersionedWorkflowDataSource extends _WorkFormDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        for (final version in [1, 2])
          AxBuiltinWorkflow.fromJson({
            'id': 'direct',
            'executionPolicy': const {
              'userSelectsWorker': true,
              'userSelectsModel': true,
              'userSelectsEffort': true
            },
            'composerBindingId': 'direct',
            'version': version,
            'name': version == 1 ? 'Direct' : 'Work',
            'description': 'Implement the requested work.',
            'steps': [
              {'kind': 'implement', 'order': 0}
            ],
          }),
      ];
  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        _workRequest('old-direct', 'Historical request'),
      ];
}

class _CurrentWorkflowUiDataSource extends _VersionedWorkflowDataSource {
  int discussionWrites = 0;

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        for (final entry in [
          ['chat', 1, 'Chat', 'chat'],
          ['direct', 1, 'Direct', 'implement'],
          ['direct', 2, 'Work', 'implement'],
          ['research', 1, 'Research', 'research'],
          ['plan_implement', 1, 'Plan & Implement', 'plan'],
          ['implement_verify', 1, 'Implement & Verify', 'implement'],
          ['full_cycle', 1, 'Full Cycle', 'research'],
        ])
          AxBuiltinWorkflow.fromJson({
            'id': entry[0],
            'executionPolicy': const {
              'userSelectsWorker': true,
              'userSelectsModel': true,
              'userSelectsEffort': true
            },
            'composerBindingId': entry[0] == 'direct' ? 'direct' : entry[3],
            'version': entry[1],
            'name': entry[2],
            'description': 'Dynamic catalog workflow',
            'steps': [
              {'kind': entry[3], 'order': 0}
            ],
          }),
      ];

  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        for (final id in ['chat', 'direct'])
          AxWorkRequest(
            id: '$id-result',
            requestedByName: 'Owner',
            requestedByUserId: 'user-owner',
            prompt: '**Question**',
            workflowId: id,
            workflowVersion: id == 'chat' ? 1 : 2,
            status: 'completed',
            createdAt: '2026-10-06T00:00:00Z',
            steps: const [],
            finalText: id == 'chat' ? '**Chat answer**' : '**Work answer**',
          ),
      ];

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage(
      {required String threadId,
      required String text,
      List<String> references = const [],
      String? idempotencyKey}) {
    discussionWrites++;
    return super.sendDiscussionMessage(
        threadId: threadId, text: text, references: references);
  }
}

class _SnapshotHistoryDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        for (final entry in [
          ['direct', 1, 'Direct'],
          ['direct', 2, 'Work'],
          ['chat', 1, 'Chat']
        ])
          AxWorkRequest.fromJson({
            'id': '${entry[0]}-${entry[1]}',
            'workflowId': entry[0],
            'workflowVersion': entry[1],
            'workflowName': entry[2],
            'status': 'completed',
            'createdAt': '2026-10-06T00:00:00Z',
            'prompt': 'History request',
            'finalText': 'History answer',
          }),
      ];
}

class _SpaceStreamsSource extends AxFixtureDataSource {
  _SpaceStreamsSource(this.streams);
  final List<AxThread> streams;
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async =>
      streams;
}

class _PolicyWorkflowDataSource extends _ModelSelectionTestDataSource {
  _PolicyWorkflowDataSource(
      {required this.model, required this.effort, required this.binding});
  final bool model;
  final bool effort;
  final bool binding;

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'policy-fixture',
          'version': 1,
          'name': 'Policy fixture',
          'description': '',
          'steps': [
            {'kind': 'implement', 'order': 0}
          ],
          'executionPolicy': {
            'userSelectsWorker': true,
            'userSelectsModel': model,
            'userSelectsEffort': effort,
            'multiStep': !binding
          },
          'composerBindingId': binding ? 'policy-binding' : null,
        })
      ];
}

class _ModelSelectionTestDataSource extends _GenericWorkerConfigDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Implement the requested work.',
          'steps': [
            {'kind': 'implement', 'order': 0},
          ],
        }),
        AxBuiltinWorkflow.fromJson({
          'id': 'research',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'research',
          'version': 1,
          'name': 'Research',
          'description': 'Investigate and research codebase.',
          'steps': [
            {'kind': 'research', 'order': 0},
          ],
        }),
      ];

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [
        AxWorker(
          id: 'w-chatgpt',
          workspaceId: 'workspace-1',
          workspaceName: 'MacBook Pro',
          workerTypeId: 'chatgpt',
          displayName: 'ChatGPT',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
          modelOptions: {
            'catalog': [
              {
                'id': 'gpt-4o',
                'name': 'GPT-4o',
                'supportedReasoningEfforts': []
              },
              {
                'id': 'o3',
                'name': 'o3',
                'supportedReasoningEfforts': ['low', 'high']
              },
            ]
          },
        ),
      ];
}

class _MembersTabTestDataSource extends AxFixtureDataSource {
  _MembersTabTestDataSource({
    required this.members,
    required this.invitations,
  });

  final List<AxSpaceMember> members;
  final List<AxSpaceInvitation> invitations;
  int resendCount = 0;
  int revokeCount = 0;

  @override
  Future<List<AxSpaceMember>> loadSpaceMembers({
    required String spaceId,
  }) async =>
      members;

  @override
  Future<List<AxSpaceInvitation>> loadSpaceInvitations({
    required String spaceId,
  }) async =>
      invitations;

  @override
  Future<void> expireSpaceInvitation({
    required String spaceId,
    required String invitationId,
  }) async {
    revokeCount++;
  }

  @override
  Future<AxSpaceInvitation> inviteSpaceMemberWithPermissions({
    required String spaceId,
    required String email,
    required String role,
    required AxSpacePermissions permissions,
  }) async {
    resendCount++;
    return AxSpaceInvitation(
      id: 'pinv-new',
      spaceId: spaceId,
      email: email,
      role: role,
      status: 'pending',
      createdAt: DateTime.now().toIso8601String(),
    );
  }
}

class _SimpleConversationDataSource extends _WorkHistoryDataSource {
  _SimpleConversationDataSource(this.request) : super([request]);
  final AxWorkRequest request;
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() =>
      _CurrentWorkflowUiDataSource().loadBuiltinWorkflowCatalog();
  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
          {required String workRequestId}) async =>
      AxWorkRequestStatus(
          id: request.id,
          conversationId: request.conversationId,
          workflowRun: request.workflowRun,
          turns: request.turns,
          status: request.status,
          originalRequest: request.prompt,
          workflowId: request.workflowId,
          workflowVersion: request.workflowVersion,
          steps: request.steps,
          requestedByName: request.requestedByName);
}

class _ContinuityFailureDataSource extends _WorkHistoryDataSource {
  _ContinuityFailureDataSource(this.request, this.step) : super([request]);
  final AxWorkRequest request;
  final AxWorkRequestStep step;
  @override
  Future<AxWorkRequestStatus> loadWorkRequest(
          {required String workRequestId}) async =>
      AxWorkRequestStatus(
          id: workRequestId,
          status: 'failed',
          errorCode: step.errorCode,
          errorMessage: step.errorMessage,
          steps: [step]);
}

AxWorkRequest _workRequest(String id, String prompt,
        {String status = 'completed'}) =>
    AxWorkRequest(
      id: id,
      requestedByName: 'Owner',
      requestedByUserId: 'user-owner',
      prompt: prompt,
      workflowId: 'direct',
      workflowVersion: 1,
      status: status,
      createdAt: '2026-10-01T10:00:00.000Z',
      steps: const [],
    );

void _noop() {}

/// Restricts [finder] to the read-only AI History panel; the conversation
/// shows the same Work Requests as compact messages.
Finder _inAiHistory(Finder finder) => find.descendant(
    of: find.byKey(const ValueKey('thread-AI History-pane')), matching: finder);

/// Restricts [finder] to the Conversation timeline.
Finder _inConversation(Finder finder) => find.descendant(
    of: find.byKey(const ValueKey('chat-history-scroll')), matching: finder);

/// Opens the read-only AI History panel.
Future<void> _openAiHistory(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
  await tester.pumpAndSettle();
}

/// Switches the conversation composer to Ask AI (the Work composer).
Future<void> _askAi(WidgetTester tester) async {
  // A narrow Thread shows AI History instead of the conversation.
  if (find.byKey(const ValueKey('composer-mode-ai')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('ai-history-conversation')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('composer-mode-ai')));
  await tester.pumpAndSettle();
}

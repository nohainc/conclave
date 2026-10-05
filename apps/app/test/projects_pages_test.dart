import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

import 'ax_fixture_data.dart';

void main() {
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
        'Cannot run Direct\n• The Project Workspace grant does not allow the access this Step needs.';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: WorkstreamPage(
        project: const AxProject(
            id: 'project-1',
            name: 'Project',
            branch: '',
            lastActivity: '',
            role: 'owner'),
        workstream: const AxWorkstream(
            id: 'workstream-1',
            projectId: 'project-1',
            name: 'Chat',
            lead: 'Owner',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: 'idle',
            canExecuteWork: true),
        dataSource: _WorkFormDataSource(),
        onBackToProject: _noop,
        onArchive: _noop,
        onRunWork: (_, __, ___) async => throw const AxApiException(message),
        initialTab: 1,
      ),
    ))));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).first, 'Implement the change');
    await tester.ensureVisible(find.text('Run'));
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Copy Run error'));
    await tester.tap(find.byTooltip('Copy Run error'));
    await tester.pumpAndSettle();
    expect(copied, message);
  });
  testWidgets(
      'Project page exposes editable header, Archive/Delete, and 3 tabs',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: const AxProject(
              id: 'project-1',
              name: 'Project One',
              description: 'Shared space for Project One',
              instructions: 'Follow standard engineering practices.',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify Header items
    expect(find.text('Project One'), findsOneWidget);
    expect(find.text('Shared space for Project One'), findsOneWidget);
    expect(find.text('Follow standard engineering practices.'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNWidgets(3));
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    // Verify 3 Tabs
    expect(find.text('Workstreams'), findsOneWidget);
    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Members'), findsOneWidget);

    // Verify Workstreams Tab contents
    expect(find.text('Each Workstream is one focused area of team work.'),
        findsOneWidget);
    expect(find.byTooltip('Create Workstream'), findsOneWidget);

    // Switch to Workspaces Tab
    await tester.tap(find.text('Workspaces'));
    await tester.pumpAndSettle();
    expect(find.text('Workspaces provide execution capacity for your project.'),
        findsOneWidget);
    expect(find.byTooltip('Connect Workspace'), findsOneWidget);

    // Switch to Members Tab
    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();
    expect(
        find.text('Project roles control collaboration across team members.'),
        findsOneWidget);
    expect(find.byTooltip('Share Project'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Project page updates description when switching projects',
      (tester) async {
    const p1 = AxProject(
      id: 'project-1',
      name: 'Project One',
      description: 'First project description',
      branch: '',
      lastActivity: 'today',
    );
    const p2 = AxProject(
      id: 'project-2',
      name: 'Project Two',
      description: 'Second project description',
      branch: '',
      lastActivity: 'today',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: p1,
            dataSource: const AxFixtureDataSource(),
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First project description'), findsOneWidget);
    expect(find.text('Second project description'), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: p2,
            dataSource: const AxFixtureDataSource(),
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('First project description'), findsNothing);
    expect(find.text('Second project description'), findsOneWidget);
  });

  testWidgets(
      'Workstream shell exposes Chat and Work with viewer-safe controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: AxProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              lastActivity: 'today',
              role: 'viewer',
            ),
            workstream: AxWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Not selected',
              queueStatus: 'Idle',
            ),
            onBackToProject: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);
    expect(find.text('What should Conclave do?'), findsOneWidget);
    expect(
        find.text(
            'Ask AI to do something for the team. Nothing runs until you press Run.'),
        findsOneWidget);
    expect(find.textContaining('lease'), findsNothing);
    expect(find.textContaining('fencing'), findsNothing);
    expect(find.textContaining('Durable Object'), findsNothing);
    expect(find.textContaining('checkout key'), findsNothing);
    expect(
        find.text('Viewer access can read the workstream but cannot run Work.'),
        findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
  });

  testWidgets('collaborator can explicitly run Work', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    String? submittedWork;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: const AxProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            workstream: const AxWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
              canExecuteWork: true,
            ),
            dataSource: _WorkFormDataSource(),
            onBackToProject: _noop,
            onArchive: _noop,
            onRunWork: (work, workflowId, attachments) async {
              submittedWork = work;
              return 'request-1';
            },
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('What should Conclave do?'), findsOneWidget);
    expect(find.text('Workflow'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField).first, 'Add the missing tests');
    await tester.ensureVisible(find.text('Run'));
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(submittedWork, 'Add the missing tests');
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Workstream selects a Worker unknown to AX by Cloud name and local ID',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    final dataSource = _GenericWorkerConfigDataSource();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: const AxProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            workstream: const AxWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Not selected',
              queueStatus: 'Idle',
              canConfigureWork: true,
            ),
            dataSource: dataSource,
            onBackToProject: _noop,
            onArchive: _noop,
            initialTab: 2,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final selectors = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    expect(selectors, findsNWidgets(7));
    await tester
        .tap(selectors.at(4)); // Workflow, then Direct/Research/Plan/Implement
    await tester.pumpAndSettle();
    expect(find.text('Dynamic Test Worker · Vitalii’s MacBook Pro'),
        findsOneWidget);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('Antigravity'), findsNothing);
    await tester
        .tap(find.text('Dynamic Test Worker · Vitalii’s MacBook Pro').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save Work settings'));
    await tester.tap(find.text('Save Work settings'));
    await tester.pumpAndSettle();

    expect(
      dataSource.savedWorkConfig?['bindings']['implement']['workerId'],
      'local-worker-dynamic-test',
    );
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('retired dynamic Worker bindings remain explicit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    final dataSource = _RetiredWorkerConfigDataSource();
    const staleConfig = {
      'defaultWorkflowId': 'direct',
      'bindings': {
        'implement': {
          'workerId': 'local-worker-dynamic-test',
          'workerLabel': {
            'displayName': 'Dynamic Test Worker',
            'workspaceName': 'Vitalii’s MacBook Pro',
          },
          'fallbackWorkerId': 'retired-fallback',
          'fallbackWorkerLabel': {
            'displayName': 'Gemini',
            'workspaceName': 'Linux workstation',
          },
        },
      },
    };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: const AxProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            workstream: const AxWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: '',
              primaryWorkspace: 'Not selected',
              queueStatus: 'Idle',
              canConfigureWork: true,
              workConfig: staleConfig,
            ),
            dataSource: dataSource,
            onBackToProject: _noop,
            onArchive: _noop,
            initialTab: 2,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Worker unavailable'), findsOneWidget);
    expect(
      find.text('Previously: Dynamic Test Worker — Vitalii’s MacBook Pro'),
      findsOneWidget,
    );
    expect(find.text('Select Worker'), findsNWidgets(2));
    expect(
        find.text('Dynamic Test Worker · Vitalii’s MacBook Pro'), findsNothing);

    await tester.ensureVisible(find.text('Save Work settings'));
    await tester.tap(find.text('Save Work settings'));
    await tester.pumpAndSettle();
    expect(
      dataSource.savedWorkConfig?['bindings']['implement']['workerId'],
      'local-worker-dynamic-test',
    );
    expect(
      dataSource.savedWorkConfig?['bindings']['implement']['fallbackWorkerId'],
      'retired-fallback',
    );

    await tester.ensureVisible(find.text('Advanced'));
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Step settings'));
    final configureButtons = find.widgetWithText(TextButton, 'Configure');
    await tester.tap(configureButtons.at(3));
    await tester.pumpAndSettle();
    expect(
      find.text(
          'Fallback Worker unavailable. Previously: Gemini — Linux workstation'),
      findsOneWidget,
    );
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.tap(configureButtons.at(3));
    await tester.pumpAndSettle();
    expect(
      find.text(
          'Fallback Worker unavailable. Previously: Gemini — Linux workstation'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Work history reloads from Cloud after a realtime reconnect gap',
      (tester) async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final dataSource = _WorkHistoryDataSource([
      _workRequest('request-1', 'History before reconnect', status: 'running'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: const AxProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            workstream: const AxWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
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
            onBackToProject: _noop,
            onArchive: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
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
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('The requested change is complete.'), findsOneWidget);
    expect(find.text('Implement'), findsNothing);
    expect(find.text('Conclave'), findsOneWidget);
    expect(find.byTooltip('View run details'), findsOneWidget);

    dataSource.requests = [
      _workRequest('request-1', 'History restored after reconnect'),
      _workRequest('request-2', 'Run submitted while the browser was away'),
    ];
    events.add({'type': 'reconnect.required'});
    await tester.pump();
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
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: AxProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            workstream: AxWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
            ),
            onBackToProject: _noop,
            onArchive: _noop,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last,
        'The login failure reproduces on a fresh checkout.');
    await tester.scrollUntilVisible(find.byTooltip('Send message'), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('The login failure reproduces on a fresh checkout.'),
        findsOneWidget);
    expect(find.text('You'), findsNothing);

    // Verify copy message button exists and triggers
    expect(find.byTooltip('Copy message'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy message'));
    await tester.pumpAndSettle();
    expect(find.text('Message copied to clipboard'), findsOneWidget);

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

    // Test sending another message via Enter key (appears at the bottom)
    await tester.enterText(
        find.byType(TextField).last, 'Line 1\nLine 2 details');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Line 1\nLine 2 details'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Chat messages show their calendar date', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorkstreamPage(
          project: const AxProject(
            id: 'project-1',
            name: 'Project One',
            branch: '',
            lastActivity: 'today',
            role: 'collaborator',
          ),
          workstream: const AxWorkstream(
            id: 'workstream-1',
            projectId: 'project-1',
            name: 'Research',
            lead: 'Owner',
            status: 'active',
            brief: 'Understand the problem.',
            primaryWorkspace: 'Workspace One',
            queueStatus: 'Idle',
          ),
          dataSource: _DiscussionDataSource(),
          currentUserId: 'user-owner',
          onBackToProject: _noop,
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
  });

  testWidgets(
      'WorkstreamPage loads and persists discussions via dataSource and updates when switching workstreams',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    const dataSource = AxFixtureDataSource();
    const project = AxProject(
      id: 'project-1',
      name: 'Project One',
      branch: '',
      lastActivity: 'today',
      role: 'collaborator',
    );
    const ws1 = AxWorkstream(
      id: 'ws-1',
      projectId: 'project-1',
      name: 'Alpha Workstream',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Workspace One',
      queueStatus: 'Idle',
    );
    const ws2 = AxWorkstream(
      id: 'ws-2',
      projectId: 'project-1',
      name: 'Beta Workstream',
      lead: 'Owner',
      status: 'active',
      brief: '',
      primaryWorkspace: 'Workspace One',
      queueStatus: 'Idle',
    );

    var activeWorkstream = ws1;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => WorkstreamPage(
            key: ValueKey(activeWorkstream.id),
            project: project,
            workstream: activeWorkstream,
            dataSource: dataSource,
            currentUserId: 'user-owner',
            onBackToProject: _noop,
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
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('Message for Alpha'), findsOneWidget);

    // Switch to ws2
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            activeWorkstream = ws2;
            return WorkstreamPage(
              key: ValueKey(activeWorkstream.id),
              project: project,
              workstream: activeWorkstream,
              dataSource: dataSource,
              currentUserId: 'user-owner',
              onBackToProject: _noop,
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

  testWidgets(
      'Workstream rename keeps its position and Move Up/Down reorders correctly',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    const ws1 = AxWorkstream(
      id: 'ws-1',
      projectId: 'p-1',
      name: 'Alpha Workstream',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
    );
    const ws2 = AxWorkstream(
      id: 'ws-2',
      projectId: 'p-1',
      name: 'Beta Workstream',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
    );
    const ws3 = AxWorkstream(
      id: 'ws-3',
      projectId: 'p-1',
      name: 'Gamma Workstream',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      queueStatus: 'Idle',
    );

    const project = AxProject(
      id: 'p-1',
      name: 'Test Project',
      branch: 'main',
      lastActivity: 'today',
      workstreams: [ws1, ws2, ws3],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: project,
            dataSource: const AxFixtureDataSource(),
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Verify initial ordering: Alpha (0), Beta (1), Gamma (2)
    final listTiles = find.byType(ListTile);
    expect(listTiles, findsNWidgets(3));

    // Verify Move up and Move down icons
    expect(find.byTooltip('Move up'), findsNWidgets(3));
    expect(find.byTooltip('Move down'), findsNWidgets(3));

    // Move Beta (index 1) down -> should become index 2 (Alpha, Gamma, Beta)
    await tester.tap(find.byTooltip('Move down').at(1));
    await tester.pumpAndSettle();

    // Verify order after moving Beta down
    final tilesAfterDown =
        tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tilesAfterDown[0].title as Text).data, 'Alpha Workstream');
    expect((tilesAfterDown[1].title as Text).data, 'Gamma Workstream');
    expect((tilesAfterDown[2].title as Text).data, 'Beta Workstream');

    // Move Gamma (now index 1) up -> should become index 0 (Gamma, Alpha, Beta)
    await tester.tap(find.byTooltip('Move up').at(1));
    await tester.pumpAndSettle();

    final tilesAfterUp =
        tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tilesAfterUp[0].title as Text).data, 'Gamma Workstream');
    expect((tilesAfterUp[1].title as Text).data, 'Alpha Workstream');
    expect((tilesAfterUp[2].title as Text).data, 'Beta Workstream');

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Workspaces tab renders workspace items and invokes onOpenWorkspace',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    String? openedWorkspaceId;

    final customDataSource = _WorkspaceTestDataSource();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: const AxProject(
              id: 'p-1',
              name: 'Test Project',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: customDataSource,
            onOpenWorkstream: (_) {},
            onOpenWorkspace: (id) => openedWorkspaceId = id,
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Switch to Workspaces Tab
    await tester.tap(find.text('Workspaces'));
    await tester.pumpAndSettle();

    // Check workspace title displayed cleanly without icons or status chips
    expect(find.text('Production Workspace'), findsOneWidget);
    expect(find.byIcon(Icons.computer_outlined), findsNothing);

    // Tap on workspace
    await tester.tap(find.text('Production Workspace'));
    await tester.pumpAndSettle();

    expect(openedWorkspaceId, 'ws-prod');

    await tester.tap(find.byTooltip('Edit Workspace access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read repository files'));
    await tester.tap(find.text('Change repository files'));
    await tester.tap(find.text('Confirm access'));
    await tester.pumpAndSettle();
    expect(customDataSource.savedPermissions,
        ['repository:read', 'repository:write']);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Project instructions can be edited and saved without error',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    AxProject? updatedProject;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: const AxProject(
              id: 'p-1',
              name: 'Test Project',
              description: 'Initial description',
              instructions: 'Initial instructions',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: const AxFixtureDataSource(),
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
            onProjectUpdated: (p) => updatedProject = p,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Initial instructions'), findsOneWidget);

    // Tap edit button for instructions (the 3rd edit icon in header)
    final editIcons = find.byIcon(Icons.edit_outlined);
    expect(editIcons, findsNWidgets(3));
    await tester.tap(editIcons.at(2));
    await tester.pumpAndSettle();

    // Enter new instructions
    final textField = find.byType(TextField);
    expect(textField, findsOneWidget);
    await tester.enterText(textField, 'Updated engineering guidelines');

    // Click Save (green check icon)
    final saveButton = find.byIcon(Icons.check);
    expect(saveButton, findsOneWidget);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // Verify update occurred and no LateInitializationError was thrown
    expect(find.text('Project updated.'), findsOneWidget);
    expect(updatedProject, isNotNull);
    expect(updatedProject!.instructions, 'Updated engineering guidelines');

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Creating workstream with duplicate name shows warning and stays on dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var createdCount = 0;

    final customDataSource = _DuplicateTestDataSource(
      onCreateWorkstream: () => createdCount++,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: const AxProject(
              id: 'p-1',
              name: 'Test Project',
              branch: 'main',
              lastActivity: 'today',
              workstreams: [
                AxWorkstream(
                  id: 'ws-1',
                  projectId: 'p-1',
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
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Tap create workstream button
    await tester.tap(find.byTooltip('Create Workstream'));
    await tester.pumpAndSettle();

    expect(
        find.text('Create Workstream'), findsNWidgets(2)); // Title and Button

    // Enter existing name (case-insensitive)
    await tester.enterText(find.byType(TextField).first, 'frontend design');
    await tester.tap(find.widgetWithText(FilledButton, 'Create Workstream'));
    await tester.pumpAndSettle();

    // Verify warning is displayed and dialog is still visible
    expect(find.text('A workstream with this name already exists.'),
        findsOneWidget);
    expect(find.text('Create Workstream'), findsNWidgets(2));
    expect(createdCount, 0);

    // Cancel dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Connecting duplicate workspace shows warning and stays on dialog',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    var requestedCount = 0;

    final customDataSource = _DuplicateTestDataSource(
      onRequestWorkspace: () => requestedCount++,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: const AxProject(
              id: 'p-1',
              name: 'Test Project',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: customDataSource,
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Switch to Workspaces Tab
    await tester.tap(find.text('Workspaces'));
    await tester.pumpAndSettle();

    // Tap Connect Workspace button
    await tester.tap(find.byTooltip('Connect Workspace'));
    await tester.pumpAndSettle();

    expect(find.text('Connect Workspace'), findsOneWidget); // Dialog title

    // Attempt to connect already connected workspace
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    // Verify warning is displayed and dialog is still visible
    expect(find.text('This Workspace is already connected to this Project.'),
        findsOneWidget);
    expect(find.text('Connect Workspace'), findsOneWidget);
    expect(requestedCount, 0);

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
          child: ProjectPage(
            project: const AxProject(
              id: 'p-1',
              name: 'Test Project',
              branch: 'main',
              lastActivity: 'today',
            ),
            dataSource: customDataSource,
            onOpenWorkstream: (_) {},
            onEdit: () {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Switch to Members Tab
    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();

    // Tap Share Project button
    await tester.tap(find.byTooltip('Share Project'));
    await tester.pumpAndSettle();

    expect(find.text('Share Project'), findsOneWidget); // Dialog title

    // Enter existing member email
    await tester.enterText(find.byType(TextField).first, 'alice@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Send invitation'));
    await tester.pumpAndSettle();

    // Verify warning is displayed and dialog is still visible
    expect(find.text('This user is already a member of the Project.'),
        findsOneWidget);
    expect(find.text('Share Project'), findsOneWidget);
    expect(inviteCount, 0);

    // Cancel dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.binding.setSurfaceSize(null);
  });
}

class _WorkspaceTestDataSource extends AxFixtureDataSource {
  List<String>? savedPermissions;
  @override
  Future<void> updateWorkspaceProjectPermissions({
    required String grantId,
    required List<String> allowedPermissions,
  }) async {
    savedPermissions = allowedPermissions;
  }

  @override
  Future<List<Map<String, dynamic>>> loadProjectWorkspaces({
    required String projectId,
  }) async =>
      [
        {
          'id': 'grant-1',
          'workspaceId': 'ws-prod',
          'workspaceName': 'Production Workspace',
        }
      ];
}

class _DuplicateTestDataSource extends AxFixtureDataSource {
  _DuplicateTestDataSource({
    this.onCreateWorkstream,
    this.onRequestWorkspace,
    this.onInviteMember,
  });

  final VoidCallback? onCreateWorkstream;
  final VoidCallback? onRequestWorkspace;
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
  Future<List<Map<String, dynamic>>> loadProjectWorkspaces({
    required String projectId,
  }) async =>
      [
        {
          'id': 'grant-1',
          'workspaceId': 'ws-1',
          'workspaceName': 'MacBook Pro',
        }
      ];

  @override
  Future<List<AxProjectMember>> loadProjectMembers({
    required String projectId,
  }) async =>
      const [
        AxProjectMember(
          userId: 'u-alice',
          email: 'alice@example.com',
          displayName: 'Alice',
          role: 'collaborator',
          createdAt: '2026-01-01',
        ),
      ];

  @override
  Future<AxWorkstream> createWorkstream({
    required String projectId,
    required String name,
    String? brief,
    String? lead,
    String? primaryWorkspace,
  }) async {
    onCreateWorkstream?.call();
    return AxWorkstream(
      id: 'ws-new',
      projectId: projectId,
      name: name,
      lead: lead ?? 'Owner',
      status: 'active',
      brief: brief ?? '',
      primaryWorkspace: primaryWorkspace ?? '',
      queueStatus: 'idle',
    );
  }

  @override
  Future<void> requestProjectWorkspace({
    required String projectId,
    required String workspaceId,
    List<String> allowedPermissions = const [],
  }) async {
    onRequestWorkspace?.call();
  }

  @override
  Future<void> inviteProjectMember({
    required String projectId,
    required String email,
    required String role,
  }) async {
    onInviteMember?.call();
  }
}

class _WorkHistoryDataSource extends AxFixtureDataSource {
  _WorkHistoryDataSource(this.requests);

  List<AxWorkRequest> requests;
  final List<bool> activeOnlyCalls = [];

  @override
  Future<List<AxWorkRequest>> loadWorkstreamWorkRequests({
    required String workstreamId,
    bool activeOnly = false,
  }) async {
    activeOnlyCalls.add(activeOnly);
    return requests;
  }
}

class _DiscussionDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxDiscussionMessage>> loadDiscussionMessages({
    required String workstreamId,
  }) async =>
      [
        const AxDiscussionMessage(
          id: 'message-1',
          workstreamId: 'workstream-1',
          authorUserId: 'user-owner',
          authorName: 'Vitalii',
          body: 'A dated message',
          createdAt: '2026-10-05T19:18:00.000Z',
          isMe: true,
        ),
      ];
}

class _WorkFormDataSource extends AxFixtureDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'version': 1,
          'name': 'Direct',
          'description': 'Complete a request directly.',
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
          capabilities: [],
        ),
      ];

  @override
  Future<List<Map<String, dynamic>>> loadProjectWorkspaces({
    required String projectId,
  }) async =>
      [
        {'workspaceId': 'workspace-1', 'workspaceName': 'Ignored grant label'},
      ];

  @override
  Future<AxWorkstream> updateWorkstream({
    required String workstreamId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
  }) async {
    savedWorkConfig = workConfig;
    return AxWorkstream(
      id: workstreamId,
      projectId: 'project-1',
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

class _RetiredWorkerConfigDataSource extends _GenericWorkerConfigDataSource {
  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => [
        const AxWorker(
          id: 'local-worker-dynamic-test',
          workspaceId: 'workspace-retired-1',
          workspaceName: 'Vitalii’s MacBook Pro',
          workerTypeId: 'dynamic-test-worker',
          displayName: 'Dynamic Test Worker',
          catalogLifecycleState: 'retired',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
          capabilities: [],
        ),
        const AxWorker(
          id: 'retired-fallback',
          workspaceId: 'workspace-retired-2',
          workspaceName: 'Linux workstation',
          workerTypeId: 'gemini',
          displayName: 'Gemini',
          catalogLifecycleState: 'retired',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
          capabilities: [],
        ),
      ];
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

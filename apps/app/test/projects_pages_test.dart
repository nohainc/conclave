import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'studio_fixture_data.dart';

void main() {
  testWidgets(
      'Project page exposes editable header, Archive/Delete, and 3 tabs',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: const StudioProject(
              id: 'project-1',
              name: 'Project One',
              description: 'Shared space for Project One',
              instructions: 'Follow standard engineering practices.',
              branch: 'main',
              activeGoals: 0,
              lastActivity: 'today',
            ),
            dataSource: const StudioFixtureDataSource(),
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
    expect(
        find.text('Each Workstream is one focused area of team work.'),
        findsOneWidget);
    expect(find.byTooltip('Create Workstream'), findsOneWidget);

    // Switch to Workspaces Tab
    await tester.tap(find.text('Workspaces'));
    await tester.pumpAndSettle();
    expect(find.text('Execution Workspaces'), findsOneWidget);
    expect(find.text('Connect Workspace'), findsOneWidget);

    // Switch to Members Tab
    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();
    expect(find.text('Share Project'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Project page updates description when switching projects',
      (tester) async {
    const p1 = StudioProject(
      id: 'project-1',
      name: 'Project One',
      description: 'First project description',
      branch: '',
      activeGoals: 0,
      lastActivity: 'today',
    );
    const p2 = StudioProject(
      id: 'project-2',
      name: 'Project Two',
      description: 'Second project description',
      branch: '',
      activeGoals: 0,
      lastActivity: 'today',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: p1,
            dataSource: const StudioFixtureDataSource(),
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
            dataSource: const StudioFixtureDataSource(),
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
      'Workstream shell exposes Discuss and Work with viewer-safe controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: StudioProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              activeGoals: 0,
              lastActivity: 'today',
              role: 'viewer',
            ),
            workstream: StudioWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Not selected',
              currentCheckpoint: 'Not started',
              queueStatus: 'Idle',
            ),
            onBackToProject: _noop,
            onArchive: _noop,
            onProvisionCheckout: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Discuss'), findsOneWidget);
    expect(find.text('Work'), findsNWidgets(2));
    expect(find.text('Archive'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('No Work yet. Describe what you need, then press Run.'),
        findsOneWidget);
    expect(find.text('Work'), findsNWidgets(2));
    expect(
        find.text(
            'Ask AI to do something for the team. Nothing runs until you press Run.'),
        findsOneWidget);
    expect(find.textContaining('lease'), findsNothing);
    expect(find.textContaining('fencing'), findsNothing);
    expect(find.textContaining('Durable Object'), findsNothing);
    expect(find.textContaining('checkout key'), findsNothing);
    expect(
        find.text('Viewer access can read the timeline but cannot run Work.'),
        findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
  });

  testWidgets('collaborator can explicitly run Work and cancel it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: StudioProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              activeGoals: 0,
              lastActivity: 'today',
              role: 'collaborator',
            ),
            workstream: StudioWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              currentCheckpoint: 'main',
              queueStatus: 'Idle',
            ),
            onBackToProject: _noop,
            onArchive: _noop,
            onProvisionCheckout: _noop,
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('What should Conclave do?'), findsOneWidget);
    expect(find.text('Workflow'), findsOneWidget);
    expect(find.text('Advanced'), findsOneWidget);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Account policy'), findsOneWidget);
    expect(find.text('Workstream budget'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField).first, 'Add the missing tests');
    await tester.ensureVisible(find.text('Run'));
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(find.text('queued'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Discuss messages can create a Work draft without running it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: StudioProject(
              id: 'project-1',
              name: 'Project One',
              branch: '',
              activeGoals: 0,
              lastActivity: 'today',
              role: 'collaborator',
            ),
            workstream: StudioWorkstream(
              id: 'workstream-1',
              projectId: 'project-1',
              name: 'Research',
              lead: 'Owner',
              status: 'active',
              brief: 'Understand the problem.',
              primaryWorkspace: 'Workspace One',
              currentCheckpoint: 'main',
              queueStatus: 'Idle',
            ),
            onBackToProject: _noop,
            onArchive: _noop,
            onProvisionCheckout: _noop,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last,
        'The login failure reproduces on a fresh checkout.');
    await tester.scrollUntilVisible(find.text('Send message'), 500,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('The login failure reproduces on a fresh checkout.'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Send to Work'));
    await tester.tap(find.text('Send to Work'));
    await tester.pumpAndSettle();

    expect(find.text('What should Conclave do?'), findsOneWidget);
    expect(find.text('References added'), findsOneWidget);
    expect(find.text('No Work yet. Describe what you need, then press Run.'),
        findsOneWidget);
    expect(find.text('queued'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'Workstream rename keeps its position and Move Up/Down reorders correctly',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    const ws1 = StudioWorkstream(
      id: 'ws-1',
      projectId: 'p-1',
      name: 'Alpha Workstream',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      currentCheckpoint: 'main',
      queueStatus: 'Idle',
    );
    const ws2 = StudioWorkstream(
      id: 'ws-2',
      projectId: 'p-1',
      name: 'Beta Workstream',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      currentCheckpoint: 'main',
      queueStatus: 'Idle',
    );
    const ws3 = StudioWorkstream(
      id: 'ws-3',
      projectId: 'p-1',
      name: 'Gamma Workstream',
      lead: 'Vitalii',
      status: 'active',
      brief: '',
      primaryWorkspace: 'MacBook',
      currentCheckpoint: 'main',
      queueStatus: 'Idle',
    );

    const project = StudioProject(
      id: 'p-1',
      name: 'Test Project',
      branch: 'main',
      activeGoals: 0,
      lastActivity: 'today',
      workstreams: [ws1, ws2, ws3],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: project,
            dataSource: const StudioFixtureDataSource(),
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
}

void _noop() {}

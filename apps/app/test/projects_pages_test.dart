import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'studio_fixture_data.dart';

void main() {
  testWidgets('Project page exposes Workstreams and collaboration areas',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectPage(
            project: const StudioProject(
              id: 'project-1',
              name: 'Project One',
              description: 'Shared space for Project One',
              repository: '',
              branch: '',
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

    expect(find.text('Share Project'), findsOneWidget);
    expect(find.text('Shared space for Project One'), findsOneWidget);
    expect(find.text('Project One'), findsNothing);
    for (final label in [
      'Runs',
      'Artifacts',
      'Members',
      'Execution',
      'Settings',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Workstreams'), findsWidgets);
    expect(find.text('Overview'), findsNothing);

    expect(find.text('Members'), findsOneWidget);
    expect(find.text('No Workstreams yet. Create the first one below.'),
        findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Project page updates workstreams when switching projects',
      (tester) async {
    const p1 = StudioProject(
      id: 'project-1',
      name: 'Project One',
      repository: '',
      branch: '',
      activeGoals: 0,
      lastActivity: 'today',
      workstreams: [
        StudioWorkstream(
          id: 'ws-1',
          projectId: 'project-1',
          name: 'P1 Workstream',
          lead: 'Owner',
          status: 'active',
          brief: 'Brief 1',
          primaryWorkspace: 'Workspace 1',
          currentCheckpoint: 'main',
          queueStatus: 'Idle',
        ),
      ],
    );
    const p2 = StudioProject(
      id: 'project-2',
      name: 'Project Two',
      repository: '',
      branch: '',
      activeGoals: 0,
      lastActivity: 'today',
      workstreams: [
        StudioWorkstream(
          id: 'ws-2',
          projectId: 'project-2',
          name: 'P2 Workstream',
          lead: 'Owner',
          status: 'active',
          brief: 'Brief 2',
          primaryWorkspace: 'Workspace 2',
          currentCheckpoint: 'main',
          queueStatus: 'Idle',
        ),
      ],
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
    expect(find.text('P1 Workstream'), findsOneWidget);
    expect(find.text('P2 Workstream'), findsNothing);

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
    expect(find.text('P1 Workstream'), findsNothing);
    expect(find.text('P2 Workstream'), findsOneWidget);
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
              repository: '',
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
        findsNWidgets(2));
    expect(find.text('Work'), findsNWidgets(2));
    expect(find.text('Ask AI to do something for the team. Nothing runs until you press Run.'), findsOneWidget);
    expect(find.textContaining('lease'), findsNothing);
    expect(find.textContaining('fencing'), findsNothing);
    expect(find.textContaining('Durable Object'), findsNothing);
    expect(find.textContaining('checkout key'), findsNothing);
    expect(
        find.text('Viewer access can read the timeline but cannot run Work.'),
        findsNWidgets(2));
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
              repository: '',
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
    await tester.enterText(find.byType(TextField).first, 'Add the missing tests');
    await tester.ensureVisible(find.text('Run'));
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(find.text('Latest Work: queued'), findsOneWidget);
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
              repository: '',
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
        findsNWidgets(2));
    expect(find.text('queued'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });
}

void _noop() {}

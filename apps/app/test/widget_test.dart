import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'studio_fixture_data.dart';

void main() {
  const project = StudioProject(
    id: 'project-1',
    name: 'Authentication',
    branch: 'main',
    activeGoals: 0,
    lastActivity: 'today',
    role: 'collaborator',
  );
  const workstream = StudioWorkstream(
    id: 'workstream-1',
    projectId: 'project-1',
    name: 'Login reliability',
    lead: 'Owner',
    status: 'active',
    brief: 'Make login reliable.',
    primaryWorkspace: 'Mac Workspace',
    currentCheckpoint: 'Not started',
    queueStatus: 'Idle',
  );

  testWidgets('V6 Project explains team collaboration and Workstreams',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
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

    expect(find.text('Authentication'), findsOneWidget);
    expect(find.text('Workstreams'), findsOneWidget);
    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Members'), findsOneWidget);
    expect(
        find.text('Each Workstream is one focused area of team work.'),
        findsOneWidget);
    expect(find.byTooltip('Create Workstream'), findsOneWidget);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Runs'), findsNothing);
    expect(find.text('Artifacts'), findsNothing);
    expect(find.text('Execution'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('V6 normal Workstream UI uses product vocabulary',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkstreamPage(
            project: project,
            workstream: workstream,
            onBackToProject: () {},
            onArchive: () {},
            onProvisionCheckout: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Discuss'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('No discussion messages yet'), findsOneWidget);
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(find.text('No Work yet. Describe what you need, then press Run.'),
        findsOneWidget);
    expect(find.text('lease'), findsNothing);
    expect(find.text('fencing token'), findsNothing);
    expect(find.text('Durable Object'), findsNothing);
    expect(find.text('checkout key'), findsNothing);
  });
}

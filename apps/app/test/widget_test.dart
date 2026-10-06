import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

import 'ax_fixture_data.dart';

void main() {
  const project = AxProject(
    id: 'project-1',
    name: 'Authentication',
    branch: 'main',
    lastActivity: 'today',
    role: 'collaborator',
  );
  const workstream = AxWorkstream(
    id: 'workstream-1',
    projectId: 'project-1',
    name: 'Login reliability',
    lead: 'Owner',
    status: 'active',
    brief: 'Make login reliable.',
    primaryWorkspace: 'Mac Workspace',
    queueStatus: 'Idle',
  );

  testWidgets('Project explains team collaboration and Workstreams',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
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

    expect(find.text('Authentication'), findsOneWidget);
    expect(find.text('Workstreams'), findsOneWidget);
    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Each Workstream is one focused area of team work.'),
        findsOneWidget);
    expect(find.byTooltip('Create Workstream'), findsOneWidget);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Runs'), findsNothing);
    expect(find.text('Artifacts'), findsNothing);
    expect(find.text('Execution'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Workstream UI uses product vocabulary', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: WorkstreamPage(
            project: project,
            workstream: workstream,
            onBackToProject: () {},
            onArchive: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('No chat messages yet'), findsOneWidget);
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(find.text('What should Conclave do?'), findsNothing);
    expect(find.text('lease'), findsNothing);
    expect(find.text('fencing token'), findsNothing);
    expect(find.text('Durable Object'), findsNothing);
    expect(find.text('checkout key'), findsNothing);
  });
}

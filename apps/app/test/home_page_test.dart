import 'package:conclave_app/src/features/home/home_page.dart';
import 'package:conclave_app/src/studio/studio_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget scaffold(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  const project = StudioProject(
    id: 'project-1',
    name: 'Project One',
    branch: 'main',
    activeGoals: 0,
    lastActivity: 'Today',
  );

  testWidgets('Getting Started gives the three Workspace-first steps',
      (tester) async {
    await tester.pumpWidget(scaffold(HomePage(
      projects: const [],
      workspaces: const [],
      workers: const [],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (_) {},
      onOpenChat: (_, __) {},
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onOpenArchivedProjects: () {},
    )));

    expect(find.text('Getting started'), findsOneWidget);
    expect(find.text('Connect a Workspace'), findsOneWidget);
    expect(
        find.text('Configure Workers in Conclave Workspace'), findsOneWidget);
    expect(find.text('Create Project'), findsOneWidget);
    expect(find.text('Archived Projects'), findsNothing);
    expect(find.text('Execution'), findsNothing);
    expect(find.text('Workers'), findsNothing);
  });

  testWidgets(
      'Home shows Ready Workers and both execution metrics open Workspaces',
      (tester) async {
    var workspaceOpens = 0;
    await tester.pumpWidget(scaffold(HomePage(
      projects: const [project],
      workspaces: const [
        StudioWorkspace(id: 'workspace-1', name: 'MacBook'),
      ],
      workers: const [
        StudioWorker(
          id: 'ready-1',
          workspaceId: 'workspace-1',
          workspaceName: 'MacBook',
          workerTypeId: 'codex',
          name: 'Ready Codex',
          status: 'ready',
          authStrategy: 'browser_auth',
          credentialStatus: 'ready',
          localConcurrencyLimit: 1,
          revision: 1,
          capabilities: [],
          allowedModels: [],
        ),
        StudioWorker(
          id: 'attention-1',
          workspaceId: 'workspace-1',
          workspaceName: 'MacBook',
          workerTypeId: 'claude-code',
          name: 'Needs Login',
          status: 'needs_attention',
          authStrategy: 'browser_auth',
          credentialStatus: 'needs_authentication',
          localConcurrencyLimit: 1,
          revision: 1,
          capabilities: [],
          allowedModels: [],
        ),
      ],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () => workspaceOpens++,
      onOpenProject: (_) {},
      onOpenChat: (_, __) {},
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onOpenArchivedProjects: () {},
    )));

    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Ready Workers'), findsOneWidget);
    final readyWorkersCard = find.ancestor(
      of: find.text('Ready Workers'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: readyWorkersCard, matching: find.text('1')),
      findsOneWidget,
    );
    expect(find.text('Workers'), findsNothing);
    expect(find.text('Execution'), findsNothing);

    await tester.tap(find.text('Workspaces'));
    await tester.tap(find.text('Ready Workers'));
    expect(workspaceOpens, 2);
  });
}

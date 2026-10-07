import 'package:conclave_app/src/features/home/home_page.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget scaffold(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  const project = AxProject(
    id: 'project-1',
    name: 'Project One',
    branch: 'main',
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
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onOpenArchivedProjects: () {},
    )));

    expect(find.text('Getting started'), findsOneWidget);
    expect(find.text('Connect a Workspace'), findsOneWidget);
    expect(find.text('Set up Engine and Profiles in Conclave Workspace'),
        findsOneWidget);
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
        AxWorkspace(id: 'workspace-1', name: 'MacBook'),
      ],
      workers: const [
        AxWorker(
          id: 'ready-1',
          workspaceId: 'workspace-1',
          workspaceName: 'MacBook',
          workerTypeId: 'chatgpt',
          displayName: 'ChatGPT',
          status: 'ready',
          readinessState: 'ready',
          localConcurrencyLimit: 1,
          capabilities: [],
        ),
        AxWorker(
          id: 'attention-1',
          workspaceId: 'workspace-1',
          workspaceName: 'MacBook',
          workerTypeId: 'gemini',
          displayName: 'Gemini',
          status: 'needs_attention',
          readinessState: 'sign_in_required',
          attentionReasonCode: 'sign_in_required',
          localConcurrencyLimit: 1,
          capabilities: [],
        ),
      ],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () => workspaceOpens++,
      onOpenProject: (_) {},
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

  testWidgets('Pending invitations appear on zero-project screen with actions',
      (tester) async {
    var accepted = false;
    var declined = false;
    const invite = AxProjectInvitation(
      id: 'inv-1',
      projectId: 'proj-123',
      projectName: 'Conclave AX Development',
      email: 'ulikossnokia@gmail.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'user-1',
      invitedByUserEmail: 'vitalii@nohainc.com',
      invitedByUserName: 'Vitalii Noha',
      createdAt: '2026-10-07T12:00:00Z',
    );

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [],
      workspaces: const [],
      workers: const [],
      invitations: const [invite],
      onAcceptInvitation: (_) => accepted = true,
      onDeclineInvitation: (_) => declined = true,
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (_) {},
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onOpenArchivedProjects: () {},
    )));

    expect(find.text('Welcome to Conclave AX'), findsOneWidget);
    expect(find.text('Pending invitations (1)'), findsOneWidget);
    expect(find.text('Conclave AX Development'), findsOneWidget);
    expect(find.text('Invited by Vitalii Noha · MEMBER'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    expect(accepted, isTrue);

    await tester.tap(find.text('Decline'));
    expect(declined, isTrue);
  });

  testWidgets('Pending invitations appear on established home screen',
      (tester) async {
    const invite = AxProjectInvitation(
      id: 'inv-1',
      projectId: 'proj-123',
      projectName: 'Conclave AX Development',
      email: 'ulikossnokia@gmail.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'user-1',
      invitedByUserEmail: 'vitalii@nohainc.com',
      createdAt: '2026-10-07T12:00:00Z',
    );

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [project],
      workspaces: const [],
      workers: const [],
      invitations: const [invite],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (_) {},
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onOpenArchivedProjects: () {},
    )));

    expect(find.text('Pending invitations (1)'), findsOneWidget);
    expect(find.text('Conclave AX Development'), findsOneWidget);
    expect(
        find.text('Invited by vitalii@nohainc.com · MEMBER'), findsOneWidget);
  });
}

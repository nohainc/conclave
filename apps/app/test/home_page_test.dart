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

  const testInvite1 = AxProjectInvitation(
    id: 'inv-1',
    projectId: 'proj-123',
    projectName: 'Family Travel',
    email: 'vitalii@nohainc.com',
    role: 'owner',
    status: 'pending',
    invitedByUserId: 'user-2',
    invitedByUserEmail: 'julia@nohainc.com',
    invitedByUserName: 'Julia',
    createdAt: '2026-10-07T12:00:00Z',
  );

  const testInvite2 = AxProjectInvitation(
    id: 'inv-2',
    projectId: 'proj-456',
    projectName: 'Home Renovation',
    email: 'vitalii@nohainc.com',
    role: 'editor',
    status: 'pending',
    invitedByUserId: 'user-3',
    invitedByUserEmail: 'alex@nohainc.com',
    invitedByUserName: 'Alex',
    createdAt: '2026-10-07T14:00:00Z',
  );

  testWidgets(
      'NewUserHome renders collaborative onboarding and value cards when no invitations exist',
      (tester) async {
    var projectCreated = false;
    var workspaceOpened = false;

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () => workspaceOpened = true,
      onOpenProject: (_) {},
      onOpenRun: (_, __) {},
      onCreateProject: () => projectCreated = true,
    )));

    // NewUserHome Header & Hero
    expect(find.text('Welcome to Conclave AX'), findsOneWidget);
    expect(find.text('Bring your people and AI together.'), findsOneWidget);
    expect(find.text('Create your first Project'), findsOneWidget);
    expect(find.text('Start a shared space for people, conversations and AI.'),
        findsOneWidget);
    expect(find.text('Create Project →'), findsOneWidget);

    // No priority invitation card or separator
    expect(find.text('Join a Project'), findsNothing);
    expect(find.text('or'), findsNothing);

    // Value cards
    expect(find.text('How Conclave AX works'), findsOneWidget);
    expect(find.text('People first'), findsOneWidget);
    expect(find.text('Private credentials'), findsOneWidget);
    expect(find.text('Shared conversations'), findsOneWidget);

    // Advanced local execution card
    expect(find.text('Want to use AI or tools running on your computer?'),
        findsOneWidget);
    expect(
        find.text(
            'Connect Conclave Workspace to make local Workers available to your Projects.'),
        findsOneWidget);
    expect(find.text('Connect Workspace →'), findsOneWidget);

    // Dashboard sections must NOT appear for new user
    expect(find.text('For you'), findsNothing);
    expect(find.text('Continue working'), findsNothing);
    expect(find.text("What's new in Conclave"), findsNothing);
    expect(find.text('AI updates'), findsNothing);
    expect(find.text('Ready Workers'), findsNothing);
    expect(find.text('Archived Projects'), findsNothing);

    await tester.tap(find.text('Create Project →'));
    expect(projectCreated, isTrue);

    await tester.ensureVisible(find.text('Connect Workspace →'));
    await tester.tap(find.text('Connect Workspace →'));
    expect(workspaceOpened, isTrue);
  });

  testWidgets(
      'NewUserHome prioritizes Join a Project card when user has 0 projects but has pending invitations',
      (tester) async {
    var projectCreated = false;
    var workspaceOpened = false;
    AxProjectInvitation? acceptedInvite;
    AxProjectInvitation? declinedInvite;

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [],
      workspaces: const [],
      workers: const [],
      invitations: const [testInvite1, testInvite2],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () => workspaceOpened = true,
      onOpenProject: (_) {},
      onOpenRun: (_, __) {},
      onCreateProject: () => projectCreated = true,
      onAcceptInvitation: (inv) => acceptedInvite = inv,
      onDeclineInvitation: (inv) => declinedInvite = inv,
    )));

    // Header
    expect(find.text('Welcome to Conclave AX'), findsOneWidget);
    expect(find.text('Bring your people and AI together.'), findsOneWidget);

    // Priority Join a Project card
    expect(find.text('Join a Project'), findsOneWidget);
    expect(find.text('You have 2 invitations.'), findsOneWidget);
    expect(find.text('Family Travel'), findsOneWidget);
    expect(find.text('Invited by Julia · OWNER'), findsOneWidget);
    expect(find.text('Home Renovation'), findsOneWidget);
    expect(find.text('Invited by Alex · EDITOR'), findsOneWidget);

    // 'or' divider and Create your first Project
    expect(find.text('or'), findsOneWidget);
    expect(find.text('Create your first Project'), findsOneWidget);
    expect(find.text('Create Project →'), findsOneWidget);

    // Value cards
    expect(find.text('How Conclave AX works'), findsOneWidget);
    expect(find.text('People first'), findsOneWidget);
    expect(find.text('Private credentials'), findsOneWidget);
    expect(find.text('Shared conversations'), findsOneWidget);

    // Advanced workspace connection
    expect(find.text('Want to use AI or tools running on your computer?'),
        findsOneWidget);
    expect(
        find.text(
            'Connect Conclave Workspace to make local Workers available to your Projects.'),
        findsOneWidget);
    expect(find.text('Connect Workspace →'), findsOneWidget);

    // Test accept on first invite
    await tester.tap(find.text('Accept').first);
    expect(acceptedInvite?.id, 'inv-1');

    // Test decline on second invite
    await tester.tap(find.text('Decline').last);
    expect(declinedInvite?.id, 'inv-2');

    // Test create project
    await tester.tap(find.text('Create Project →'));
    expect(projectCreated, isTrue);

    // Test connect workspace
    await tester.ensureVisible(find.text('Connect Workspace →'));
    await tester.tap(find.text('Connect Workspace →'));
    expect(workspaceOpened, isTrue);
  });

  testWidgets(
      'EstablishedUserHome implements the 4-part contract and omits onboarding',
      (tester) async {
    var openedProject = '';
    var openedWorkstream = '';
    AxProjectInvitation? acceptedInvite;

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
      ],
      invitations: const [testInvite1],
      continueWorkItems: const [
        AxContinueWorkItem(
          projectId: 'project-1',
          projectName: 'Website Redesign',
          workstreamId: 'ws-landing',
          workstreamTitle: 'Landing page',
          collaboratorsDisplay: 'You and ChatGPT',
          lastMessageSnippet: "Let's simplify the hero section...",
          lastActivityDisplay: '18 min ago',
        ),
      ],
      attentionItems: const [
        AxHomeAttentionItem(
          id: 'attn-1',
          title: 'Authentication workstream needs your input',
          subtitle: 'Question from Erik about OAuth providers',
          timestampDisplay: '24 min ago',
          projectId: 'project-1',
          workstreamId: 'ws-auth',
          actionLabel: 'Open',
        ),
      ],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (id) => openedProject = id,
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onAcceptInvitation: (inv) => acceptedInvite = inv,
      onOpenWorkstream: (pId, wsId) {
        openedProject = pId;
        openedWorkstream = wsId;
      },
      onOpenNotifications: () {},
    )));

    // 1. FOR YOU (unified prioritized card projection)
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('View all'), findsOneWidget);
    expect(find.text('Project invitation'), findsOneWidget);
    expect(find.text('Julia invited you to Family Travel'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);

    expect(find.text('Needs your input'), findsOneWidget);
    expect(find.text('Authentication workstream needs your input'),
        findsOneWidget);
    expect(find.text('Open'), findsOneWidget);

    // 2. CONTINUE WORKING
    expect(find.text('Continue working'), findsOneWidget);
    expect(find.text('Website Redesign'), findsOneWidget);
    expect(find.text('Landing page'), findsOneWidget);
    expect(find.text('You and ChatGPT'), findsOneWidget);
    expect(find.text('Continue →'), findsOneWidget);

    // 3. WHAT'S NEW
    expect(find.text("What's new in Conclave"), findsOneWidget);
    expect(find.text('Project Invitations'), findsOneWidget);
    expect(find.text('Conversation Continuity'), findsOneWidget);

    // 4. AI UPDATES
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('ChatGPT Worker'), findsOneWidget);

    // INVARIANTS: Onboarding cards and prohibited legacy elements must NOT appear
    expect(find.text('Welcome to Conclave AX'), findsNothing);
    expect(find.text('How Conclave AX works'), findsNothing);
    expect(find.text('Projects count'), findsNothing);
    expect(find.text('Ready Workers count'), findsNothing);
    expect(find.text('Workspaces count'), findsNothing);
    expect(find.text('No active Runs'), findsNothing);
    expect(find.text('Nothing needs your attention.'), findsNothing);
    expect(find.text('Archived Projects'), findsNothing);
    expect(find.text('Your execution capacity at a glance.'), findsNothing);

    await tester.tap(find.text('Continue →'));
    expect(openedProject, 'project-1');
    expect(openedWorkstream, 'ws-landing');

    await tester.tap(find.text('Accept'));
    expect(acceptedInvite?.id, 'inv-1');
  });

  testWidgets(
      'For you section correctly prioritizes items and respects 5-item limit',
      (tester) async {
    var notificationsOpened = false;
    var openedProject = '';
    var openedWorkstream = '';

    final manyAttentionItems = [
      const AxHomeAttentionItem(
        id: 'completed-1',
        kind: AxAttentionKind.completed,
        categoryLabel: 'Completed',
        title: 'Gemini finished reviewing Landing Page',
        subtitle: 'Website Redesign',
        timestampDisplay: '1 hour ago',
        actionLabel: 'Review →',
        projectId: 'proj-1',
        workstreamId: 'ws-landing',
      ),
      const AxHomeAttentionItem(
        id: 'failed-1',
        kind: AxAttentionKind.failedExecution,
        categoryLabel: 'Failed execution',
        title: 'Build task failed on CI Worker',
        subtitle: 'Project One',
        timestampDisplay: '15 min ago',
        actionLabel: 'Inspect →',
        projectId: 'proj-1',
      ),
      const AxHomeAttentionItem(
        id: 'worker-prob-1',
        kind: AxAttentionKind.workerProblem,
        categoryLabel: 'Worker needs attention',
        title: 'ChatGPT Worker authentication expired',
        subtitle: 'Workspace: MacBook',
        timestampDisplay: '30 min ago',
        actionLabel: 'Fix →',
      ),
      const AxHomeAttentionItem(
        id: 'input-1',
        kind: AxAttentionKind.needsInput,
        categoryLabel: 'Needs your input',
        title: 'Authentication workstream needs your input',
        subtitle: 'Conclave',
        timestampDisplay: '24 min ago',
        actionLabel: 'Open',
        projectId: 'proj-1',
        workstreamId: 'ws-auth',
      ),
      const AxHomeAttentionItem(
        id: 'workspace-prob-1',
        kind: AxAttentionKind.workspaceProblem,
        categoryLabel: 'Workspace offline',
        title: "Workspace Mac-Mini went offline",
        subtitle: 'Re-connect to enable workers',
        timestampDisplay: '45 min ago',
        actionLabel: 'Connect →',
      ),
      const AxHomeAttentionItem(
        id: 'general-extra',
        kind: AxAttentionKind.general,
        categoryLabel: 'Info',
        title: 'Lower priority extra notification',
        subtitle: 'Should be cut off past top 5',
        timestampDisplay: '2 hours ago',
      ),
    ];

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [project],
      workspaces: const [],
      workers: const [],
      invitations: const [testInvite1], // Priority 1: invitation
      attentionItems: manyAttentionItems,
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (id) => openedProject = id,
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onOpenWorkstream: (pId, wsId) {
        openedProject = pId;
        openedWorkstream = wsId;
      },
      onOpenNotifications: () => notificationsOpened = true,
    )));

    expect(find.text('For you'), findsOneWidget);
    expect(find.text('View all'), findsOneWidget);

    // Priority 1: Invitation (present)
    expect(find.text('Project invitation'), findsOneWidget);
    expect(find.text('Julia invited you to Family Travel'), findsOneWidget);

    // Priority 2: Needs your input (present)
    expect(find.text('Needs your input'), findsOneWidget);
    expect(find.text('Authentication workstream needs your input'),
        findsOneWidget);

    // Priority 3: Failed execution (present)
    expect(find.text('Failed execution'), findsOneWidget);
    expect(find.text('Build task failed on CI Worker'), findsOneWidget);

    // Priority 4: Worker needs attention (present)
    expect(find.text('Worker needs attention'), findsOneWidget);
    expect(find.text('ChatGPT Worker authentication expired'), findsOneWidget);

    // Priority 5: Workspace offline (present - total 5 items reached)
    expect(find.text('Workspace offline'), findsOneWidget);
    expect(find.text("Workspace Mac-Mini went offline"), findsOneWidget);

    // Priority 6 & lower items past limit of 5:
    // 'Gemini finished reviewing Landing Page' (Priority 6) and 'Lower priority extra notification' (Priority 7) should be cut off
    expect(find.text('Gemini finished reviewing Landing Page'), findsNothing);
    expect(find.text('Lower priority extra notification'), findsNothing);

    // Test View all trigger
    await tester.tap(find.text('View all'));
    expect(notificationsOpened, isTrue);

    // Test action navigation on attention item
    await tester.tap(find.text('Open'));
    expect(openedProject, 'proj-1');
    expect(openedWorkstream, 'ws-auth');
  });
}

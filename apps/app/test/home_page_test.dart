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
    expect(find.text('View all notifications →'), findsOneWidget);
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
    expect(find.text('WEBSITE REDESIGN'), findsOneWidget);
    expect(find.text('Landing page'), findsOneWidget);
    expect(find.text('You and ChatGPT · 18 min ago'), findsOneWidget);
    expect(find.text('"Let\'s simplify the hero section..."'), findsOneWidget);
    expect(find.text('Continue →'), findsOneWidget);

    // 3. WHAT'S NEW
    expect(find.text("What's new"), findsOneWidget);
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

    await tester.ensureVisible(find.text('Continue →'));
    await tester.tap(find.text('Continue →'));
    expect(openedProject, 'project-1');
    expect(openedWorkstream, 'ws-landing');

    await tester.ensureVisible(find.text('Accept'));
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
    expect(find.text('View all notifications →'), findsOneWidget);

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

    // Test View all notifications trigger
    await tester.tap(find.text('View all notifications →'));
    expect(notificationsOpened, isTrue);

    // Test action navigation on attention item
    await tester.tap(find.text('Open'));
    expect(openedProject, 'proj-1');
    expect(openedWorkstream, 'ws-auth');
  });

  testWidgets(
      'For you selection ranks by priority, unread status, actionability, and recency',
      (tester) async {
    final now = DateTime.now();
    final items = [
      // Same category (completed) but unread vs read:
      AxHomeAttentionItem(
        id: 'comp-read',
        kind: AxAttentionKind.completed,
        categoryLabel: 'Completed',
        title: 'Read Task A',
        subtitle: 'Done',
        timestampDisplay: '10 min ago',
        isUnread: false,
        isActionable: false,
        createdAt: now.subtract(const Duration(minutes: 10)),
      ),
      AxHomeAttentionItem(
        id: 'comp-unread',
        kind: AxAttentionKind.completed,
        categoryLabel: 'Completed',
        title: 'Unread Task B',
        subtitle: 'Done',
        timestampDisplay: '12 min ago',
        isUnread: true,
        isActionable: false,
        createdAt: now.subtract(const Duration(minutes: 12)),
      ),
      // Same category (needsInput), actionable
      AxHomeAttentionItem(
        id: 'input-actionable',
        kind: AxAttentionKind.needsInput,
        categoryLabel: 'Needs your input',
        title: 'Actionable input needed',
        subtitle: 'Decision required',
        timestampDisplay: '5 min ago',
        actionLabel: 'Review →',
        isUnread: true,
        isActionable: true,
        createdAt: now.subtract(const Duration(minutes: 5)),
      ),
      // Same category (failedExecution), newer vs older:
      AxHomeAttentionItem(
        id: 'fail-newer',
        kind: AxAttentionKind.failedExecution,
        categoryLabel: 'Failed execution',
        title: 'Newer Failure',
        subtitle: 'Just failed',
        timestampDisplay: '1 min ago',
        actionLabel: 'Inspect →',
        isUnread: true,
        isActionable: true,
        createdAt: now.subtract(const Duration(minutes: 1)),
      ),
      AxHomeAttentionItem(
        id: 'fail-older',
        kind: AxAttentionKind.failedExecution,
        categoryLabel: 'Failed execution',
        title: 'Older Failure',
        subtitle: 'Failed earlier',
        timestampDisplay: '20 min ago',
        actionLabel: 'Inspect →',
        isUnread: true,
        isActionable: true,
        createdAt: now.subtract(const Duration(minutes: 20)),
      ),
    ];

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [project],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      attentionItems: items,
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (_) {},
      onOpenRun: (_, __) {},
      onCreateProject: () {},
    )));

    // Expect input-actionable (Priority 2) first
    expect(find.text('Actionable input needed'), findsOneWidget);
    // Expect fail-newer & fail-older (Priority 3)
    expect(find.text('Newer Failure'), findsOneWidget);
    expect(find.text('Older Failure'), findsOneWidget);
    // Expect unread completed (Priority 6, unread) before read completed (Priority 6, read)
    expect(find.text('Unread Task B'), findsOneWidget);
    expect(find.text('Read Task A'), findsOneWidget);
  });

  testWidgets(
      'AxHomeAttentionItem abstraction renders and executes decoupled primaryAction and secondaryAction',
      (tester) async {
    var primaryExecuted = false;
    var secondaryExecuted = false;

    final itemWithActions = AxHomeAttentionItem(
      id: 'custom-action-item',
      type: AxHomeAttentionType.needsInput,
      title: 'Decoupled Action Item',
      description: 'Item with encapsulated primary and secondary closures',
      timestampDisplay: 'Just now',
      primaryAction: AxHomeAttentionAction(
        label: 'Custom Resolve',
        onPerform: () => primaryExecuted = true,
      ),
      secondaryAction: AxHomeAttentionAction(
        label: 'Custom Dismiss',
        onPerform: () => secondaryExecuted = true,
        isDestructive: true,
      ),
    );

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [project],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      attentionItems: [itemWithActions],
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (_) {},
      onOpenRun: (_, __) {},
      onCreateProject: () {},
    )));

    expect(find.text('Decoupled Action Item'), findsOneWidget);
    expect(find.text('Item with encapsulated primary and secondary closures'),
        findsOneWidget);
    expect(find.text('Custom Resolve'), findsOneWidget);
    expect(find.text('Custom Dismiss'), findsOneWidget);

    await tester.tap(find.text('Custom Resolve'));
    expect(primaryExecuted, isTrue);

    await tester.tap(find.text('Custom Dismiss'));
    expect(secondaryExecuted, isTrue);
  });

  test('AxHomeAttentionProjector cleanly maps and prioritizes domain items',
      () {
    var acceptedInvite = false;
    var declinedInvite = false;
    var openedProject = '';

    final projected = AxHomeAttentionProjector.project(
      invitations: [testInvite1],
      rawAttentionItems: [
        const AxHomeAttentionItem(
          id: 'attn-raw',
          type: AxHomeAttentionType.executionFailed,
          title: 'Execution Failed on Worker',
          description: 'Stack trace error',
          actionLabel: 'Inspect →',
          projectId: 'project-1',
        ),
      ],
      openFindingCount: 2,
      projects: [project],
      onAcceptInvitation: (_) => acceptedInvite = true,
      onDeclineInvitation: (_) => declinedInvite = true,
      onOpenProject: (id) => openedProject = id,
    );

    expect(projected.length, 3);

    // 1. Invitation (Priority 1)
    expect(projected[0].type, AxHomeAttentionType.projectInvitation);
    expect(projected[0].primaryAction?.label, 'Accept');
    expect(projected[0].secondaryAction?.label, 'Decline');
    projected[0].primaryAction?.onPerform();
    expect(acceptedInvite, isTrue);
    projected[0].secondaryAction?.onPerform();
    expect(declinedInvite, isTrue);

    // 2. Open findings (Priority 2, needsInput)
    expect(projected[1].type, AxHomeAttentionType.needsInput);
    expect(projected[1].primaryAction?.label, 'Review →');
    projected[1].primaryAction?.onPerform();
    expect(openedProject, 'project-1');

    // 3. Raw attention item (Priority 3, executionFailed)
    expect(projected[2].type, AxHomeAttentionType.executionFailed);
    expect(projected[2].primaryAction?.label, 'Inspect →');
    openedProject = '';
    projected[2].primaryAction?.onPerform();
    expect(openedProject, 'project-1');
  });

  testWidgets(
      'Continue Working displays 3-5 workstream cards with project, title, collaborators, snippet and action',
      (tester) async {
    var openedProject = '';
    var openedWorkstream = '';

    final continueItems = [
      const AxContinueWorkItem(
        projectId: 'proj-conclave',
        projectName: 'Conclave Development',
        workstreamId: 'ws-sessions',
        workstreamTitle: 'Worker Sessions',
        collaboratorsDisplay: 'ChatGPT',
        lastMessageSnippet: 'We should persist the session context.',
        lastActivityDisplay: '23 min ago',
      ),
      const AxContinueWorkItem(
        projectId: 'proj-web',
        projectName: 'Website',
        workstreamId: 'ws-landing',
        workstreamTitle: 'Landing Page',
        collaboratorsDisplay: 'You + Gemini',
        lastMessageSnippet: 'The hero should bring people together.',
        lastActivityDisplay: 'Yesterday',
      ),
      const AxContinueWorkItem(
        projectId: 'proj-docs',
        projectName: 'Documentation',
        workstreamId: 'ws-architecture',
        workstreamTitle: 'Architecture v8',
        collaboratorsDisplay: 'Julia + Claude',
        lastMessageSnippet: 'ADRs updated with signed tool profiles.',
        lastActivityDisplay: '2 days ago',
      ),
      const AxContinueWorkItem(
        projectId: 'proj-cloud',
        projectName: 'Cloud Services',
        workstreamId: 'ws-d1',
        workstreamTitle: 'D1 Migrations',
        collaboratorsDisplay: 'Erik',
        lastMessageSnippet: 'Baseline schema applied.',
        lastActivityDisplay: '3 days ago',
      ),
      const AxContinueWorkItem(
        projectId: 'proj-mobile',
        projectName: 'Mobile App',
        workstreamId: 'ws-ios',
        workstreamTitle: 'iOS Polish',
        collaboratorsDisplay: 'Alex',
        lastMessageSnippet: 'Responsive layouts fixed.',
        lastActivityDisplay: '4 days ago',
      ),
      const AxContinueWorkItem(
        projectId: 'proj-extra',
        projectName: 'Extra Project',
        workstreamId: 'ws-extra',
        workstreamTitle: 'Extra Workstream',
        collaboratorsDisplay: 'Bot',
        lastMessageSnippet: 'Should not appear past 5 items.',
        lastActivityDisplay: '5 days ago',
      ),
    ];

    await tester.pumpWidget(scaffold(HomePage(
      projects: const [project],
      workspaces: const [],
      workers: const [],
      invitations: const [],
      continueWorkItems: continueItems,
      run: null,
      openFindingCount: 0,
      onOpenWorkspaces: () {},
      onOpenProject: (_) {},
      onOpenRun: (_, __) {},
      onCreateProject: () {},
      onOpenWorkstream: (pId, wsId) {
        openedProject = pId;
        openedWorkstream = wsId;
      },
    )));

    expect(find.text('Continue working'), findsOneWidget);

    // Card 1
    expect(find.text('CONCLAVE DEVELOPMENT'), findsOneWidget);
    expect(find.text('Worker Sessions'), findsOneWidget);
    expect(find.text('ChatGPT · 23 min ago'), findsOneWidget);
    expect(
        find.text('"We should persist the session context."'), findsOneWidget);

    // Card 2
    expect(find.text('WEBSITE'), findsOneWidget);
    expect(find.text('Landing Page'), findsOneWidget);
    expect(find.text('You + Gemini · Yesterday'), findsOneWidget);
    expect(
        find.text('"The hero should bring people together."'), findsOneWidget);

    // Card 3
    expect(find.text('DOCUMENTATION'), findsOneWidget);
    expect(find.text('Architecture v8'), findsOneWidget);

    // Card 4
    expect(find.text('CLOUD SERVICES'), findsOneWidget);
    expect(find.text('D1 Migrations'), findsOneWidget);

    // Card 5
    expect(find.text('MOBILE APP'), findsOneWidget);
    expect(find.text('iOS Polish'), findsOneWidget);

    // 6th item should be truncated by 5-item limit
    expect(find.text('EXTRA PROJECT'), findsNothing);
    expect(find.text('Extra Workstream'), findsNothing);

    // Test clicking Continue → on first card
    await tester.ensureVisible(find.text('Continue →').first);
    await tester.tap(find.text('Continue →').first);
    expect(openedProject, 'proj-conclave');
    expect(openedWorkstream, 'ws-sessions');
  });

  test(
      'AxRecentWorkRanker ranks by meaningful activity factors and excludes archived/inaccessible items',
      () {
    final now = DateTime(2026, 10, 8, 12, 0, 0);

    final itemArchived = AxContinueWorkItem(
      projectId: 'p-archived',
      projectName: 'Archived Project',
      workstreamId: 'ws-1',
      workstreamTitle: 'Old Workstream',
      collaboratorsDisplay: 'None',
      lastMessageSnippet: 'Archived',
      lastActivityDisplay: '1 year ago',
      archived: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(minutes: 5)),
    );

    final itemInaccessible = AxContinueWorkItem(
      projectId: 'p-inaccessible',
      projectName: 'Inaccessible Project',
      workstreamId: 'ws-2',
      workstreamTitle: 'Restricted',
      collaboratorsDisplay: 'None',
      lastMessageSnippet: 'Restricted',
      lastActivityDisplay: 'Just now',
      isDirectMember: false,
      lastMeaningfulActivityAt: now.subtract(const Duration(minutes: 1)),
    );

    final itemPassiveSyncOnly = AxContinueWorkItem(
      projectId: 'p-passive',
      projectName: 'Passive Metadata Updated Project',
      workstreamId: 'ws-passive',
      workstreamTitle: 'No Real Messages',
      collaboratorsDisplay: 'None',
      lastMessageSnippet: 'Automated background sync ping',
      lastActivityDisplay: 'Just now',
      hasUserParticipation: false,
      hasRecentWorkerResponse: false,
      hasUnresolvedState: false,
      // Meaningful conversation was 3 days ago, only metadata was updated now
      lastMeaningfulActivityAt: now.subtract(const Duration(days: 3)),
    );

    final itemUserParticipated = AxContinueWorkItem(
      projectId: 'p-user',
      projectName: 'User Discussion Project',
      workstreamId: 'ws-user',
      workstreamTitle: 'Active Discussion',
      collaboratorsDisplay: 'You + Team',
      lastMessageSnippet: 'I responded with the specs.',
      lastActivityDisplay: '2 hours ago',
      hasUserParticipation: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(hours: 2)),
    );

    final itemWorkerResponded = AxContinueWorkItem(
      projectId: 'p-worker',
      projectName: 'AI Assistant Project',
      workstreamId: 'ws-worker',
      workstreamTitle: 'Worker Synthesis',
      collaboratorsDisplay: 'ChatGPT',
      lastMessageSnippet: 'Synthesis completed with 3 artifacts.',
      lastActivityDisplay: '1 hour ago',
      hasRecentWorkerResponse: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(hours: 1)),
    );

    final itemUnresolvedState = AxContinueWorkItem(
      projectId: 'p-unresolved',
      projectName: 'Execution Project',
      workstreamId: 'ws-unresolved',
      workstreamTitle: 'Pending Decisions',
      collaboratorsDisplay: 'You + Gemini',
      lastMessageSnippet: 'Waiting for parameter confirmation.',
      lastActivityDisplay: '4 hours ago',
      hasUnresolvedState: true,
      hasUserParticipation: true,
      lastMeaningfulActivityAt: now.subtract(const Duration(hours: 4)),
    );

    final ranked = AxRecentWorkRanker.rank(
      [
        itemArchived,
        itemInaccessible,
        itemPassiveSyncOnly,
        itemUserParticipated,
        itemWorkerResponded,
        itemUnresolvedState,
      ],
      now: now,
    );

    // Assert archived and inaccessible items are completely excluded
    expect(ranked.any((it) => it.projectId == 'p-archived'), isFalse);
    expect(ranked.any((it) => it.projectId == 'p-inaccessible'), isFalse);

    // Expected order:
    // 1. itemUnresolvedState (score ~ 1000 + 500 + 100 + decay) -> Rank 1
    // 2. itemUserParticipated (score ~ 500 + 100 + decay) -> Rank 2
    // 3. itemWorkerResponded (score ~ 250 + 100 + decay) -> Rank 3
    // 4. itemPassiveSyncOnly (score ~ 0 + 100 + decayed 3 days) -> Rank 4 (does NOT beat active conversations despite background metadata)
    expect(ranked.length, 4);
    expect(ranked[0].workstreamId, 'ws-unresolved');
    expect(ranked[1].workstreamId, 'ws-user');
    expect(ranked[2].workstreamId, 'ws-worker');
    expect(ranked[3].workstreamId, 'ws-passive');
  });

  test(
      'AxProductUpdate domain model and AxProductUpdateService lifecycle & read state filtering',
      () {
    final now = DateTime(2026, 10, 8, 12, 0, 0);

    final update1Published = AxProductUpdate(
      id: 'up-1',
      slug: 'invitations',
      title: 'Project Invitations',
      summary: 'Invite collaborators to projects.',
      category: AxProductUpdateCategory.collaboration,
      publishedAt: now.subtract(const Duration(days: 1)),
      status: AxProductUpdateStatus.published,
    );

    final update2Draft = AxProductUpdate(
      id: 'up-2',
      slug: 'draft-feature',
      title: 'Unreleased Draft',
      summary: 'Coming soon.',
      category: AxProductUpdateCategory.feature,
      publishedAt: now,
      status: AxProductUpdateStatus.draft,
    );

    final update3Archived = AxProductUpdate(
      id: 'up-3',
      slug: 'old-feature',
      title: 'Deprecated System',
      summary: 'Archived release.',
      category: AxProductUpdateCategory.improvement,
      publishedAt: now.subtract(const Duration(days: 60)),
      status: AxProductUpdateStatus.archived,
    );

    final update4Dismissed = AxProductUpdate(
      id: 'up-4',
      slug: 'workspace-sync',
      title: 'Workspace Sync',
      summary: 'Local process execution.',
      category: AxProductUpdateCategory.workspace,
      publishedAt: now.subtract(const Duration(days: 2)),
      status: AxProductUpdateStatus.published,
    );

    final update5Incompatible = AxProductUpdate(
      id: 'up-5',
      slug: 'future-v9',
      title: 'Future Feature',
      summary: 'Requires v9.0.0',
      category: AxProductUpdateCategory.worker,
      publishedAt: now,
      minimumAppVersion: '9.0.0',
      status: AxProductUpdateStatus.published,
    );

    final readStates = <String, AxUserProductUpdateState>{
      'up-1': AxUserProductUpdateState(
        userId: 'u-1',
        updateId: 'up-1',
        seenAt: now.subtract(const Duration(hours: 1)),
      ),
      'up-4': AxUserProductUpdateState(
        userId: 'u-1',
        updateId: 'up-4',
        dismissedAt: now.subtract(const Duration(minutes: 30)),
      ),
    };

    final allUpdates = [
      update1Published,
      update2Draft,
      update3Archived,
      update4Dismissed,
      update5Incompatible,
    ];

    // Test Home filtering: only published, non-dismissed, version-compatible updates
    final homeUpdates = AxProductUpdateService.getHomeUpdates(
      allUpdates,
      readStates: readStates,
      appVersion: '1.0.0',
    );

    expect(homeUpdates.length, 1);
    expect(homeUpdates.first.id, 'up-1');

    // Test unread count: update1 is seen, update4 is dismissed, update2 is draft, update5 incompatible
    // Only published un-seen un-dismissed compatible items are unread
    final unreadCount = AxProductUpdateService.computeUnreadCount(
      allUpdates,
      readStates: readStates,
      appVersion: '1.0.0',
    );
    expect(unreadCount, 0);

    // If update1 was not seen, unread count should be 1
    final unreadCountUnseen = AxProductUpdateService.computeUnreadCount(
      allUpdates,
      readStates: {},
      appVersion: '1.0.0',
    );
    expect(unreadCountUnseen, 2); // update1 and update4

    // Test Month/Year grouping for full changelog with historical releases
    final grouped = AxProductUpdateService.groupUpdatesByMonthYear(
      allUpdates,
      includeDrafts: true,
    );
    expect(grouped.containsKey('October 2026'), isTrue);
    expect(grouped.containsKey('August 2026'), isTrue);
  });

  testWidgets(
      'EstablishedUserHome renders What\'s new with badge, category tags, See all CTA, and AxWhatsNewDialog',
      (tester) async {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    final updates = [
      AxProductUpdate(
        id: 'up-1',
        slug: 'collab',
        title: 'Project Invitations',
        summary: 'Collaborate with your team.',
        details: 'Full RBAC invitation workflow directly inside AX.',
        category: AxProductUpdateCategory.collaboration,
        publishedAt: now,
        dateDisplay: 'Oct 8',
      ),
      AxProductUpdate(
        id: 'up-2',
        slug: 'continuity',
        title: 'Conversation Continuity',
        summary: 'Keep conversational context across Workers.',
        category: AxProductUpdateCategory.workflow,
        publishedAt: now.subtract(const Duration(days: 1)),
        dateDisplay: 'Oct 7',
      ),
    ];

    var seeAllOpened = false;
    AxProductUpdate? selectedDetailUpdate;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EstablishedUserHome(
            projects: const [
              AxProject(
                id: 'p-1',
                name: 'Main Project',
                description: 'Active project',
                archived: false,
                branch: 'main',
                lastActivity: 'Just now',
                workstreams: [],
              ),
            ],
            workspaces: const [],
            workers: const [],
            run: null,
            openFindingCount: 0,
            productUpdates: updates,
            productUpdateReadStates: const {}, // Both updates unread
            onOpenWorkspaces: () {},
            onOpenProject: (_) {},
            onOpenRun: (_, __) {},
            onOpenWhatsNew: () => seeAllOpened = true,
            onOpenUpdateDetail: (u) => selectedDetailUpdate = u,
          ),
        ),
      ),
    );

    // Verify What's new header with unread count badge (2 unread)
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('See all'), findsOneWidget);

    // Verify tiles rendered with category pill and CTA
    expect(find.text('COLLABORATION'), findsOneWidget);
    expect(find.text('WORKFLOW'), findsOneWidget);
    expect(find.text('Project Invitations'), findsOneWidget);
    expect(find.text('Conversation Continuity'), findsOneWidget);
    expect(find.text('Learn more →'), findsNWidgets(2));

    // Tap See all
    await tester.tap(find.text('See all'));
    await tester.pumpAndSettle();
    expect(seeAllOpened, isTrue);

    // Tap Learn more on first tile
    await tester.tap(find.text('Learn more →').first);
    await tester.pumpAndSettle();
    expect(selectedDetailUpdate?.id, 'up-1');
  });

  testWidgets('AxWhatsNewDialog displays grouped changelog and details',
      (tester) async {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    final updates = [
      AxProductUpdate(
        id: 'up-oct',
        title: 'October Feature',
        summary: 'Launched in October.',
        details: 'Detailed technical changelog for October release.',
        category: AxProductUpdateCategory.feature,
        publishedAt: now,
      ),
      AxProductUpdate(
        id: 'up-sep',
        title: 'September Feature',
        summary: 'Launched in September.',
        details: 'Detailed changelog for September release.',
        category: AxProductUpdateCategory.workspace,
        publishedAt: now.subtract(const Duration(days: 35)),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => AxWhatsNewDialog.show(
                  context,
                  updates: updates,
                ),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    // Verify Dialog rendered with Month Year grouping
    expect(find.text("What's New"), findsOneWidget);
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('October Feature'), findsOneWidget);
    expect(find.text('September Feature'), findsOneWidget);
    expect(find.text('Detailed technical changelog for October release.'),
        findsOneWidget);
  });

  test('Phase 16 — AxAiCapabilityUpdate domain model and serialization', () {
    const update = AxAiCapabilityUpdate(
      id: 'ai-gpt4o-mini',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      modelId: 'gpt-4o-mini',
      modelDisplayName: 'GPT-4o Mini',
      title: 'Fast lightweight model added',
      summary: 'GPT-4o Mini is now available for low-latency code tasks.',
      publishedAt: '2026-10-08T00:00:00Z',
      dateDisplay: 'Oct 8',
      minimumProfileVersion: '1.2.0',
    );

    expect(update.workerTypeId, 'chatgpt');
    expect(update.workerDisplayName, 'ChatGPT Worker');
    expect(update.type.isModelUpdate, isTrue);
    expect(update.type.isCapabilityUpdate, isFalse);
    expect(update.type.wireName, 'model_added');
    expect(update.type.label, 'Model Added');
    expect(update.dateDisplay, 'Oct 8');
    expect(update.isCompatibleWithProfileVersion('1.3.0'), isTrue);
    expect(update.isCompatibleWithProfileVersion('1.1.0'), isFalse);

    final json = update.toJson();
    expect(json['id'], 'ai-gpt4o-mini');
    expect(json['workerProfileId'], 'chatgpt');
    expect(json['provider'], 'openai');
    expect(json['type'], 'model_added');
    expect(json['modelId'], 'gpt-4o-mini');
    expect(json['modelDisplayName'], 'GPT-4o Mini');
    expect(json['title'], 'Fast lightweight model added');
    expect(json['minimumProfileVersion'], '1.2.0');

    final parsed = AxAiCapabilityUpdate.fromJson(json);
    expect(parsed.id, update.id);
    expect(parsed.workerProfileId, update.workerProfileId);
    expect(parsed.provider, update.provider);
    expect(parsed.type, update.type);
    expect(parsed.modelId, update.modelId);
    expect(parsed.modelDisplayName, update.modelDisplayName);
    expect(parsed.summary, update.summary);
    expect(parsed.minimumProfileVersion, update.minimumProfileVersion);
  });

  testWidgets(
      'Phase 16 — EstablishedUserHome renders AI capability updates with distinct badges',
      (tester) async {
    const aiUpdates = [
      AxAiCapabilityUpdate(
        id: 'ai-up-1',
        workerProfileId: 'chatgpt',
        provider: 'openai',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'New Reasoning Model',
        summary: 'Deep reasoning model enabled for complex code architecture.',
        publishedAt: '2026-10-08T00:00:00Z',
        dateDisplay: 'Oct 8',
      ),
      AxAiCapabilityUpdate(
        id: 'ai-up-2',
        workerProfileId: 'gemini',
        provider: 'google',
        type: AxAiCapabilityUpdateType.capabilityAdded,
        title: 'Structured Output Mode',
        summary: 'Enforce JSON schema guarantees across multi-turn runs.',
        publishedAt: '2026-10-09T00:00:00Z',
        dateDisplay: 'Oct 9',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EstablishedUserHome(
            projects: const [
              AxProject(
                id: 'p-1',
                name: 'Active Project',
                description: 'Project description',
                archived: false,
                branch: 'main',
                lastActivity: 'Just now',
                workstreams: [
                  AxWorkstream(
                    id: 'ws-1',
                    projectId: 'p-1',
                    name: 'AI Stream',
                    lead: 'Gemini',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: 'idle',
                  ),
                ],
              ),
            ],
            workspaces: const [],
            workers: const [
              AxWorker(
                id: 'w-chatgpt',
                workspaceId: 'ws-local',
                workspaceName: 'Local',
                workerTypeId: 'chatgpt',
                displayName: 'ChatGPT Worker',
                status: 'ready',
                readinessState: 'ready',
                localConcurrencyLimit: 2,
                capabilities: ['chat'],
              ),
            ],
            run: null,
            openFindingCount: 0,
            aiUpdates: aiUpdates,
            onOpenProject: (_) {},
            onOpenRun: (_, __) {},
            onOpenWorkspaces: () {},
          ),
        ),
      ),
    );

    // Verify section header and update details
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('ChatGPT Worker'), findsOneWidget);
    expect(find.text('MODEL ADDED'), findsOneWidget);
    expect(find.text('New Reasoning Model'), findsOneWidget);
    expect(find.text('Oct 8'), findsOneWidget);

    expect(find.text('Gemini Worker'), findsOneWidget);
    expect(find.text('CAPABILITY ADDED'), findsOneWidget);
    expect(find.text('Structured Output Mode'), findsOneWidget);
    expect(find.text('Oct 9'), findsOneWidget);
  });

  test(
      'Phase 17 — AxAiCapabilityUpdateService filters AI updates by user accessible workers',
      () {
    const chatgptWorker = AxWorker(
      id: 'w-1',
      workspaceId: 'ws-1',
      workspaceName: 'Local',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
      capabilities: ['chat'],
    );

    const updates = [
      AxAiCapabilityUpdate(
        id: 'up-gpt',
        workerProfileId: 'chatgpt',
        provider: 'openai',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'ChatGPT New Model',
        summary: 'New o3 model available.',
      ),
      AxAiCapabilityUpdate(
        id: 'up-claude',
        workerProfileId: 'claude',
        provider: 'anthropic',
        type: AxAiCapabilityUpdateType.modelAdded,
        title: 'Claude 3.7 Sonnet',
        summary: 'Hybrid reasoning and artifacts.',
      ),
      AxAiCapabilityUpdate(
        id: 'up-gemini',
        workerProfileId: 'gemini',
        provider: 'google',
        type: AxAiCapabilityUpdateType.capabilityAdded,
        title: 'Gemini Search Grounding',
        summary: 'Web grounded search outputs.',
      ),
    ];

    // Case 1: User has ChatGPT only -> ONLY ChatGPT updates returned
    final chatgptOnly = AxAiCapabilityUpdateService.getRelevantUpdates(
      updates: updates,
      workers: [chatgptWorker],
      projects: const [],
    );
    expect(chatgptOnly.length, 1);
    expect(chatgptOnly.first.workerProfileId, 'chatgpt');
    expect(chatgptOnly.first.title, 'ChatGPT New Model');

    // Case 2: User gains access through shared Project Worker (e.g. Gemini lead/config in shared project)
    const sharedProject = AxProject(
      id: 'proj-shared',
      name: 'Shared Project',
      branch: 'main',
      lastActivity: 'Now',
      workstreams: [
        AxWorkstream(
          id: 'ws-gemini',
          projectId: 'proj-shared',
          name: 'Gemini Analysis',
          lead: 'Gemini',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: 'idle',
        ),
      ],
    );

    final chatgptAndSharedGemini =
        AxAiCapabilityUpdateService.getRelevantUpdates(
      updates: updates,
      workers: [chatgptWorker],
      projects: [sharedProject],
    );
    expect(chatgptAndSharedGemini.length, 2);
    final workerIds =
        chatgptAndSharedGemini.map((u) => u.workerProfileId).toSet();
    expect(workerIds, containsAll(['chatgpt', 'gemini']));
    expect(workerIds, isNot(contains('claude')));

    // Case 3: User with 0 accessible workers -> returns empty list (cleanly omitted)
    final zeroWorkers = AxAiCapabilityUpdateService.getRelevantUpdates(
      updates: updates,
      workers: const [],
      projects: const [],
    );
    expect(zeroWorkers, isEmpty);
  });

  testWidgets(
      'Phase 17 — EstablishedUserHome omits AI updates when user has no accessible workers',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EstablishedUserHome(
            projects: const [
              AxProject(
                id: 'p-1',
                name: 'Solo Project',
                description: 'Solo project',
                archived: false,
                branch: 'main',
                lastActivity: 'Just now',
                workstreams: [],
              ),
            ],
            workspaces: const [],
            workers: const [],
            run: null,
            openFindingCount: 0,
            onOpenProject: (_) {},
            onOpenRun: (_, __) {},
            onOpenWorkspaces: () {},
          ),
        ),
      ),
    );

    // AI updates section is omitted cleanly
    expect(find.text('AI updates'), findsNothing);
  });

  test(
      'Phase 18 — Model discovery automatically generates system AI capability updates',
      () {
    final discoveryUpdates =
        AxAiCapabilityUpdateService.synthesizeDiscoveredModelUpdates(
      workerProfileId: 'chatgpt',
      provider: 'openai',
      workerDisplayName: 'ChatGPT Worker',
      previousModelIds: ['gpt-4o', 'o1-mini'],
      currentModelIds: ['gpt-4o', 'o1-mini', 'o3-mini'],
      timestamp: DateTime(2026, 10, 8),
    );

    expect(discoveryUpdates.length, 1);
    final autoUpdate = discoveryUpdates.first;
    expect(autoUpdate.isSystemGenerated, isTrue);
    expect(autoUpdate.isEditorial, isFalse);
    expect(autoUpdate.source, AxAiCapabilityUpdateSource.systemGenerated);
    expect(autoUpdate.type, AxAiCapabilityUpdateType.modelAdded);
    expect(autoUpdate.modelId, 'o3-mini');
    expect(autoUpdate.title, 'New model available');
    expect(autoUpdate.summary,
        'Model o3-mini is now available for your ChatGPT Worker.');
  });

  test(
      'Phase 18 — Editorial updates take precedence over raw system discovery updates',
      () {
    const editorialUpdate = AxAiCapabilityUpdate(
      id: 'ed-o3-mini',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      source: AxAiCapabilityUpdateSource.editorial,
      modelId: 'o3-mini',
      title: 'OpenAI o3-mini reasoning model released',
      summary: 'High-speed STEM reasoning model with flexible effort controls.',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    final rawDiscoveryUpdates =
        AxAiCapabilityUpdateService.synthesizeDiscoveredModelUpdates(
      workerProfileId: 'chatgpt',
      previousModelIds: ['gpt-4o'],
      currentModelIds: ['gpt-4o', 'o3-mini', 'gpt-4.5'],
    );
    expect(rawDiscoveryUpdates.length, 2);

    final merged = AxAiCapabilityUpdateService.mergeUpdates(
      editorialUpdates: [editorialUpdate],
      discoveryUpdates: rawDiscoveryUpdates,
    );

    // Should have 2 items total: editorial for o3-mini and discovery for gpt-4.5
    expect(merged.length, 2);
    final o3Item = merged.firstWhere((u) => u.modelId == 'o3-mini');
    expect(o3Item.isEditorial, isTrue);
    expect(o3Item.title, 'OpenAI o3-mini reasoning model released');

    final gpt45Item = merged.firstWhere((u) => u.modelId == 'gpt-4.5');
    expect(gpt45Item.isSystemGenerated, isTrue);
    expect(gpt45Item.title, 'New model available');
  });

  testWidgets(
      'Phase 19 — Running now renders ephemeral execution card with rich metadata and Open CTA when run is active',
      (tester) async {
    String? openedProjectId;
    String? openedRunId;

    const activeRun = AxRun(
      id: 'run-101',
      projectId: 'proj-landing',
      projectName: 'Website',
      workstreamId: 'ws-landing',
      workstreamTitle: 'Landing Page',
      status: RunStatus.running,
      objective: 'Landing page review',
      taskCount: 5,
      completedTaskCount: 2,
      openFindingCount: 0,
      verifiedCriterionCount: 2,
      criterionCount: 5,
      workerName: 'ChatGPT',
      modelName: 'Model X',
      effort: 'High',
      durationDisplay: 'Running for 1m 42s',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          projects: const [project],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: activeRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenProject: (_) {},
          onOpenRun: (pId, rId) {
            openedProjectId = pId;
            openedRunId = rId;
          },
        ),
      ),
    );

    // Section header
    expect(find.text('Running now'), findsOneWidget);

    // Card contents
    expect(find.text('Landing page review'), findsOneWidget);
    expect(find.text('ChatGPT · Model X · High'), findsOneWidget);
    expect(find.text('Website / Landing Page'), findsOneWidget);
    expect(find.text('Running for 1m 42s'), findsOneWidget);
    expect(find.text('Open →'), findsOneWidget);

    // Tap CTA
    await tester.tap(find.text('Open →'));
    expect(openedProjectId, 'proj-landing');
    expect(openedRunId, 'run-101');
  });

  testWidgets(
      'Phase 19 — Running now is completely omitted with zero noise when run is null or completed',
      (tester) async {
    // 1. When run is null
    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          projects: const [project],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: null,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenProject: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    expect(find.text('Running now'), findsNothing);
    expect(find.text('Open →'), findsNothing);
    expect(find.text('No active runs'), findsNothing);
    expect(find.text('No runs executing'), findsNothing);

    // 2. When run status is completed
    const completedRun = AxRun(
      id: 'run-done',
      status: RunStatus.completed,
      objective: 'Completed task review',
      taskCount: 3,
      completedTaskCount: 3,
      openFindingCount: 0,
      verifiedCriterionCount: 3,
      criterionCount: 3,
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          projects: const [project],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [],
          productUpdateReadStates: const {},
          aiUpdates: const [],
          run: completedRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenProject: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    expect(find.text('Running now'), findsNothing);
    expect(find.text('Completed task review'), findsNothing);
  });

  testWidgets(
      'Phase 20 — Conditional Home composition renders only active sections (User A: For You + Running Now)',
      (tester) async {
    const activeRun = AxRun(
      id: 'run-1',
      status: RunStatus.running,
      objective: 'Optimizing database queries',
      taskCount: 4,
      completedTaskCount: 2,
      openFindingCount: 0,
      verifiedCriterionCount: 1,
      criterionCount: 4,
    );

    const testAttentionItem = AxHomeAttentionItem(
      id: 'att-1',
      type: AxHomeAttentionType.workspaceProblem,
      title: 'MacBook Pro is disconnected',
      description: 'MacBook Pro workspace disconnected',
      actionLabel: 'Reconnect →',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          projects: const [project],
          workspaces: const [],
          workers: const [],
          invitations: const [],
          attentionItems: const [testAttentionItem],
          continueWorkItems: const [],
          productUpdates: const [
            AxProductUpdate(
              id: 'update-draft',
              slug: 'draft-feature',
              title: 'Draft Feature',
              summary: 'Not yet visible to users',
              publishedAt: '2026-10-08T00:00:00Z',
              status: AxProductUpdateStatus.draft,
            ),
          ],
          productUpdateReadStates: const {},
          aiUpdates: const [
            AxAiCapabilityUpdate(
              id: 'ai-claude-inaccessible',
              workerProfileId: 'claude-unassigned',
              provider: 'anthropic',
              type: AxAiCapabilityUpdateType.modelAdded,
              title: 'Claude 3.7 Sonnet',
              summary: 'Claude model upgrade for Anthropic users',
              publishedAt: '2026-10-08T00:00:00Z',
            ),
          ],
          run: activeRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenProject: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    // Section 1: For You - present
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('Workspace offline'), findsOneWidget);

    // Section 2: Running Now - present
    expect(find.text('Running now'), findsOneWidget);
    expect(find.text('Optimizing database queries'), findsOneWidget);

    // Section 3: Continue Working - present (fallback derived from project)
    expect(find.text('Continue working'), findsOneWidget);

    // Section 4: What's New - omitted (only draft update)
    expect(find.text("What's new"), findsNothing);

    // Section 5: AI Updates - omitted (claude-unassigned not accessible to user)
    expect(find.text('AI updates'), findsNothing);
  });

  testWidgets(
      'Phase 20 — Conditional Home composition renders only active sections (User B: Continue Working + What\'s New + AI Updates)',
      (tester) async {
    const testWorker = AxWorker(
      id: 'worker-chatgpt',
      workspaceId: 'ws-macbook',
      workspaceName: 'Local Workspace',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
      capabilities: ['chat', 'work'],
    );

    const testPublishedUpdate = AxProductUpdate(
      id: 'update-collab',
      slug: 'realtime-collab',
      title: 'Real-time Collaboration',
      summary: 'Collaborate live with teammates.',
      publishedAt: '2026-10-08T00:00:00Z',
      status: AxProductUpdateStatus.published,
    );

    const testAiUpdate = AxAiCapabilityUpdate(
      id: 'ai-chatgpt-o3',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      title: 'OpenAI o3-mini model',
      summary: 'High-speed reasoning model available.',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          projects: const [project],
          workspaces: const [],
          workers: const [testWorker],
          invitations: const [],
          attentionItems: const [],
          continueWorkItems: const [],
          productUpdates: const [testPublishedUpdate],
          productUpdateReadStates: const {},
          aiUpdates: const [testAiUpdate],
          run: null, // No active executions
          openFindingCount: 0, // No attention items
          onOpenWorkspaces: () {},
          onOpenProject: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    // Section 1: For You - omitted
    expect(find.text('For you'), findsNothing);

    // Section 2: Running Now - omitted
    expect(find.text('Running now'), findsNothing);

    // Section 3: Continue Working - present
    expect(find.text('Continue working'), findsOneWidget);

    // Section 4: What's New - present
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Real-time Collaboration'), findsOneWidget);

    // Section 5: AI Updates - present
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('OpenAI o3-mini model'), findsOneWidget);
  });

  testWidgets(
      'Phase 21 — Establish visual hierarchy renders sections in canonical order with For You strongest',
      (tester) async {
    const activeRun = AxRun(
      id: 'run-urgent',
      status: RunStatus.running,
      objective: 'Generating security audit report',
      taskCount: 3,
      completedTaskCount: 1,
      openFindingCount: 0,
      verifiedCriterionCount: 1,
      criterionCount: 3,
    );

    const urgentAttentionItem = AxHomeAttentionItem(
      id: 'att-approval',
      type: AxHomeAttentionType.approvalRequired,
      title: 'Production deployment approval',
      description: 'Review pending changes before deployment',
      actionLabel: 'Approve →',
    );

    const testWorker = AxWorker(
      id: 'worker-chatgpt',
      workspaceId: 'ws-main',
      workspaceName: 'Local Workspace',
      workerTypeId: 'chatgpt',
      displayName: 'ChatGPT Worker',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
      capabilities: ['chat', 'work'],
    );

    const testPublishedUpdate = AxProductUpdate(
      id: 'update-sec',
      slug: 'security-audit',
      title: 'Enhanced Tool Isolation',
      summary: 'Strict process containment for CLI tools.',
      publishedAt: '2026-10-08T00:00:00Z',
      status: AxProductUpdateStatus.published,
    );

    const testAiUpdate = AxAiCapabilityUpdate(
      id: 'ai-gpt-reasoning',
      workerProfileId: 'chatgpt',
      provider: 'openai',
      type: AxAiCapabilityUpdateType.modelAdded,
      title: 'GPT-4o Reasoning',
      summary: 'Deep reasoning model for complex code.',
      publishedAt: '2026-10-08T00:00:00Z',
    );

    await tester.pumpWidget(
      scaffold(
        EstablishedUserHome(
          projects: const [project],
          workspaces: const [],
          workers: const [testWorker],
          invitations: const [],
          attentionItems: const [urgentAttentionItem],
          continueWorkItems: const [],
          productUpdates: const [testPublishedUpdate],
          productUpdateReadStates: const {},
          aiUpdates: const [testAiUpdate],
          run: activeRun,
          openFindingCount: 0,
          onOpenWorkspaces: () {},
          onOpenProject: (_) {},
          onOpenRun: (_, __) {},
        ),
      ),
    );

    // 1. For You is rendered at the top (strongest visual weight)
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('Production deployment approval'), findsOneWidget);
    expect(find.text('Approve →'), findsOneWidget);

    // 2. Running Now is present directly below For You
    expect(find.text('Running now'), findsOneWidget);
    expect(find.text('Generating security audit report'), findsOneWidget);

    // 3. Continue Working is present as primary daily activity
    expect(find.text('Continue working'), findsOneWidget);

    // 4. What's New is rendered below Continue Working as secondary editorial content
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Enhanced Tool Isolation'), findsOneWidget);

    // 5. AI Updates is rendered as secondary capability discovery
    expect(find.text('AI updates'), findsOneWidget);
    expect(find.text('GPT-4o Reasoning'), findsOneWidget);

    // Verify ordering in widget tree: For you appears before Running now, before Continue working, before What's new, before AI updates
    final forYouPos = tester.getTopLeft(find.text('For you')).dy;
    final runningNowPos = tester.getTopLeft(find.text('Running now')).dy;
    final continueWorkPos = tester.getTopLeft(find.text('Continue working')).dy;
    final whatsNewPos = tester.getTopLeft(find.text("What's new")).dy;
    final aiUpdatesPos = tester.getTopLeft(find.text('AI updates')).dy;

    expect(forYouPos < runningNowPos, isTrue);
    expect(runningNowPos < continueWorkPos, isTrue);
    expect(continueWorkPos < whatsNewPos, isTrue);
    expect(whatsNewPos < aiUpdatesPos, isTrue);
  });
}

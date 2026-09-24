import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/navigation/studio_shell_context.dart';
import 'package:conclave_app/src/features/navigation/studio_sidebar.dart';
import 'package:conclave_app/src/features/navigation/studio_top_bar.dart';
import 'package:conclave_app/src/navigation/studio_navigation.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

void main() {
  group('StudioShellContext and isNavActive', () {
    test('isNavActive correctly isolates Home from projects and workstreams', () {
      const homeContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [],
      );
      expect(homeContext.isNavActive(const StudioNavigation.home()), isTrue);
      expect(homeContext.isNavActive(const StudioNavigation.projects()), isFalse);
      expect(homeContext.isNavActive(const StudioNavigation.hosts()), isFalse);

      const projectContext = StudioShellContext(
        navigation: StudioNavigation.project('project-1'),
        projects: [],
      );
      // Home must NOT be active when on a project page
      expect(projectContext.isNavActive(const StudioNavigation.home()), isFalse);
      expect(
          projectContext.isNavActive(const StudioNavigation.project('project-1')),
          isTrue);
      expect(
          projectContext.isNavActive(const StudioNavigation.project('project-2')),
          isFalse);
      expect(
          projectContext.isNavActive(const StudioNavigation.projects()),
          isTrue);

      const workstreamContext = StudioShellContext(
        navigation: StudioNavigation.workstream('project-1', 'ws-1'),
        projects: [],
      );
      // Home must NOT be active when on a workstream page
      expect(workstreamContext.isNavActive(const StudioNavigation.home()), isFalse);
      expect(
          workstreamContext
              .isNavActive(const StudioNavigation.project('project-1')),
          isTrue);
      expect(
          workstreamContext.isNavActive(const StudioNavigation.projects()),
          isTrue);
    });

    test('isNavActive covers every route kind accurately', () {
      // Projects section active for projects, project, workstream, run, chat
      const routesInProjects = [
        StudioNavigation.projects(),
        StudioNavigation.project('p-1'),
        StudioNavigation.workstream('p-1', 'ws-1'),
        StudioNavigation.run('p-1', 'r-1'),
        StudioNavigation.chat('p-1', 'c-1'),
      ];

      for (final nav in routesInProjects) {
        final ctx = StudioShellContext(navigation: nav, projects: const []);
        expect(
          ctx.isNavActive(const StudioNavigation.projects()),
          isTrue,
          reason: '$nav should activate Projects group',
        );
        expect(
          ctx.isNavActive(const StudioNavigation.home()),
          isFalse,
          reason: '$nav should NOT activate Home',
        );
        expect(
          ctx.isNavActive(const StudioNavigation.hosts()),
          isFalse,
          reason: '$nav should NOT activate Workspaces',
        );
      }

      // Workspaces route
      const hostsCtx = StudioShellContext(
        navigation: StudioNavigation.hosts(),
        projects: [],
      );
      expect(hostsCtx.isNavActive(const StudioNavigation.hosts()), isTrue);
      expect(hostsCtx.isNavActive(const StudioNavigation.projects()), isFalse);
      expect(hostsCtx.isNavActive(const StudioNavigation.home()), isFalse);

      // Workers route
      const workersCtx = StudioShellContext(
        navigation: StudioNavigation.workers(),
        projects: [],
      );
      expect(workersCtx.isNavActive(const StudioNavigation.workers()), isTrue);
      expect(workersCtx.isNavActive(const StudioNavigation.hosts()), isFalse);
      expect(workersCtx.isNavActive(const StudioNavigation.home()), isFalse);

      // AI Accounts route
      const accountsCtx = StudioShellContext(
        navigation: StudioNavigation.accounts(),
        projects: [],
      );
      expect(accountsCtx.isNavActive(const StudioNavigation.accounts()), isTrue);
      expect(accountsCtx.isNavActive(const StudioNavigation.projects()), isFalse);

      // Usage route
      const usageCtx = StudioShellContext(
        navigation: StudioNavigation.usage(),
        projects: [],
      );
      expect(usageCtx.isNavActive(const StudioNavigation.usage()), isTrue);
      expect(usageCtx.isNavActive(const StudioNavigation.home()), isFalse);

      // Profile & Security route
      const profileCtx = StudioShellContext(
        navigation: StudioNavigation.profileSecurity(),
        projects: [],
      );
      expect(profileCtx.isNavActive(const StudioNavigation.profileSecurity()),
          isTrue);
      expect(profileCtx.isNavActive(const StudioNavigation.home()), isFalse);
      expect(profileCtx.isNavActive(const StudioNavigation.projects()), isFalse);
    });
  });

  group('StudioSidebar Canonical Component', () {
    const testProject = StudioProject(
      id: 'project-1',
      name: 'Conclave AX',
      repository: 'github.com/conclave/ax',
      branch: 'main',
      activeGoals: 0,
      lastActivity: 'today',
      workstreams: [
        StudioWorkstream(
          id: 'ws-1',
          projectId: 'project-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
          currentCheckpoint: 'main',
          queueStatus: 'Running',
        ),
      ],
    );

    testWidgets('renders canonical sidebar hierarchy and triggers callbacks',
        (tester) async {
      StudioNavigation? navigatedTo;
      String? toggledProjectId;
      var createProjectCalled = false;
      StudioProject? createdWorkstreamProject;

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [testProject],
        selectedProject: testProject,
        workspaces: [
          StudioAgent(
            id: 'agent-1',
            name: 'MacBook Pro',
            hostname: 'vitalii-mac',
            status: 'online',
            os: 'macOS',
            architecture: 'arm64',
            version: '0.6.0',
            lastSeen: 'just now',
            workerCount: 2,
            pluginCount: 2,
            activeTaskCount: 1,
            workspaceBindings: [],
          ),
        ],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        expandedProjectIds: {'project-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleProjectExpanded: (id) => toggledProjectId = id,
              onCreateProject: () => createProjectCalled = true,
              onCreateWorkstream: (proj) => createdWorkstreamProject = proj,
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check Header & Main Sections
      expect(find.text('Conclave AX'), findsNWidgets(2)); // Brand & Project
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('PROJECTS'), findsOneWidget);
      expect(find.text('EXECUTION'), findsOneWidget);
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Workers'), findsOneWidget);
      expect(find.text('AI Accounts'), findsOneWidget);
      expect(find.text('INSIGHTS'), findsOneWidget);
      expect(find.text('Usage'), findsOneWidget);

      // Check Project & Workstream tree
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Check Running count badge (1 running workstream) and Workspaces badge (1 workspace)
      expect(find.text('1'), findsNWidgets(2));

      // Check Viewer Initials & Name
      expect(find.text('VN'), findsOneWidget);
      expect(find.text('Vitalii Noha'), findsOneWidget);

      // Tap + button for create menu
      await tester.tap(find.byTooltip('Create...'));
      await tester.pumpAndSettle();
      expect(find.text('New Project'), findsOneWidget);
      expect(find.text('New Workstream'), findsOneWidget);

      // Tap New Project
      await tester.tap(find.text('New Project'));
      await tester.pumpAndSettle();
      expect(createProjectCalled, isTrue);

      // Open menu again and tap New Workstream
      await tester.tap(find.byTooltip('Create...'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Workstream'));
      await tester.pumpAndSettle();
      expect(createdWorkstreamProject?.id, 'project-1');

      // Tap Project row to navigate to /projects/:projectId
      await tester.tap(find.text('Conclave AX').last);
      expect(navigatedTo?.kind, StudioRouteKind.project);
      expect(navigatedTo?.projectId, 'project-1');

      // Tap workstream row
      await tester.tap(find.text('Authentication redesign'));
      expect(navigatedTo?.kind, StudioRouteKind.workstream);
      expect(navigatedTo?.workstreamId, 'ws-1');

      // Tap chevron to toggle expansion
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      expect(toggledProjectId, 'project-1');
    });

    testWidgets('excludes archived workstreams from sidebar list',
        (tester) async {
      const projectWithArchived = StudioProject(
        id: 'project-2',
        name: 'Conclave Core',
        repository: 'github.com/conclave/core',
        branch: 'main',
        activeGoals: 0,
        lastActivity: 'today',
        workstreams: [
          StudioWorkstream(
            id: 'ws-active',
            projectId: 'project-2',
            name: 'Active Workstream',
            lead: 'Vitalii',
            status: 'active',
            brief: 'Active task',
            primaryWorkspace: 'MacBook Pro',
            currentCheckpoint: 'main',
            queueStatus: 'Idle',
          ),
          StudioWorkstream(
            id: 'ws-archived',
            projectId: 'project-2',
            name: 'Old Archived Workstream',
            lead: 'Vitalii',
            status: 'archived',
            brief: 'Archived task',
            primaryWorkspace: 'MacBook Pro',
            currentCheckpoint: 'main',
            queueStatus: 'Done',
          ),
        ],
      );

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [projectWithArchived],
        expandedProjectIds: {'project-2'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleProjectExpanded: (_) {},
              onCreateProject: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Active Workstream'), findsOneWidget);
      expect(find.text('Old Archived Workstream'), findsNothing);
    });
  });

  group('StudioTopBar Canonical Component', () {
    const testProject = StudioProject(
      id: 'project-1',
      name: 'Conclave AX',
      repository: 'github.com/conclave/ax',
      branch: 'main',
      activeGoals: 0,
      lastActivity: 'today',
      workstreams: [
        StudioWorkstream(
          id: 'ws-1',
          projectId: 'project-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
          currentCheckpoint: 'main',
          queueStatus: 'Running',
        ),
      ],
    );

    testWidgets('renders breadcrumbs, search affordance, and workspace status',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      StudioNavigation? navigatedTo;
      var commandPaletteOpened = false;

      final shellContext = StudioShellContext(
        navigation: const StudioNavigation.workstream('project-1', 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
        workspaces: const [
          StudioAgent(
            id: 'agent-1',
            name: 'MacBook Pro',
            hostname: 'vitalii-mac',
            status: 'online',
            os: 'macOS',
            architecture: 'arm64',
            version: '0.6.0',
            lastSeen: 'just now',
            workerCount: 2,
            pluginCount: 2,
            activeTaskCount: 1,
            workspaceBindings: [],
          ),
        ],
        unreadNotificationCount: 3,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () => commandPaletteOpened = true,
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check Breadcrumbs: Projects / Conclave AX / Authentication redesign
      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('Conclave AX'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Check Search affordance
      expect(find.text('Search or jump to...'), findsOneWidget);
      expect(find.text('⌘K'), findsOneWidget);

      // Check Workspace status button
      expect(find.text('MacBook Pro · Online'), findsOneWidget);

      // Check Notification badge
      expect(find.text('3'), findsOneWidget);

      // Click Projects in breadcrumb
      await tester.tap(find.text('Projects'));
      expect(navigatedTo?.kind, StudioRouteKind.projects);

      // Click Search affordance
      await tester.tap(find.text('Search or jump to...'));
      expect(commandPaletteOpened, isTrue);
    });
  });
}

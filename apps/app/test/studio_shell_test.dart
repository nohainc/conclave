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
      expect(workersCtx.isNavActive(const StudioNavigation.hosts()), isTrue);
      expect(workersCtx.isNavActive(const StudioNavigation.home()), isFalse);

      // AI Accounts route
      const accountsCtx = StudioShellContext(
        navigation: StudioNavigation.accounts(),
        projects: [],
      );
      expect(accountsCtx.isNavActive(const StudioNavigation.accounts()), isTrue);
      expect(accountsCtx.isNavActive(const StudioNavigation.hosts()), isTrue);
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
      expect(find.text('Home'), findsNothing);
      expect(find.text('Projects'), findsNothing);
      expect(find.text('PROJECTS'), findsOneWidget);

      // Tapping Conclave AX brand navigates to Home
      await tester.tap(find.text('Conclave AX').first);
      expect(navigatedTo?.kind, StudioRouteKind.home);
      navigatedTo = null;

      // Infrequent execution and insights configuration are removed from permanent sidebar
      expect(find.text('EXECUTION'), findsNothing);
      expect(find.text('Workers'), findsNothing);
      expect(find.text('AI Accounts'), findsNothing);
      expect(find.text('INSIGHTS'), findsNothing);

      // Check Project & Workstream tree
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Check Viewer Initials & Name button
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

      // Tap User Profile Button at bottom of sidebar -> navigates to /settings/profile
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo?.kind, StudioRouteKind.profileSecurity);

      // Tap ⋯ Application menu at bottom of sidebar
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Usage'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Website'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);

      // Tap Workspaces in Application menu
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, StudioRouteKind.hosts);
    });

    testWidgets('Phase 2: bottom user/profile control and separate ⋯ menu hit target',
        (tester) async {
      StudioNavigation? navigatedTo;

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [testProject],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
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

      // 1. Tapping the avatar specifically navigates to /settings/profile and does not open menu
      await tester.tap(find.text('VN'));
      expect(navigatedTo?.kind, StudioRouteKind.profileSecurity);
      expect(find.text('Workspaces'), findsNothing);

      // Reset
      navigatedTo = null;

      // 2. Tapping the user name specifically navigates to /settings/profile and does not open menu
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo?.kind, StudioRouteKind.profileSecurity);
      expect(find.text('Workspaces'), findsNothing);

      // Reset
      navigatedTo = null;

      // 3. Tapping the ⋯ button specifically opens the Application Menu and does NOT navigate to profile
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(navigatedTo, isNull);
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Usage'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Website'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
    });

    testWidgets(
        'Phase 3: Global application menu actions (destinations, appearance submenu, product info, session logout)',
        (tester) async {
      StudioNavigation? navigatedTo;
      ThemeMode? selectedThemeMode;
      var logoutTriggered = false;
      var aboutTriggered = false;
      Uri? openedExternalUri;

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [testProject],
        themeMode: ThemeMode.system,
        viewerDisplayName: 'Vitalii Noha',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleProjectExpanded: (_) {},
              onCreateProject: () {},
              onSetThemeMode: (mode) => selectedThemeMode = mode,
              onLogout: () => logoutTriggered = true,
              onOpenAbout: () => aboutTriggered = true,
              onOpenExternal: (uri) => openedExternalUri = uri,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open menu in sidebar
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Test 1: Usage destination
      await tester.tap(find.text('Usage'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, StudioRouteKind.usage);

      // Re-open menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Test 2: Appearance Submenu
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);

      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(selectedThemeMode, ThemeMode.dark);

      // Re-open menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Test 3: About Conclave AX
      await tester.tap(find.text('About Conclave AX'));
      await tester.pumpAndSettle();
      expect(aboutTriggered, isTrue);

      // Re-open menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Test 4: Website
      await tester.tap(find.text('Website'));
      await tester.pumpAndSettle();
      expect(openedExternalUri, Uri.parse('https://conclaveax.com'));

      // Re-open menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Test 5: Log out
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(logoutTriggered, isTrue);
    });

    testWidgets(
        'Phase 3: StudioIconRail includes global application menu with destinations and actions',
        (tester) async {
      StudioNavigation? navigatedTo;
      ThemeMode? selectedThemeMode;
      var logoutTriggered = false;
      var aboutTriggered = false;
      Uri? openedExternalUri;
      var drawerOpened = false;

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [testProject],
        themeMode: ThemeMode.light,
        viewerDisplayName: 'Vitalii Noha',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.lightTheme(),
          home: Scaffold(
            body: StudioIconRail(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenDrawer: () => drawerOpened = true,
              onSetThemeMode: (mode) => selectedThemeMode = mode,
              onLogout: () => logoutTriggered = true,
              onOpenAbout: () => aboutTriggered = true,
              onOpenExternal: (uri) => openedExternalUri = uri,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open menu in rail
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Check items exist
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Usage'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Website'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);

      // Click Workspaces
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, StudioRouteKind.hosts);

      // Reopen and check Appearance -> System
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(selectedThemeMode, ThemeMode.system);

      // Reopen and check About Conclave AX
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Conclave AX'));
      await tester.pumpAndSettle();
      expect(aboutTriggered, isTrue);

      // Reopen and check Website
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Website'));
      await tester.pumpAndSettle();
      expect(openedExternalUri, Uri.parse('https://conclaveax.com'));

      // Reopen and check Log out
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(logoutTriggered, isTrue);

      // Tap drawer button in rail
      await tester.tap(find.byTooltip('Open project tree & menu'));
      expect(drawerOpened, isTrue);
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
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

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

      // Check Breadcrumbs: Conclave AX / Authentication redesign
      expect(find.text('Conclave AX'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Check Search affordance (desktop)
      expect(find.text('Search or jump to...'), findsOneWidget);
      expect(find.text('⌘K'), findsOneWidget);

      // Check Workspace status button
      expect(find.text('MacBook Pro · Online'), findsOneWidget);

      // Check Notification badge
      expect(find.text('3'), findsOneWidget);

      // Low-value controls (theme toggle & about) must NOT be in the permanent top HUD
      expect(find.byTooltip('Switch to light mode'), findsNothing);
      expect(find.byTooltip('Switch to dark mode'), findsNothing);
      expect(find.text('About'), findsNothing);

      // Click Project in breadcrumb
      await tester.tap(find.text('Conclave AX'));
      expect(navigatedTo?.kind, StudioRouteKind.project);
      expect(navigatedTo?.projectId, 'project-1');

      // Click Search affordance
      await tester.tap(find.text('Search or jump to...'));
      expect(commandPaletteOpened, isTrue);
    });

    testWidgets('mobile/compact HUD renders account avatar and opens account menu',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      var themeToggled = false;
      var aboutOpened = false;
      var logoutCalled = false;
      StudioNavigation? navigatedTo;

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [testProject],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        isDarkTheme: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onOpenNotifications: () {},
              onToggleTheme: () => themeToggled = true,
              onOpenAbout: () => aboutOpened = true,
              onLogout: () => logoutCalled = true,
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check initials avatar in compact HUD
      expect(find.text('VN'), findsOneWidget);

      // Tap Account menu avatar
      await tester.tap(find.byTooltip('Account menu'));
      await tester.pumpAndSettle();

      // Verify Account Menu contents
      expect(find.text('Vitalii Noha'), findsOneWidget);
      expect(find.text('Switch to light mode'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);

      // Tap Switch to light mode
      await tester.tap(find.text('Switch to light mode'));
      await tester.pumpAndSettle();
      expect(themeToggled, isTrue);

      // Open menu again and tap About
      await tester.tap(find.byTooltip('Account menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Conclave AX'));
      await tester.pumpAndSettle();
      expect(aboutOpened, isTrue);

      // Open menu again and tap Profile
      await tester.tap(find.byTooltip('Account menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vitalii Noha'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, StudioRouteKind.profileSecurity);

      // Open menu again and tap Logout
      await tester.tap(find.byTooltip('Account menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(logoutCalled, isTrue);
    });

    testWidgets('renders Run breadcrumbs: Project / Workstream / Run',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      StudioNavigation? navigatedTo;

      final shellContext = StudioShellContext(
        navigation: const StudioNavigation.run('project-1', 'run-1',
            workstreamId: 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
        selectedRun: const StudioRun(
          id: 'run-1',
          workstreamId: 'ws-1',
          status: RunStatus.running,
          objective: 'Run test objective',
          taskCount: 2,
          completedTaskCount: 1,
          openFindingCount: 0,
          verifiedCriterionCount: 1,
          criterionCount: 2,
          tokens: 500,
          costMicros: 1000,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Conclave AX'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);

      // Click Workstream link in breadcrumb
      await tester.tap(find.text('Authentication redesign'));
      expect(navigatedTo?.kind, StudioRouteKind.workstream);
      expect(navigatedTo?.projectId, 'project-1');
      expect(navigatedTo?.workstreamId, 'ws-1');
    });

    testWidgets('compact HUD prioritizes leaf entity in breadcrumbs for workstream',
        (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      StudioNavigation? navigatedTo;

      final shellContext = StudioShellContext(
        navigation: const StudioNavigation.workstream('project-1', 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In compact mode, parent project 'Conclave AX' is replaced with '…'
      expect(find.text('Conclave AX'), findsNothing);
      expect(find.text('…'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Tapping '…' navigates back to the parent Project
      await tester.tap(find.text('…'));
      expect(navigatedTo?.kind, StudioRouteKind.project);
      expect(navigatedTo?.projectId, 'project-1');
    });

    testWidgets('renders nested breadcrumbs for Workers and AI Accounts',
        (tester) async {
      StudioNavigation? navigatedTo;

      const workersContext = StudioShellContext(
        navigation: StudioNavigation.workers(),
        projects: [testProject],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: workersContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onOpenNotifications: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Workers'), findsOneWidget);

      await tester.tap(find.text('Workspaces'));
      expect(navigatedTo?.kind, StudioRouteKind.hosts);

      navigatedTo = null;
      const accountsContext = StudioShellContext(
        navigation: StudioNavigation.accounts(),
        projects: [testProject],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: accountsContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onOpenNotifications: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('AI Accounts'), findsOneWidget);

      await tester.tap(find.text('Workspaces'));
      expect(navigatedTo?.kind, StudioRouteKind.hosts);
    });

    testWidgets('compact HUD prioritizes leaf entity in breadcrumbs for run',
        (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      StudioNavigation? navigatedTo;

      final shellContext = StudioShellContext(
        navigation: const StudioNavigation.run('project-1', 'run-1',
            workstreamId: 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
        selectedRun: const StudioRun(
          id: 'run-1',
          workstreamId: 'ws-1',
          status: RunStatus.running,
          objective: 'Run test objective',
          taskCount: 2,
          completedTaskCount: 1,
          openFindingCount: 0,
          verifiedCriterionCount: 1,
          criterionCount: 2,
          tokens: 500,
          costMicros: 1000,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // In compact mode, parent 'Authentication redesign' is collapsed to '…' while 'Run' remains
      expect(find.text('Authentication redesign'), findsNothing);
      expect(find.text('…'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);

      // Tapping '…' navigates to parent Workstream
      await tester.tap(find.text('…'));
      expect(navigatedTo?.kind, StudioRouteKind.workstream);
      expect(navigatedTo?.projectId, 'project-1');
      expect(navigatedTo?.workstreamId, 'ws-1');
    });

    testWidgets('StudioIconRail has 64px width and renders navigation icons',
        (tester) async {
      StudioNavigation? navigatedTo;
      var drawerOpened = false;

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [testProject],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 64,
              child: StudioIconRail(
                shellContext: shellContext,
                onNavigateTo: (nav) => navigatedTo = nav,
                onOpenDrawer: () => drawerOpened = true,
                onToggleTheme: () {},
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Conclave AX — Home'), findsOneWidget);
      expect(find.byTooltip('Open project tree & menu'), findsOneWidget);
      expect(find.byTooltip('Vitalii Noha'), findsOneWidget);
      expect(find.byTooltip('Application menu'), findsOneWidget);

      // Tapping Conclave AX brand icon navigates to home
      await tester.tap(find.byTooltip('Conclave AX — Home'));
      expect(navigatedTo?.kind, StudioRouteKind.home);

      // Tapping Open project tree & menu opens drawer
      await tester.tap(find.byTooltip('Open project tree & menu'));
      expect(drawerOpened, isTrue);

      // Tapping Profile avatar button navigates to profile
      await tester.tap(find.byTooltip('Vitalii Noha'));
      expect(navigatedTo?.kind, StudioRouteKind.profileSecurity);

      // Tapping Application menu opens menu with Workspaces
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Usage'), findsOneWidget);
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, StudioRouteKind.hosts);
    });

    testWidgets('Execution status popover opens and displays workspaces and workers',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      StudioNavigation? navigatedTo;

      const macBook = StudioAgent(
        id: 'agent-1',
        name: 'MacBook Pro',
        hostname: 'vitalii-mac',
        status: 'online',
        os: 'macOS',
        architecture: 'arm64',
        version: '0.6.0',
        lastSeen: 'just now',
        workerCount: 4,
        pluginCount: 2,
        activeTaskCount: 1,
        workspaceBindings: [],
      );

      const buildServer = StudioAgent(
        id: 'agent-2',
        name: 'Build Server',
        hostname: 'build-srv',
        status: 'online',
        os: 'Linux',
        architecture: 'x64',
        version: '0.6.0',
        lastSeen: 'just now',
        workerCount: 6,
        pluginCount: 3,
        activeTaskCount: 0,
        workspaceBindings: [],
      );

      const officeMac = StudioAgent(
        id: 'agent-3',
        name: 'Office Mac',
        hostname: 'office-mac',
        status: 'offline',
        os: 'macOS',
        architecture: 'arm64',
        version: '0.6.0',
        lastSeen: '2 hours ago',
        workerCount: 0,
        pluginCount: 0,
        activeTaskCount: 0,
        workspaceBindings: [],
      );

      // 1. Global context test: "2 / 3 Workspaces online"
      const globalContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [],
        workspaces: [macBook, buildServer, officeMac],
      );

      expect(globalContext.executionStatusLabel, '2 / 3 Workspaces online');
      expect(globalContext.executionStatusTone, ExecutionStatusTone.usable);

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: globalContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 / 3 Workspaces online'), findsOneWidget);

      // Tap execution status trigger to open popover
      await tester.tap(find.text('2 / 3 Workspaces online'));
      await tester.pumpAndSettle();

      // Check Popover content
      expect(find.text('Execution'), findsOneWidget);
      expect(find.text('2 / 3 Online'), findsOneWidget);
      expect(find.text('MacBook Pro'), findsOneWidget);
      expect(find.text('4 Workers ready'), findsOneWidget);
      expect(find.text('Build Server'), findsOneWidget);
      expect(find.text('6 Workers ready'), findsOneWidget);
      expect(find.text('Office Mac'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);

      // Tap Manage Workspaces in popover footer
      await tester.tap(find.text('Manage Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, StudioRouteKind.hosts);
    });

    test('StudioShellContext derives correct tone and label across states', () {
      const macBook = StudioAgent(
        id: 'agent-1',
        name: 'MacBook Pro',
        hostname: 'vitalii-mac',
        status: 'online',
        os: 'macOS',
        architecture: 'arm64',
        version: '0.6.0',
        lastSeen: 'just now',
        workerCount: 4,
        pluginCount: 2,
        activeTaskCount: 1,
        workspaceBindings: [],
      );
      const officeMacOffline = StudioAgent(
        id: 'agent-3',
        name: 'Office Mac',
        hostname: 'office-mac',
        status: 'offline',
        os: 'macOS',
        architecture: 'arm64',
        version: '0.6.0',
        lastSeen: 'yesterday',
        workerCount: 0,
        pluginCount: 0,
        activeTaskCount: 0,
        workspaceBindings: [],
      );

      // Workstream context: targeted workspace online
      const wsCtxOnline = StudioShellContext(
        navigation: StudioNavigation.workstream('project-1', 'ws-1'),
        projects: [],
        selectedWorkstream: StudioWorkstream(
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
        workspaces: [macBook, officeMacOffline],
      );
      expect(wsCtxOnline.executionStatusLabel, 'MacBook Pro · Online');
      expect(wsCtxOnline.executionStatusTone, ExecutionStatusTone.usable);

      // Workstream context: targeted workspace offline
      const wsCtxOffline = StudioShellContext(
        navigation: StudioNavigation.workstream('project-1', 'ws-2'),
        projects: [],
        selectedWorkstream: StudioWorkstream(
          id: 'ws-2',
          projectId: 'project-1',
          name: 'Core refactor',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Refactoring core',
          primaryWorkspace: 'Office Mac',
          currentCheckpoint: 'main',
          queueStatus: 'Running',
        ),
        workspaces: [macBook, officeMacOffline],
      );
      expect(wsCtxOffline.executionStatusLabel, 'Office Mac · Offline');
      expect(wsCtxOffline.executionStatusTone, ExecutionStatusTone.failed);

      // Reconnecting / stale state
      const staleCtx = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [],
        workspaces: [macBook],
        realtimeStale: true,
      );
      expect(staleCtx.executionStatusTone, ExecutionStatusTone.degraded);

      // Empty workspaces state
      const emptyCtx = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [],
        workspaces: [],
      );
      expect(emptyCtx.executionStatusLabel, 'No Workspaces');
      expect(emptyCtx.executionStatusTone, ExecutionStatusTone.neutral);
    });
  });

  group('Phase 10 — Shell Cleanup, Regressions, and Deep Interactions', () {
    const projectA = StudioProject(
      id: 'p-1',
      name: 'Conclave Core',
      repository: 'github.com/conclave/core',
      branch: 'main',
      activeGoals: 0,
      lastActivity: 'today',
      workstreams: [
        StudioWorkstream(
          id: 'ws-running',
          projectId: 'p-1',
          name: 'Engine optimization',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Optimizing worker loop',
          primaryWorkspace: 'MacBook Pro',
          currentCheckpoint: 'main',
          queueStatus: 'Running',
        ),
        StudioWorkstream(
          id: 'ws-queued',
          projectId: 'p-1',
          name: 'Queue integration',
          lead: 'Vitalii',
          status: 'queued',
          brief: 'Queue worker tasks',
          primaryWorkspace: 'MacBook Pro',
          currentCheckpoint: 'main',
          queueStatus: 'Queued',
        ),
        StudioWorkstream(
          id: 'ws-failed',
          projectId: 'p-1',
          name: 'Buggy patch',
          lead: 'Vitalii',
          status: 'failed',
          brief: 'Failed run',
          primaryWorkspace: 'MacBook Pro',
          currentCheckpoint: 'main',
          queueStatus: 'Failed',
        ),
      ],
    );

    testWidgets('Active sidebar route visual check for all route kinds',
        (tester) async {
      const allRoutes = [
        StudioNavigation.home(),
        StudioNavigation.projects(),
        StudioNavigation.project('p-1'),
        StudioNavigation.workstream('p-1', 'ws-running'),
        StudioNavigation.run('p-1', 'run-1', workstreamId: 'ws-running'),
        StudioNavigation.hosts(),
        StudioNavigation.workers(),
        StudioNavigation.accounts(),
        StudioNavigation.usage(),
        StudioNavigation.profileSecurity(),
      ];

      for (final nav in allRoutes) {
        final ctx = StudioShellContext(
          navigation: nav,
          projects: const [projectA],
          selectedProject: projectA,
          expandedProjectIds: {'p-1'},
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ConclaveBrand.darkTheme(),
            home: Scaffold(
              body: StudioSidebar(
                shellContext: ctx,
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

        // Ensure sidebar renders without error
        expect(find.text('Conclave AX'), findsOneWidget);
      }
    });

    testWidgets('Project click vs chevron click separation and expand/collapse',
        (tester) async {
      StudioNavigation? navigatedTo;
      String? toggledProjectId;

      // 1. Initially collapsed
      const collapsedContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [projectA],
        expandedProjectIds: {},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: collapsedContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleProjectExpanded: (id) => toggledProjectId = id,
              onCreateProject: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Workstreams should not be visible when collapsed
      expect(find.text('Engine optimization'), findsNothing);

      // Tap the project title text -> should navigate to project, NOT toggle expand
      await tester.tap(find.text('Conclave Core'));
      expect(navigatedTo?.kind, StudioRouteKind.project);
      expect(navigatedTo?.projectId, 'p-1');
      expect(toggledProjectId, isNull);

      // Reset
      navigatedTo = null;

      // Tap the chevron icon -> should toggle expand, NOT navigate
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      expect(toggledProjectId, 'p-1');
      expect(navigatedTo, isNull);
    });

    testWidgets('Workstream status dot indicators render for each status',
        (tester) async {
      const expandedContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [projectA],
        expandedProjectIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: expandedContext,
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

      expect(find.text('Engine optimization'), findsOneWidget);
      expect(find.text('Queue integration'), findsOneWidget);
      expect(find.text('Buggy patch'), findsOneWidget);
    });

    testWidgets('Breadcrumb generation and segment navigation across all routes',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      StudioNavigation? navigatedTo;

      // Test 1: Project route -> "Projects / Conclave Core"
      const projectContext = StudioShellContext(
        navigation: StudioNavigation.project('p-1'),
        projects: [projectA],
        selectedProject: projectA,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: projectContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Conclave Core'), findsOneWidget);

      // Test 1b: Workstream route -> "Conclave Core / WS"
      final workstreamContext = StudioShellContext(
        navigation: const StudioNavigation.workstream('p-1', 'ws-1'),
        projects: const [projectA],
        selectedProject: projectA,
        selectedWorkstream: projectA.workstreams.first,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: workstreamContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Conclave Core'), findsOneWidget);
      await tester.tap(find.text('Conclave Core'));
      expect(navigatedTo?.kind, StudioRouteKind.project);

      // Test 2: AI Accounts route -> "AI Accounts"
      navigatedTo = null;
      const accountsContext = StudioShellContext(
        navigation: StudioNavigation.accounts(),
        projects: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: accountsContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('AI Accounts'), findsOneWidget);
    });

    testWidgets('Execution status popover shows degraded/reconnecting and failed status',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const degradedCtx = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [],
        workspaces: [
          StudioAgent(
            id: 'agent-1',
            name: 'Build Server',
            hostname: 'build-srv',
            status: 'offline',
            os: 'Linux',
            architecture: 'x86_64',
            version: '0.6.0',
            lastSeen: '10m ago',
            workerCount: 0,
            pluginCount: 0,
            activeTaskCount: 0,
            workspaceBindings: [],
          ),
        ],
        realtimeStale: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: degradedCtx,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () {},
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('0 / 1 Workspace online'), findsOneWidget);
      expect(degradedCtx.executionStatusTone, ExecutionStatusTone.degraded);

      // Tap to open popover
      await tester.tap(find.text('0 / 1 Workspace online'));
      await tester.pumpAndSettle();

      expect(find.text('Execution'), findsOneWidget);
      expect(find.text('Build Server'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets('Command Palette HUD control responds to click in desktop, tablet, and mobile',
        (tester) async {
      var commandPaletteOpened = false;

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [],
      );

      // 1. Desktop
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () => commandPaletteOpened = true,
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Search or jump to...'));
      expect(commandPaletteOpened, isTrue);

      // 2. Compact / Mobile
      commandPaletteOpened = false;
      tester.view.physicalSize = const Size(450, 800);
      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () => commandPaletteOpened = true,
              onToggleTheme: () {},
              onOpenNotifications: () {},
              onOpenAbout: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search (⌘K)'));
      expect(commandPaletteOpened, isTrue);
    });

    testWidgets('Regression Assertions: shell contains no legacy mental models',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [projectA],
        selectedProject: projectA,
        expandedProjectIds: {'p-1'},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: Row(
              children: [
                StudioSidebar(
                  shellContext: shellContext,
                  onNavigateTo: (_) {},
                  onToggleProjectExpanded: (_) {},
                  onCreateProject: () {},
                  onLogout: () {},
                  onOpenAbout: () {},
                  onOpenExternal: (_) {},
                ),
                Expanded(
                  child: Scaffold(
                    appBar: StudioTopBar(
                      shellContext: shellContext,
                      onNavigateTo: (_) {},
                      onOpenCommandPalette: () {},
                      onToggleTheme: () {},
                      onOpenNotifications: () {},
                      onOpenAbout: () {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Regression checks:
      // 1. No "New chat" button in shell
      expect(find.text('New chat'), findsNothing);

      // 2. No "New goal" button in shell
      expect(find.text('New goal'), findsNothing);

      // 3. No generic "Back to chat" button
      expect(find.text('Back to chat'), findsNothing);

      // 4. HUD heading is "Home" (from route breadcrumb), NOT generic "Workspace"
      expect(find.text('Home'), findsWidgets);
      // "Workspaces" only appears as the nav section item in sidebar, never as HUD title for Home
      expect(find.text('Workspace'), findsNothing);
    });

    testWidgets(
        'Phase 8: Project tree centerpiece with trailing meaningful status dots and contextual create',
        (tester) async {
      StudioProject? createdWorkstreamProject;
      var createProjectCalled = false;

      const project = StudioProject(
        id: 'p-1',
        name: 'Conclave AX',
        repository: 'github.com/conclave/ax',
        branch: 'main',
        activeGoals: 5,
        lastActivity: 'today',
        workstreams: [
          StudioWorkstream(
            id: 'ws-1',
            projectId: 'p-1',
            name: 'Authentication redesign',
            lead: 'Vitalii',
            status: 'running',
            brief: 'Redesign login flow',
            primaryWorkspace: 'MacBook Pro',
            currentCheckpoint: 'main',
            queueStatus: 'Running',
          ),
          StudioWorkstream(
            id: 'ws-2',
            projectId: 'p-1',
            name: 'Landing page',
            lead: 'Vitalii',
            status: 'idle',
            brief: 'Landing page work',
            primaryWorkspace: 'MacBook Pro',
            currentCheckpoint: 'main',
            queueStatus: 'Idle',
          ),
          StudioWorkstream(
            id: 'ws-3',
            projectId: 'p-1',
            name: 'Scheduler',
            lead: 'Vitalii',
            status: 'queued',
            brief: 'Scheduler updates',
            primaryWorkspace: 'MacBook Pro',
            currentCheckpoint: 'main',
            queueStatus: 'Queued',
          ),
        ],
      );

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [project],
        selectedProject: project,
        expandedProjectIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleProjectExpanded: (_) {},
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

      // Project row: name is displayed without activeGoals count '5'
      expect(find.text('Conclave AX'), findsNWidgets(2)); // Brand and Project
      expect(find.text('5'), findsNothing);

      // Workstream rows are rendered
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('Landing page'), findsOneWidget);
      expect(find.text('Scheduler'), findsOneWidget);

      // Verify create menu beside PROJECTS
      await tester.tap(find.byTooltip('Create...'));
      await tester.pumpAndSettle();

      expect(find.text('New Project'), findsOneWidget);
      expect(find.text('New Workstream'), findsOneWidget);

      await tester.tap(find.text('New Workstream'));
      await tester.pumpAndSettle();
      expect(createdWorkstreamProject?.id, 'p-1');

      // Test New Project
      await tester.tap(find.byTooltip('Create...'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Project'));
      await tester.pumpAndSettle();
      expect(createProjectCalled, isTrue);
    });

    testWidgets(
        'Phase 9: Fix Home/Projects active navigation isolation across all routes',
        (tester) async {
      const ws1 = StudioWorkstream(
        id: 'ws-1',
        projectId: 'p-1',
        name: 'Authentication redesign',
        lead: 'Vitalii',
        status: 'running',
        brief: 'Redesign login flow',
        primaryWorkspace: 'MacBook Pro',
        currentCheckpoint: 'main',
        queueStatus: 'Running',
      );

      const project = StudioProject(
        id: 'p-1',
        name: 'Conclave AX',
        repository: 'github.com/conclave/ax',
        branch: 'main',
        activeGoals: 0,
        lastActivity: 'today',
        workstreams: [ws1],
      );

      // 1. On Home route (/)
      const homeCtx = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [project],
        expandedProjectIds: {'p-1'},
      );
      expect(homeCtx.isNavActive(const StudioNavigation.home()), isTrue);
      expect(homeCtx.isNavActive(const StudioNavigation.projects()), isFalse);

      // 2. On Projects list (/projects)
      const projectsCtx = StudioShellContext(
        navigation: StudioNavigation.projects(),
        projects: [project],
        expandedProjectIds: {'p-1'},
      );
      expect(projectsCtx.isNavActive(const StudioNavigation.home()), isFalse);
      expect(projectsCtx.isNavActive(const StudioNavigation.projects()), isTrue);

      // 3. On Project detail (/projects/p-1)
      const projectDetailCtx = StudioShellContext(
        navigation: StudioNavigation.project('p-1'),
        projects: [project],
        selectedProject: project,
        expandedProjectIds: {'p-1'},
      );
      expect(projectDetailCtx.isNavActive(const StudioNavigation.home()), isFalse);
      expect(projectDetailCtx.isNavActive(const StudioNavigation.projects()), isTrue);

      // 4. On Workstream detail (/projects/p-1/workstreams/ws-1)
      const workstreamCtx = StudioShellContext(
        navigation: StudioNavigation.workstream('p-1', 'ws-1'),
        projects: [project],
        selectedProject: project,
        selectedWorkstream: ws1,
        expandedProjectIds: {'p-1'},
      );
      expect(workstreamCtx.isNavActive(const StudioNavigation.home()), isFalse);
      expect(workstreamCtx.isNavActive(const StudioNavigation.projects()), isTrue);

      // 5. On Run detail (/projects/p-1/workstreams/ws-1/runs/r-1)
      const runCtx = StudioShellContext(
        navigation: StudioNavigation.run('p-1', 'r-1', workstreamId: 'ws-1'),
        projects: [project],
        selectedProject: project,
        selectedWorkstream: ws1,
        expandedProjectIds: {'p-1'},
      );
      expect(runCtx.isNavActive(const StudioNavigation.home()), isFalse);
      expect(runCtx.isNavActive(const StudioNavigation.projects()), isTrue);

      // 6. Verify Visual UI: when on Workstream, Workstream item is highlighted, Home is not
      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: StudioSidebar(
              shellContext: workstreamCtx,
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

      // Home container has transparent background, Projects nav is active
      expect(find.text('Authentication redesign'), findsOneWidget);
    });

    testWidgets(
        'Phase 11: Responsive layout adapts across Desktop, Medium (Rail), and Mobile',
        (tester) async {
      const ws = StudioWorkstream(
        id: 'ws-1',
        projectId: 'p-1',
        name: 'Authentication redesign',
        lead: 'Vitalii',
        status: 'running',
        brief: 'Redesign login flow',
        primaryWorkspace: 'MacBook Pro',
        currentCheckpoint: 'main',
        queueStatus: 'Running',
      );

      const project = StudioProject(
        id: 'p-1',
        name: 'Conclave AX',
        repository: 'github.com/conclave/ax',
        branch: 'main',
        activeGoals: 0,
        lastActivity: 'today',
        workstreams: [ws],
      );

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.workstream('p-1', 'ws-1'),
        projects: [project],
        selectedProject: project,
        selectedWorkstream: ws,
        expandedProjectIds: {'p-1'},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      Widget buildAppScaffold() {
        final scaffoldKey = GlobalKey<ScaffoldState>();
        return MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = ConclaveBrand.isDesktop(constraints.maxWidth);
              final isTablet = ConclaveBrand.isTablet(constraints.maxWidth);
              final isMobile = ConclaveBrand.isMobile(constraints.maxWidth);

              return Scaffold(
                key: scaffoldKey,
                drawer: (isTablet || isMobile)
                    ? Drawer(
                        child: StudioSidebar(
                          shellContext: shellContext,
                          onNavigateTo: (_) {},
                          onToggleProjectExpanded: (_) {},
                          onCreateProject: () {},
                          onLogout: () {},
                          onOpenAbout: () {},
                          onOpenExternal: (_) {},
                          compact: true,
                        ),
                      )
                    : null,
                body: Row(
                  children: [
                    if (isDesktop)
                      const SizedBox(
                        width: 248,
                        child: StudioSidebar(
                          shellContext: shellContext,
                          onNavigateTo: _dummyNav,
                          onToggleProjectExpanded: _dummyToggle,
                          onCreateProject: _dummyAction,
                          onLogout: _dummyAction,
                          onOpenAbout: _dummyAction,
                          onOpenExternal: _dummyExternal,
                        ),
                      )
                    else if (isTablet)
                      SizedBox(
                        width: 64,
                        child: StudioIconRail(
                          shellContext: shellContext,
                          onNavigateTo: _dummyNav,
                          onOpenDrawer: () =>
                              scaffoldKey.currentState?.openDrawer(),
                          onLogout: _dummyAction,
                          onOpenAbout: _dummyAction,
                          onOpenExternal: _dummyExternal,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          StudioTopBar(
                            shellContext: shellContext,
                            onNavigateTo: _dummyNav,
                            onOpenCommandPalette: _dummyAction,
                            onOpenNotifications: _dummyAction,
                            compact: isMobile,
                          ),
                          const Expanded(child: SizedBox()),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      }

      // 1. Desktop (>= 800, test at 1000 x 800)
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();

      // Full sidebar visible with project tree
      expect(find.byType(StudioSidebar), findsOneWidget);
      expect(find.byType(StudioIconRail), findsNothing);
      expect(find.text('Authentication redesign'), findsNWidgets(2)); // sidebar + HUD breadcrumb
      expect(find.byTooltip('Open menu'), findsNothing); // No hamburger on desktop

      // 2. Medium / Tablet (400-799, test at 600 x 800)
      tester.view.physicalSize = const Size(600, 800);
      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();

      // Collapsed rail visible, sidebar not on main screen
      expect(find.byType(StudioIconRail), findsOneWidget);
      expect(find.byTooltip('Open project tree & menu'), findsOneWidget);
      expect(find.byTooltip('Open menu'), findsNothing);

      // Open drawer from rail
      await tester.tap(find.byTooltip('Open project tree & menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.text('PROJECTS'), findsOneWidget);

      // Close drawer
      await tester.tap(find.text('Close menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);

      // 3. Mobile (< 400, test at 380 x 800)
      tester.view.physicalSize = const Size(380, 800);
      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();

      // No persistent sidebar or icon rail on screen
      expect(find.byType(StudioSidebar), findsNothing);
      expect(find.byType(StudioIconRail), findsNothing);

      // Hamburger menu button visible in HUD
      expect(find.byTooltip('Open menu'), findsOneWidget);

      // Tap hamburger menu to open drawer with full sidebar
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.byType(StudioSidebar), findsOneWidget);
      expect(find.text('PROJECTS'), findsOneWidget);
    });
  });
}

void _dummyNav(StudioNavigation _) {}
void _dummyToggle(String _) {}
void _dummyAction() {}
void _dummyExternal(Uri _) {}


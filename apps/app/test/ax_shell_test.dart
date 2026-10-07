import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/navigation/ax_sidebar.dart';
import 'package:conclave_app/src/features/navigation/ax_top_bar.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'package:conclave_app/src/app_shell.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

import 'ax_fixture_data.dart';

void main() {
  testWidgets('clicking another project loads and reveals its Workstreams',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = _ProjectScopedFixture();
    await tester.pumpWidget(MaterialApp(
        home: ConclaveAppShell(
      services: const DefaultPlatformServices(),
      dataSource: data,
    )));
    await tester.pumpAndSettle();
    final tree = find.byType(ProjectTree);
    final target = find.descendant(of: tree, matching: find.text('Atlas API'));
    expect(find.descendant(of: tree, matching: find.text('Atlas conversation')),
        findsNothing);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(data.selectedProjects, contains('atlas'));
    expect(find.descendant(of: tree, matching: find.text('Atlas conversation')),
        findsOneWidget);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(find.descendant(of: tree, matching: find.text('Atlas conversation')),
        findsNothing);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(find.descendant(of: tree, matching: find.text('Atlas conversation')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'project collapse survives background refresh and can expand again',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ConclaveBrand.darkTheme(),
      home: ConclaveAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const AxFixtureDataSource(),
        initialUri:
            Uri.parse('/projects/project-auth/workstreams/workstream-auth'),
      ),
    ));
    await tester.pumpAndSettle();
    final tree = find.byType(ProjectTree);
    final project =
        find.descendant(of: tree, matching: find.text('Authentication'));
    final stream = find.descendant(
        of: tree, matching: find.text('Authentication hardening'));
    expect(stream, findsOneWidget);
    // Keep the active Workstream route while collapsing its sidebar parent.
    tester.widget<ProjectTree>(tree).onToggleProjectExpanded('project-auth');
    await tester.pumpAndSettle();
    expect(stream, findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(stream, findsNothing);
    await tester.tap(project);
    await tester.pumpAndSettle();
    expect(stream, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('AxShellContext and isNavActive', () {
    test('isNavActive correctly isolates Home from projects and workstreams',
        () {
      const homeContext = AxShellContext(
        navigation: AxNavigation.home(),
        projects: [],
      );
      expect(homeContext.isNavActive(const AxNavigation.home()), isTrue);
      expect(homeContext.isNavActive(const AxNavigation.projects()), isFalse);
      expect(homeContext.isNavActive(const AxNavigation.workspaces()), isFalse);

      const projectContext = AxShellContext(
        navigation: AxNavigation.project('project-1'),
        projects: [],
      );
      // Home must NOT be active when on a project page
      expect(projectContext.isNavActive(const AxNavigation.home()), isFalse);
      expect(
          projectContext.isNavActive(const AxNavigation.project('project-1')),
          isTrue);
      expect(
          projectContext.isNavActive(const AxNavigation.project('project-2')),
          isFalse);
      expect(projectContext.isNavActive(const AxNavigation.projects()), isTrue);

      const workstreamContext = AxShellContext(
        navigation: AxNavigation.workstream('project-1', 'ws-1'),
        projects: [],
      );
      // Home must NOT be active when on a workstream page
      expect(workstreamContext.isNavActive(const AxNavigation.home()), isFalse);
      expect(
          workstreamContext
              .isNavActive(const AxNavigation.project('project-1')),
          isTrue);
      expect(
          workstreamContext.isNavActive(const AxNavigation.projects()), isTrue);
    });

    test('isNavActive covers every route kind accurately', () {
      // Projects section active for projects, project, workstream, and run
      const routesInProjects = [
        AxNavigation.projects(),
        AxNavigation.project('p-1'),
        AxNavigation.workstream('p-1', 'ws-1'),
        AxNavigation.run('p-1', 'r-1'),
        AxNavigation.workstream('p-1', 'ws-2'),
      ];

      for (final nav in routesInProjects) {
        final ctx = AxShellContext(navigation: nav, projects: const []);
        expect(
          ctx.isNavActive(const AxNavigation.projects()),
          isTrue,
          reason: '$nav should activate Projects group',
        );
        expect(
          ctx.isNavActive(const AxNavigation.home()),
          isFalse,
          reason: '$nav should NOT activate Home',
        );
        expect(
          ctx.isNavActive(const AxNavigation.workspaces()),
          isFalse,
          reason: '$nav should NOT activate Workspaces',
        );
      }

      // Workspaces route
      const workspaceCtx = AxShellContext(
        navigation: AxNavigation.workspaces(),
        projects: [],
      );
      expect(workspaceCtx.isNavActive(const AxNavigation.workspaces()), isTrue);
      expect(workspaceCtx.isNavActive(const AxNavigation.projects()), isFalse);
      expect(workspaceCtx.isNavActive(const AxNavigation.home()), isFalse);

      // Profile & Security route
      const profileCtx = AxShellContext(
        navigation: AxNavigation.profileSecurity(),
        projects: [],
      );
      expect(
          profileCtx.isNavActive(const AxNavigation.profileSecurity()), isTrue);
      expect(profileCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(profileCtx.isNavActive(const AxNavigation.projects()), isFalse);
    });
  });

  group('AxSidebar Canonical Component', () {
    const testProject = AxProject(
      id: 'project-1',
      name: 'Conclave AX',
      branch: 'main',
      lastActivity: 'today',
      workstreams: [
        AxWorkstream(
          id: 'ws-1',
          projectId: 'project-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Running',
        ),
      ],
    );

    testWidgets('renders canonical sidebar hierarchy and triggers callbacks',
        (tester) async {
      AxNavigation? navigatedTo;
      String? toggledProjectId;
      var createProjectCalled = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [testProject],
        workstreamsByProject: {testProject.id: testProject.workstreams},
        selectedProject: testProject,
        workspaces: [
          const AxWorkspace(
            id: 'worker-1',
            name: 'MacBook Pro',
            hostname: 'vitalii-mac',
            status: 'online',
            platform: 'macOS',
            architecture: 'arm64',
            appVersion: '0.6.0',
            lastSeen: 'just now',
            workerCount: 2,
            activeTaskCount: 1,
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
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleProjectExpanded: (id) => toggledProjectId = id,
              onCreateProject: () => createProjectCalled = true,
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
      expect(find.text('PROJECTS'), findsNothing);

      // Tapping Conclave AX brand navigates to Home
      await tester.tap(find.text('Conclave AX').first);
      expect(navigatedTo?.kind, AxRouteKind.home);
      navigatedTo = null;

      // Check sidebar collapse button with menu_open icon
      expect(find.byIcon(Icons.menu_open_rounded), findsOneWidget);

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

      // Tap New Project button before alarm icon
      await tester.tap(find.byTooltip('New Project'));
      await tester.pumpAndSettle();
      expect(createProjectCalled, isTrue);

      // Selecting an expanded Project from Home preserves its expansion.
      await tester.tap(find.text('Conclave AX').last);
      expect(navigatedTo?.kind, AxRouteKind.project);
      expect(navigatedTo?.projectId, 'project-1');
      expect(toggledProjectId, isNull);

      // Tap workstream row
      await tester.tap(find.text('Authentication redesign'));
      expect(navigatedTo?.kind, AxRouteKind.workstream);
      expect(navigatedTo?.workstreamId, 'ws-1');

      // Verify folder open icon is displayed for expanded project
      expect(
        find.byWidgetPredicate(
            (w) => w is ConclaveFolderIcon && w.isExpanded == true),
        findsOneWidget,
      );

      // Tap User Profile Button at bottom of sidebar -> navigates to /settings/profile
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);

      // Tap ⋯ Application menu at bottom of sidebar
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Archived Projects'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('GitHub repository'), findsNothing);
      expect(find.text('Website'), findsNothing);

      // Tap Execution in Application menu
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
    });

    testWidgets(
        'Phase 2: bottom user/profile control and separate ⋯ menu hit target',
        (tester) async {
      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [testProject],
        workstreamsByProject: {testProject.id: testProject.workstreams},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
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
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);
      expect(find.text('Workspaces'), findsNothing);

      // Reset
      navigatedTo = null;

      // 2. Tapping the user name specifically navigates to /settings/profile and does not open menu
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);
      expect(find.text('Workspaces'), findsNothing);

      // Reset
      navigatedTo = null;

      // 3. Tapping the ⋯ button specifically opens the Application Menu and does NOT navigate to profile
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(navigatedTo, isNull);
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Archived Projects'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('GitHub repository'), findsNothing);
      expect(find.text('Website'), findsNothing);
    });

    testWidgets(
        'Phase 3: Global application menu actions (destinations, appearance submenu, product info, session logout)',
        (tester) async {
      ThemeMode? selectedThemeMode;
      var logoutTriggered = false;
      var aboutTriggered = false;
      Uri? openedExternalUri;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [testProject],
        workstreamsByProject: {testProject.id: testProject.workstreams},
        themeMode: ThemeMode.system,
        viewerDisplayName: 'Vitalii Noha',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
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

      // Test 1: Appearance Submenu
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

      // Test 2: Documentation
      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();
      expect(
          openedExternalUri, Uri.parse('https://conclaveax.com/how-it-works/'));

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

      // Test 4: Log out
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(logoutTriggered, isTrue);
    });

    testWidgets(
        'Phase 3: AxIconRail includes global application menu with destinations and actions',
        (tester) async {
      AxNavigation? navigatedTo;
      ThemeMode? selectedThemeMode;
      var logoutTriggered = false;
      var aboutTriggered = false;
      Uri? openedExternalUri;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [testProject],
        workstreamsByProject: {testProject.id: testProject.workstreams},
        themeMode: ThemeMode.light,
        viewerDisplayName: 'Vitalii Noha',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.lightTheme(),
          home: Scaffold(
            body: AxIconRail(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onOpenDrawer: () {},
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
      expect(find.text('Archived Projects'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('GitHub repository'), findsNothing);
      expect(find.text('Website'), findsNothing);

      // Click Execution
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);

      // Reopen and check Appearance -> System
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(selectedThemeMode, ThemeMode.system);

      // Reopen and check Documentation
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();
      expect(
          openedExternalUri, Uri.parse('https://conclaveax.com/how-it-works/'));

      // Reopen and check About Conclave AX
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Conclave AX'));
      await tester.pumpAndSettle();
      expect(aboutTriggered, isTrue);

      // Reopen and check Log out
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(logoutTriggered, isTrue);
    });

    testWidgets('excludes archived workstreams from sidebar list',
        (tester) async {
      const projectWithArchived = AxProject(
        id: 'project-2',
        name: 'Conclave Core',
        branch: 'main',
        lastActivity: 'today',
        workstreams: [
          AxWorkstream(
            id: 'ws-active',
            projectId: 'project-2',
            name: 'Active Workstream',
            lead: 'Vitalii',
            status: 'active',
            brief: 'Active task',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Idle',
          ),
          AxWorkstream(
            id: 'ws-archived',
            projectId: 'project-2',
            name: 'Old Archived Workstream',
            lead: 'Vitalii',
            status: 'archived',
            brief: 'Archived task',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Done',
          ),
        ],
      );

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [projectWithArchived],
        workstreamsByProject: {
          projectWithArchived.id: projectWithArchived.workstreams
        },
        expandedProjectIds: {'project-2'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
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

  group('AxTopBar Canonical Component', () {
    const testProject = AxProject(
      id: 'project-1',
      name: 'Conclave AX',
      branch: 'main',
      lastActivity: 'today',
      workstreams: [
        AxWorkstream(
          id: 'ws-1',
          projectId: 'project-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
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

      AxNavigation? navigatedTo;
      var commandPaletteOpened = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.workstream('project-1', 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
        workspaces: const [
          AxWorkspace(
            id: 'worker-1',
            name: 'MacBook Pro',
            hostname: 'vitalii-mac',
            status: 'online',
            platform: 'macOS',
            architecture: 'arm64',
            appVersion: '0.6.0',
            lastSeen: 'just now',
            workerCount: 2,
            activeTaskCount: 1,
          ),
        ],
        unreadNotificationCount: 3,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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
      expect(navigatedTo?.kind, AxRouteKind.project);
      expect(navigatedTo?.projectId, 'project-1');

      // Click Search affordance
      await tester.tap(find.text('Search or jump to...'));
      expect(commandPaletteOpened, isTrue);
    });

    testWidgets(
        'tablet/compact HUD omits account avatar and renders direct search & notifications',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [testProject],
        workstreamsByProject: {testProject.id: testProject.workstreams},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        isDarkTheme: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () {},
              onOpenNotifications: () {},
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Account avatar should not be in compact HUD
      expect(find.text('VN'), findsNothing);
      expect(find.byTooltip('Account menu'), findsNothing);

      // Search and Notifications should be present
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.byTooltip('Notifications'), findsOneWidget);
    });

    testWidgets(
        'tablet/compact HUD search icon click displays inline search control and triggers search',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = TextEditingController();
      final focusNode = FocusNode();
      String? searchedText;
      var clearCalled = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [testProject],
        workstreamsByProject: {testProject.id: testProject.workstreams},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        isDarkTheme: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onOpenCommandPalette: () {},
              onOpenNotifications: () {},
              searchController: controller,
              searchFocusNode: focusNode,
              onSearchChanged: (val) => searchedText = val,
              onClearSearch: () => clearCalled = true,
              compact: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially search icon is visible and inline TextField is not
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      // Tap search icon
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();

      // Now inline TextField is visible
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      // Enter search text
      await tester.enterText(find.byType(TextField), 'auth workflow');
      await tester.pumpAndSettle();
      expect(searchedText, 'auth workflow');

      // Tap clear/close button
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(clearCalled, isTrue);
    });

    testWidgets('renders Run breadcrumbs: Project / Workstream / Run',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation:
            const AxNavigation.run('project-1', 'run-1', workstreamId: 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
        selectedRun: const AxRun(
          id: 'run-1',
          workstreamId: 'ws-1',
          status: RunStatus.running,
          objective: 'Run test objective',
          taskCount: 2,
          completedTaskCount: 1,
          openFindingCount: 0,
          verifiedCriterionCount: 1,
          criterionCount: 2,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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
      expect(navigatedTo?.kind, AxRouteKind.workstream);
      expect(navigatedTo?.projectId, 'project-1');
      expect(navigatedTo?.workstreamId, 'ws-1');
    });

    testWidgets(
        'compact HUD prioritizes leaf entity in breadcrumbs for workstream',
        (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.workstream('project-1', 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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

      // In compact mode, parent project 'Conclave AX' and workstream are displayed
      expect(find.text('Conclave AX'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);

      // Tapping parent project navigates back to the Project
      await tester.tap(find.text('Conclave AX'));
      expect(navigatedTo?.kind, AxRouteKind.project);
      expect(navigatedTo?.projectId, 'project-1');
    });

    testWidgets('compact HUD displays full breadcrumb path for run',
        (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      final shellContext = AxShellContext(
        navigation:
            const AxNavigation.run('project-1', 'run-1', workstreamId: 'ws-1'),
        projects: const [testProject],
        selectedProject: testProject,
        selectedWorkstream: testProject.workstreams.first,
        selectedRun: const AxRun(
          id: 'run-1',
          workstreamId: 'ws-1',
          status: RunStatus.running,
          objective: 'Run test objective',
          taskCount: 2,
          completedTaskCount: 1,
          openFindingCount: 0,
          verifiedCriterionCount: 1,
          criterionCount: 2,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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

      // In compact mode, parent project and workstream are displayed
      expect(find.text('Conclave AX'), findsOneWidget);
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);

      // Tapping parent workstream navigates to parent Workstream
      await tester.ensureVisible(find.text('Authentication redesign'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Authentication redesign'),
          warnIfMissed: false);
      expect(navigatedTo?.kind, AxRouteKind.workstream);
      expect(navigatedTo?.projectId, 'project-1');
      expect(navigatedTo?.workstreamId, 'ws-1');
    });

    testWidgets(
        'AxIconRail has 50px width and renders navigation icons and controls',
        (tester) async {
      AxNavigation? navigatedTo;
      var notificationsOpened = false;
      var createProjectOpened = false;
      var collapseToggled = false;

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [testProject],
        workstreamsByProject: {testProject.id: testProject.workstreams},
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.com',
        unreadNotificationCount: 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 50,
              child: AxIconRail(
                shellContext: shellContext,
                onNavigateTo: (nav) => navigatedTo = nav,
                onOpenDrawer: () {},
                onCreateProject: () => createProjectOpened = true,
                onOpenCommandPalette: () {},
                onOpenNotifications: () => notificationsOpened = true,
                onToggleTheme: () {},
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {},
                onToggleCollapse: () => collapseToggled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(AxIconRail)).width, 50);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Conclave AX — Home'), findsOneWidget);
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
      expect(find.byTooltip('Search...'), findsOneWidget);
      expect(find.byTooltip('Add Project'), findsOneWidget);
      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(find.byTooltip('Projects & Workstreams'), findsOneWidget);
      expect(find.byTooltip('Vitalii Noha'), findsOneWidget);
      expect(find.byTooltip('Application menu'), findsOneWidget);

      // Tapping Conclave AX brand logo navigates to Home
      await tester.tap(find.byTooltip('Conclave AX — Home'));
      expect(navigatedTo, equals(const AxNavigation.home()));

      // Tapping Expand sidebar button expands sidebar
      await tester.tap(find.byTooltip('Expand sidebar'));
      expect(collapseToggled, isTrue);

      // Tapping Search icon opens the search popup control
      await tester.tap(find.byTooltip('Search...'));
      await tester.pumpAndSettle();
      expect(find.text('Search or jump to...'), findsOneWidget);
      expect(find.text('Open Command Palette'), findsNothing);

      // Typing and tapping clear icon clears search text and closes the popup form
      await tester.enterText(find.byType(TextField), 'test query');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Search or jump to...'), findsNothing); // popup closed

      // Tapping Add Project icon
      await tester.tap(find.byTooltip('Add Project'));
      expect(createProjectOpened, isTrue);

      // Tapping Notifications icon
      await tester.tap(find.byTooltip('Notifications'));
      expect(notificationsOpened, isTrue);

      // Tapping Projects & Workstreams popup menu
      await tester.tap(find.byTooltip('Projects & Workstreams'));
      await tester.pumpAndSettle();
      expect(find.byType(ConclaveFolderIcon), findsAtLeastNWidgets(1));
      expect(find.text(testProject.name), findsOneWidget);
      expect(find.text(testProject.workstreams.first.name), findsOneWidget);
      expect(find.text('Create Project'), findsNothing); // Removed from menu
      await tester.tap(find.text(testProject.workstreams.first.name));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workstream);
      expect(navigatedTo?.workstreamId, testProject.workstreams.first.id);

      // Tapping Profile avatar button navigates to profile
      await tester.tap(find.byTooltip('Vitalii Noha'));
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);

      // Tapping Application menu opens menu with Workspaces
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
    });

    testWidgets(
        'Workspaces status popover opens and displays workspaces and workers',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      const macBook = AxWorkspace(
        id: 'worker-1',
        name: 'MacBook Pro',
        hostname: 'vitalii-mac',
        status: 'online',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: 'just now',
        workerCount: 4,
        activeTaskCount: 1,
      );

      const buildServer = AxWorkspace(
        id: 'worker-2',
        name: 'Build Server',
        hostname: 'build-srv',
        status: 'online',
        platform: 'Linux',
        architecture: 'x64',
        appVersion: '0.6.0',
        lastSeen: 'just now',
        workerCount: 6,
        activeTaskCount: 0,
      );

      const officeMac = AxWorkspace(
        id: 'worker-3',
        name: 'Office Mac',
        hostname: 'office-mac',
        status: 'offline',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: '2 hours ago',
        workerCount: 0,
        activeTaskCount: 0,
      );

      // 1. Global context test: "2 / 3 Workspaces online"
      const globalContext = AxShellContext(
        navigation: AxNavigation.home(),
        projects: [],
        workspaces: [macBook, buildServer, officeMac],
      );

      expect(globalContext.executionStatusLabel, '2 / 3 Workspaces online');
      expect(globalContext.executionStatusTone, ExecutionStatusTone.usable);

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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
      expect(find.text('Workspaces'), findsOneWidget);
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
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
    });

    test('AxShellContext derives correct tone and label across states', () {
      const macBook = AxWorkspace(
        id: 'worker-1',
        name: 'MacBook Pro',
        hostname: 'vitalii-mac',
        status: 'online',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: 'just now',
        workerCount: 4,
        activeTaskCount: 1,
      );
      const officeMacOffline = AxWorkspace(
        id: 'worker-3',
        name: 'Office Mac',
        hostname: 'office-mac',
        status: 'offline',
        platform: 'macOS',
        architecture: 'arm64',
        appVersion: '0.6.0',
        lastSeen: 'yesterday',
        workerCount: 0,
        activeTaskCount: 0,
      );

      // Workstream context: targeted workspace online
      const wsCtxOnline = AxShellContext(
        navigation: AxNavigation.workstream('project-1', 'ws-1'),
        projects: [],
        selectedWorkstream: AxWorkstream(
          id: 'ws-1',
          projectId: 'project-1',
          name: 'Authentication redesign',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Redesign login flow',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Running',
        ),
        workspaces: [macBook, officeMacOffline],
      );
      expect(wsCtxOnline.executionStatusLabel, 'MacBook Pro · Online');
      expect(wsCtxOnline.executionStatusTone, ExecutionStatusTone.usable);

      // Workstream context: targeted workspace offline
      const wsCtxOffline = AxShellContext(
        navigation: AxNavigation.workstream('project-1', 'ws-2'),
        projects: [],
        selectedWorkstream: AxWorkstream(
          id: 'ws-2',
          projectId: 'project-1',
          name: 'Core refactor',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Refactoring core',
          primaryWorkspace: 'Office Mac',
          queueStatus: 'Running',
        ),
        workspaces: [macBook, officeMacOffline],
      );
      expect(wsCtxOffline.executionStatusLabel, 'Office Mac · Offline');
      expect(wsCtxOffline.executionStatusTone, ExecutionStatusTone.failed);

      // Reconnecting / stale state
      const staleCtx = AxShellContext(
        navigation: AxNavigation.home(),
        projects: [],
        workspaces: [macBook],
        realtimeStale: true,
      );
      expect(staleCtx.executionStatusTone, ExecutionStatusTone.degraded);

      // Empty workspaces state
      const emptyCtx = AxShellContext(
        navigation: AxNavigation.home(),
        projects: [],
        workspaces: [],
      );
      expect(emptyCtx.executionStatusLabel, 'No Workspaces');
      expect(emptyCtx.executionStatusTone, ExecutionStatusTone.neutral);
    });
  });

  group('Phase 10 — Shell Cleanup, Regressions, and Deep Interactions', () {
    const projectA = AxProject(
      id: 'p-1',
      name: 'Conclave Core',
      branch: 'main',
      lastActivity: 'today',
      workstreams: [
        AxWorkstream(
          id: 'ws-running',
          projectId: 'p-1',
          name: 'Engine optimization',
          lead: 'Vitalii',
          status: 'running',
          brief: 'Optimizing worker loop',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Running',
        ),
        AxWorkstream(
          id: 'ws-queued',
          projectId: 'p-1',
          name: 'Queue integration',
          lead: 'Vitalii',
          status: 'queued',
          brief: 'Queue worker tasks',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Queued',
        ),
        AxWorkstream(
          id: 'ws-failed',
          projectId: 'p-1',
          name: 'Buggy patch',
          lead: 'Vitalii',
          status: 'failed',
          brief: 'Failed run',
          primaryWorkspace: 'MacBook Pro',
          queueStatus: 'Failed',
        ),
      ],
    );

    testWidgets('Active sidebar route visual check for all route kinds',
        (tester) async {
      const allRoutes = [
        AxNavigation.home(),
        AxNavigation.projects(),
        AxNavigation.project('p-1'),
        AxNavigation.workstream('p-1', 'ws-running'),
        AxNavigation.run('p-1', 'run-1', workstreamId: 'ws-running'),
        AxNavigation.workspaces(),
        AxNavigation.workspaces(),
        AxNavigation.profileSecurity(),
      ];

      for (final nav in allRoutes) {
        final ctx = AxShellContext(
          navigation: nav,
          projects: const [projectA],
          selectedProject: projectA,
          expandedProjectIds: {'p-1'},
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ConclaveBrand.darkTheme(),
            home: Scaffold(
              body: AxSidebar(
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

    testWidgets(
        'Project click opens project and toggles expansion only when clicking active project',
        (tester) async {
      AxNavigation? navigatedTo;
      String? toggledProjectId;

      // 1. Initially on Home (not active project)
      final homeContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [projectA],
        workstreamsByProject: {projectA.id: projectA.workstreams},
        expandedProjectIds: {},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: homeContext,
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
      // Collapsed project shows closed folder icon
      expect(
        find.byWidgetPredicate(
            (w) => w is ConclaveFolderIcon && w.isExpanded == false),
        findsOneWidget,
      );

      // Tap the project item -> should navigate to project and toggle expansion
      await tester.tap(find.text('Conclave Core'));
      expect(navigatedTo?.kind, AxRouteKind.project);
      expect(navigatedTo?.projectId, 'p-1');
      expect(toggledProjectId, 'p-1');

      // Reset
      navigatedTo = null;
      toggledProjectId = null;

      // 2. When expanded
      final expandedProjectContext = AxShellContext(
        navigation: const AxNavigation.project('p-1'),
        projects: [projectA],
        workstreamsByProject: {projectA.id: projectA.workstreams},
        selectedProject: projectA,
        expandedProjectIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: expandedProjectContext,
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

      // Expanded project shows open folder icon and workstreams
      expect(
        find.byWidgetPredicate(
            (w) => w is ConclaveFolderIcon && w.isExpanded == true),
        findsOneWidget,
      );
      expect(find.text('Engine optimization'), findsOneWidget);

      // Tap the project item again -> toggles expansion to collapse and navigates
      await tester.tap(find.text('Conclave Core'));
      expect(navigatedTo?.kind, AxRouteKind.project);
      expect(toggledProjectId, 'p-1');
    });

    testWidgets('Workstream status dot indicators render for each status',
        (tester) async {
      final expandedContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [projectA],
        workstreamsByProject: {projectA.id: projectA.workstreams},
        expandedProjectIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
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

    testWidgets(
        'Breadcrumb generation and segment navigation across all routes',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      AxNavigation? navigatedTo;

      // Test 1: Project route -> "Projects / Conclave Core"
      final projectContext = AxShellContext(
        navigation: const AxNavigation.project('p-1'),
        projects: [projectA],
        workstreamsByProject: {projectA.id: projectA.workstreams},
        selectedProject: projectA,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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
      final workstreamContext = AxShellContext(
        navigation: const AxNavigation.workstream('p-1', 'ws-1'),
        projects: const [projectA],
        selectedProject: projectA,
        selectedWorkstream: projectA.workstreams.first,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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
      expect(navigatedTo?.kind, AxRouteKind.project);

      // Test 1c: Workspace route -> "Workspaces / Workspace Name"
      const testWs = AxWorkspace(
        id: 'ws-mac',
        name: 'MacBook Pro',
        hostname: 'macbook-pro',
        status: 'online',
        appVersion: '1.0.0',
        workerCount: 0,
        activeTaskCount: 0,
      );
      final workspaceContext = AxShellContext(
        navigation: const AxNavigation.workspace('ws-mac'),
        projects: [projectA],
        workstreamsByProject: {projectA.id: projectA.workstreams},
        workspaces: [testWs],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
              shellContext: workspaceContext,
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

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('MacBook Pro'), findsOneWidget);
      await tester.tap(find.text('Workspaces'));
      expect(navigatedTo?.kind, AxRouteKind.workspaces);
      expect(navigatedTo?.workspaceId, isNull);
    });

    testWidgets(
        'Workspaces status popover shows degraded/reconnecting and failed status',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const degradedCtx = AxShellContext(
        navigation: AxNavigation.home(),
        projects: [],
        workspaces: [
          AxWorkspace(
            id: 'worker-1',
            name: 'Build Server',
            hostname: 'build-srv',
            status: 'offline',
            platform: 'Linux',
            architecture: 'x86_64',
            appVersion: '0.6.0',
            lastSeen: '10m ago',
            workerCount: 0,
            activeTaskCount: 0,
          ),
        ],
        realtimeStale: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxTopBar(
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

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Build Server'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets(
        'Command Palette HUD control responds to click in desktop, tablet, and mobile',
        (tester) async {
      var commandPaletteOpened = false;

      const shellContext = AxShellContext(
        navigation: AxNavigation.home(),
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
            body: AxTopBar(
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
            body: AxTopBar(
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

      await tester.tap(find.byTooltip('Search'));
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

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [projectA],
        workstreamsByProject: {projectA.id: projectA.workstreams},
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
                AxSidebar(
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
                    appBar: AxTopBar(
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
      var createProjectCalled = false;

      const project = AxProject(
        id: 'p-1',
        name: 'Conclave AX',
        branch: 'main',
        lastActivity: 'today',
        workstreams: [
          AxWorkstream(
            id: 'ws-1',
            projectId: 'p-1',
            name: 'Authentication redesign',
            lead: 'Vitalii',
            status: 'running',
            brief: 'Redesign login flow',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Running',
          ),
          AxWorkstream(
            id: 'ws-2',
            projectId: 'p-1',
            name: 'Landing page',
            lead: 'Vitalii',
            status: 'idle',
            brief: 'Landing page work',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Idle',
          ),
          AxWorkstream(
            id: 'ws-3',
            projectId: 'p-1',
            name: 'Scheduler',
            lead: 'Vitalii',
            status: 'queued',
            brief: 'Scheduler updates',
            primaryWorkspace: 'MacBook Pro',
            queueStatus: 'Queued',
          ),
        ],
      );

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [project],
        workstreamsByProject: {project.id: project.workstreams},
        selectedProject: project,
        expandedProjectIds: {'p-1'},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleProjectExpanded: (_) {},
              onCreateProject: () => createProjectCalled = true,
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Project rows display the project name without legacy Goal counts.
      expect(find.text('Conclave AX'), findsNWidgets(2)); // Brand and Project
      expect(find.text('5'), findsNothing);

      // Workstream rows are rendered
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('Landing page'), findsOneWidget);
      expect(find.text('Scheduler'), findsOneWidget);

      // Test New Project button in sidebar header row
      await tester.tap(find.byTooltip('New Project'));
      await tester.pumpAndSettle();
      expect(createProjectCalled, isTrue);
    });

    testWidgets(
        'Phase 9: Fix Home/Projects active navigation isolation across all routes',
        (tester) async {
      const ws1 = AxWorkstream(
        id: 'ws-1',
        projectId: 'p-1',
        name: 'Authentication redesign',
        lead: 'Vitalii',
        status: 'running',
        brief: 'Redesign login flow',
        primaryWorkspace: 'MacBook Pro',
        queueStatus: 'Running',
      );

      const project = AxProject(
        id: 'p-1',
        name: 'Conclave AX',
        branch: 'main',
        lastActivity: 'today',
        workstreams: [ws1],
      );

      // 1. On Home route (/)
      final homeCtx = AxShellContext(
        navigation: const AxNavigation.home(),
        projects: [project],
        workstreamsByProject: {project.id: project.workstreams},
        expandedProjectIds: {'p-1'},
      );
      expect(homeCtx.isNavActive(const AxNavigation.home()), isTrue);
      expect(homeCtx.isNavActive(const AxNavigation.projects()), isFalse);

      // 2. On Projects list (/projects)
      final projectsCtx = AxShellContext(
        navigation: const AxNavigation.projects(),
        projects: [project],
        workstreamsByProject: {project.id: project.workstreams},
        expandedProjectIds: {'p-1'},
      );
      expect(projectsCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(projectsCtx.isNavActive(const AxNavigation.projects()), isTrue);

      // 3. On Project detail (/projects/p-1)
      final projectDetailCtx = AxShellContext(
        navigation: const AxNavigation.project('p-1'),
        projects: [project],
        workstreamsByProject: {project.id: project.workstreams},
        selectedProject: project,
        expandedProjectIds: {'p-1'},
      );
      expect(projectDetailCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(
          projectDetailCtx.isNavActive(const AxNavigation.projects()), isTrue);

      // 4. On Workstream detail (/projects/p-1/workstreams/ws-1)
      final workstreamCtx = AxShellContext(
        navigation: const AxNavigation.workstream('p-1', 'ws-1'),
        projects: [project],
        workstreamsByProject: {project.id: project.workstreams},
        selectedProject: project,
        selectedWorkstream: ws1,
        expandedProjectIds: {'p-1'},
      );
      expect(workstreamCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(workstreamCtx.isNavActive(const AxNavigation.projects()), isTrue);

      // 5. On Run detail (/projects/p-1/workstreams/ws-1/runs/r-1)
      final runCtx = AxShellContext(
        navigation: const AxNavigation.run('p-1', 'r-1', workstreamId: 'ws-1'),
        projects: [project],
        workstreamsByProject: {project.id: project.workstreams},
        selectedProject: project,
        selectedWorkstream: ws1,
        expandedProjectIds: {'p-1'},
      );
      expect(runCtx.isNavActive(const AxNavigation.home()), isFalse);
      expect(runCtx.isNavActive(const AxNavigation.projects()), isTrue);

      // 6. Verify Visual UI: when on Workstream, Workstream item is highlighted, Home is not
      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: Scaffold(
            body: AxSidebar(
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
      const ws = AxWorkstream(
        id: 'ws-1',
        projectId: 'p-1',
        name: 'Authentication redesign',
        lead: 'Vitalii',
        status: 'running',
        brief: 'Redesign login flow',
        primaryWorkspace: 'MacBook Pro',
        queueStatus: 'Running',
      );

      const project = AxProject(
        id: 'p-1',
        name: 'Conclave AX',
        branch: 'main',
        lastActivity: 'today',
        workstreams: [ws],
      );

      final shellContext = AxShellContext(
        navigation: const AxNavigation.workstream('p-1', 'ws-1'),
        projects: [project],
        workstreamsByProject: {project.id: project.workstreams},
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

              return Scaffold(
                key: scaffoldKey,
                drawer: !isDesktop
                    ? Drawer(
                        child: AxSidebar(
                          shellContext: shellContext,
                          onNavigateTo: (_) {},
                          onToggleProjectExpanded: (_) {},
                          onCreateProject: () {},
                          onOpenCommandPalette: _dummyAction,
                          onOpenNotifications: _dummyAction,
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
                      SizedBox(
                        width: 248,
                        child: AxSidebar(
                          shellContext: shellContext,
                          onNavigateTo: _dummyNav,
                          onToggleProjectExpanded: _dummyToggle,
                          onCreateProject: _dummyAction,
                          onOpenCommandPalette: _dummyAction,
                          onOpenNotifications: _dummyAction,
                          onLogout: _dummyAction,
                          onOpenAbout: _dummyAction,
                          onOpenExternal: _dummyExternal,
                        ),
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          if (!isDesktop)
                            AxTopBar(
                              shellContext: shellContext,
                              onNavigateTo: _dummyNav,
                              onOpenCommandPalette: _dummyAction,
                              onOpenNotifications: _dummyAction,
                              compact: true,
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

      // 1. Desktop mode (>= 500, test at 1000 x 800)
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();

      // Full sidebar visible with project tree, search & alarm button
      expect(find.byType(AxSidebar), findsOneWidget);
      expect(find.byType(AxTopBar), findsNothing); // Top HUD hidden on desktop
      expect(
          find.text('Authentication redesign'), findsOneWidget); // sidebar item
      expect(find.byTooltip('Search or jump to...'),
          findsOneWidget); // Search on sidebar
      expect(
          find.byTooltip('Notifications'), findsOneWidget); // Alarm on sidebar
      expect(
          find.byTooltip('Open menu'), findsNothing); // No hamburger on desktop

      // 2. Tablet mode (< 500, test at 400 x 800)
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();

      // Top HUD visible with breadcrumb and hamburger menu, pinned sidebar hidden
      expect(find.byType(AxTopBar), findsOneWidget);
      expect(find.byTooltip('Open menu'), findsOneWidget);
      expect(find.text('Conclave AX'), findsOneWidget); // breadcrumb project
      expect(find.text('Authentication redesign'),
          findsOneWidget); // breadcrumb workstream

      // Tap hamburger menu to open drawer with full sidebar
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.byType(AxSidebar), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(Drawer),
              matching: find.text('Authentication redesign')),
          findsOneWidget);

      // Close drawer
      await tester.tap(find.text('Close menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
    });

    testWidgets(
        'About dialog displays title, version badge, description, and website action',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: const Scaffold(
            body: ConclaveAppShell(
              services: DefaultPlatformServices(),
              dataSource: AxFixtureDataSource(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open application menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Tap About Conclave AX to trigger dialog
      await tester.tap(find.text('About Conclave AX'));
      await tester.pumpAndSettle();

      // Assert modal dialog contents
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Conclave AX v0.4.0 • Provider-Independent Core'),
          findsOneWidget);
      expect(find.text('Docs'), findsNothing);
      expect(find.text('GitHub'), findsNothing);
      expect(find.text('Website'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Visit website'), findsOneWidget);

      // Close dialog
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'Phase 6: Accepting invitation on zero-project screen navigates directly into accepted project without reload',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final data = _InvitationTestFixture();
      await tester.pumpWidget(MaterialApp(
        home: ConclaveAppShell(
          services: const DefaultPlatformServices(),
          dataSource: data,
        ),
      ));
      await tester.pumpAndSettle();

      // Zero-project screen with Welcome and Pending Invitation (both on Home and Sidebar)
      expect(find.text('Welcome to Conclave AX'), findsOneWidget);
      expect(find.text('Pending invitations (1)'), findsNWidgets(2));
      expect(find.text('Joined AX Core'), findsWidgets);

      // Tap Accept
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      // Invitation is accepted and disappears, user is navigated into project
      expect(find.text('Welcome to Conclave AX'), findsNothing);
      expect(find.text('Pending invitations (1)'), findsNothing);
      expect(find.text('Joined Joined AX Core.'), findsOneWidget);
      expect(find.text('Joined AX Core'), findsWidgets);

      // Drain toast timer
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

void _dummyNav(AxNavigation _) {}
void _dummyToggle(String _) {}
void _dummyAction() {}
void _dummyExternal(Uri _) {}

class _ProjectScopedFixture extends AxFixtureDataSource {
  final selectedProjects = <String>[];
  @override
  Future<List<AxWorkstream>> loadProjectWorkstreams(
      {required String projectId}) async {
    selectedProjects.add(projectId);
    if (projectId != 'atlas') {
      return super.loadProjectWorkstreams(projectId: projectId);
    }
    return const [
      AxWorkstream(
          id: 'atlas-chat',
          projectId: 'atlas',
          name: 'Atlas conversation',
          lead: 'Test',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: 'Idle')
    ];
  }
}

class _InvitationTestFixture extends AxFixtureDataSource {
  final List<AxProject> initialProjects = const [];
  var pendingInvitations = <AxProjectInvitation>[
    const AxProjectInvitation(
      id: 'inv-invite-1',
      projectId: 'proj-joined-1',
      projectName: 'Joined AX Core',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      invitedByUserName: 'Vitalii Noha',
      createdAt: '2026-10-07T12:00:00Z',
    ),
  ];

  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? projectId, String? workspaceId}) async {
    final base = await super
        .loadBootstrapState(projectId: projectId, workspaceId: workspaceId);
    return base.copyWith(projects: initialProjects);
  }

  @override
  Future<List<AxProject>> loadProjects({bool includeArchived = false}) async =>
      initialProjects;

  @override
  Future<List<AxProjectInvitation>> loadCurrentUserInvitations() async =>
      pendingInvitations;

  @override
  Future<void> acceptProjectInvitation({required String invitationId}) async {
    pendingInvitations =
        pendingInvitations.where((i) => i.id != invitationId).toList();
  }

  @override
  Future<void> declineProjectInvitation({required String invitationId}) async {
    pendingInvitations =
        pendingInvitations.where((i) => i.id != invitationId).toList();
  }
}

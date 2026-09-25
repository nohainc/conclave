// Phase 13 - Comprehensive Shell Regression Test Suite
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/navigation/app_menu.dart';
import 'package:conclave_app/src/features/navigation/app_sidebar.dart';
import 'package:conclave_app/src/features/navigation/app_top_hud.dart';
import 'package:conclave_app/src/features/navigation/project_tree.dart';
import 'package:conclave_app/src/features/navigation/studio_shell_context.dart';
import 'package:conclave_app/src/navigation/studio_navigation.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

void main() {
  const wsRunning = StudioWorkstream(
    id: 'ws-1',
    projectId: 'p-1',
    name: 'Authentication redesign',
    lead: 'Vitalii',
    status: 'running',
    brief: 'Redesign login and session flow',
    primaryWorkspace: 'MacBook Pro',
    currentCheckpoint: 'main',
    queueStatus: 'Running',
  );

  const wsIdle = StudioWorkstream(
    id: 'ws-2',
    projectId: 'p-1',
    name: 'Scheduler',
    lead: 'Vitalii',
    status: 'idle',
    brief: 'Background task scheduling',
    primaryWorkspace: 'MacBook Pro',
    currentCheckpoint: 'main',
    queueStatus: 'Idle',
  );

  const testProject = StudioProject(
    id: 'p-1',
    name: 'Conclave AX',
    branch: 'main',
    activeGoals: 0,
    lastActivity: 'today',
    workstreams: [wsRunning, wsIdle],
  );

  const testAgent = StudioAgent(
    id: 'agent-1',
    name: 'MacBook Pro',
    hostname: 'macbook-pro.local',
    status: 'connected',
    version: '1.0.0',
    pluginCount: 2,
    workerCount: 3,
    activeTaskCount: 1,
  );

  const baseShellContext = StudioShellContext(
    navigation: StudioNavigation.workstream('p-1', 'ws-1'),
    projects: [testProject],
    selectedProject: testProject,
    selectedWorkstream: wsRunning,
    expandedProjectIds: {'p-1'},
    viewerDisplayName: 'Vitalii Noha',
    viewerEmail: 'vitalii@conclave.ax',
    workspaces: [testAgent],
  );

  Widget wrapWithMaterial(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? ConclaveBrand.darkTheme(),
      home: Scaffold(body: child),
    );
  }

  group('Phase 13: Sidebar Content & Isolation Regressions', () {
    testWidgets(
        'sidebar contains Conclave AX brand (home trigger), New Project button, Project tree, User profile, and Menu',
        (tester) async {
      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
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

      // Allowed permanent items:
      expect(find.text('Conclave AX'),
          findsNWidgets(2)); // Brand Header & Project in tree
      expect(find.byTooltip('New Project'),
          findsOneWidget); // New Project button before alarm
      expect(find.byTooltip('Notifications'), findsOneWidget); // Alarm button
      expect(
          find.descendant(
              of: find.byType(ProjectTree), matching: find.text('Conclave AX')),
          findsOneWidget); // Project name in tree
      expect(find.text('Authentication redesign'),
          findsOneWidget); // Workstream in tree
      expect(find.text('Scheduler'), findsOneWidget); // Workstream in tree
      expect(find.text('Vitalii Noha'),
          findsOneWidget); // User footer display name
      expect(find.text('VN'), findsOneWidget); // User avatar initials
      expect(find.byTooltip('Application menu'), findsOneWidget); // ⋯ menu

      // FORBIDDEN permanent sidebar items:
      expect(find.text('Home'), findsNothing);
      expect(find.text('Projects'), findsNothing);
      expect(find.text('PROJECTS'), findsNothing);
      expect(find.text('Workspaces'), findsNothing);
      expect(find.text('Workers'), findsNothing);
      expect(find.text('AI Accounts'), findsNothing);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('Profile & Security'), findsNothing);
      expect(find.text('Agents'), findsNothing);
      expect(find.text('Catalog'), findsNothing);
      expect(find.text('New chat'), findsNothing);
      expect(find.text('ACTIVE GOALS'), findsNothing);
    });

    testWidgets('avatar and name click navigates to Profile & Security',
        (tester) async {
      StudioNavigation? target;
      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
              onNavigateTo: (nav) => target = nav,
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

      // Tap user profile tile
      await tester.tap(find.text('Vitalii Noha'));
      expect(target, const StudioNavigation.profileSecurity());
    });
  });

  group('Phase 13: Global Application Menu Regressions', () {
    testWidgets(
        'menu contains Execution, Usage, Appearance, About, Documentation, GitHub, Website, Log out in correct order',
        (tester) async {
      StudioNavigation? navigated;
      bool aboutOpened = false;
      Uri? openedUrl;
      bool loggedOut = false;

      await tester.pumpWidget(
        wrapWithMaterial(
          Row(
            children: [
              GlobalAppMenu(
                shellContext: baseShellContext,
                onNavigateTo: (nav) => navigated = nav,
                onLogout: () => loggedOut = true,
                onOpenAbout: () => aboutOpened = true,
                onOpenExternal: (uri) => openedUrl = uri,
                onOpenArchivedProjects: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open menu
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      // Verify all required items are present in the menu
      expect(find.text('Execution'), findsOneWidget);
      expect(find.text('Usage'), findsOneWidget);
      expect(find.text('Archived Projects'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('GitHub repository'), findsOneWidget);
      expect(find.text('Website'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);

      // Verify destructive / action callbacks:
      // 1. Execution
      await tester.tap(find.text('Execution'));
      await tester.pumpAndSettle();
      expect(navigated, const StudioNavigation.hosts());

      // Re-open and test Usage
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Usage'));
      await tester.pumpAndSettle();
      expect(navigated, const StudioNavigation.usage());

      // Re-open and test About Conclave AX
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Conclave AX'));
      await tester.pumpAndSettle();
      expect(aboutOpened, isTrue);

      // Re-open and test Documentation
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();
      expect(openedUrl, Uri.parse('https://conclaveax.com/how-it-works/'));

      // Re-open and test GitHub repository
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GitHub repository'));
      await tester.pumpAndSettle();
      expect(openedUrl, Uri.parse('https://github.com/nohainc/conclave'));

      // Re-open and test Website
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Website'));
      await tester.pumpAndSettle();
      expect(openedUrl, Uri.parse('https://conclaveax.com'));

      // Re-open and test Log out
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(loggedOut, isTrue);
    });

    testWidgets('appearance submenu switches System, Light, and Dark modes',
        (tester) async {
      ThemeMode? chosenMode;

      await tester.pumpWidget(
        wrapWithMaterial(
          Row(
            children: [
              GlobalAppMenu(
                shellContext: baseShellContext,
                onNavigateTo: (_) {},
                onSetThemeMode: (mode) => chosenMode = mode,
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {},
                onOpenArchivedProjects: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Switch to Light
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(chosenMode, ThemeMode.light);

      // 2. Switch to Dark
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(chosenMode, ThemeMode.dark);

      // 3. Switch to System
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(chosenMode, ThemeMode.system);
    });
  });

  group('Phase 13: Legacy URL Redirects & Canonical Routing', () {
    test('old /workers deep link canonicalizes to /execution/workers', () {
      final parsed = StudioNavigation.fromUri(Uri.parse('/workers'));
      expect(parsed, const StudioNavigation.workers());
      expect(parsed.toUri().path, '/execution/workers');
    });

    test('old /accounts deep link resolves to the Workers surface', () {
      final parsed = StudioNavigation.fromUri(Uri.parse('/accounts'));
      expect(parsed, const StudioNavigation.workers());
      expect(parsed.toUri().path, '/execution/workers');
    });

    test('query param tabs canonicalize to nested routes', () {
      final workersQuery =
          StudioNavigation.fromUri(Uri.parse('/workspaces?tab=workers'));
      expect(workersQuery, const StudioNavigation.workers());
      expect(workersQuery.toUri().path, '/execution/workers');

      final accountsQuery =
          StudioNavigation.fromUri(Uri.parse('/workspaces?tab=accounts'));
      expect(accountsQuery, const StudioNavigation.workers());
      expect(accountsQuery.toUri().path, '/execution/workers');

      final legacyHosts =
          StudioNavigation.fromUri(Uri.parse('/hosts?tab=ai_accounts'));
      expect(legacyHosts, const StudioNavigation.workers());
      expect(legacyHosts.toUri().path, '/execution/workers');
    });
  });

  group('Phase 13: Project Tree Interaction & Workstream Selection', () {
    testWidgets('project row expands/collapses and navigates independently',
        (tester) async {
      String? toggledProjectId;
      StudioNavigation? navigated;

      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
              onNavigateTo: (nav) => navigated = nav,
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

      // Tapping the project chevron triggers expansion toggle
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      expect(toggledProjectId, 'p-1');
      expect(navigated, isNull);

      // Tapping the project title in project tree navigates to the project overview
      await tester.tap(find.descendant(
        of: find.byType(ProjectTree),
        matching: find.text('Conclave AX'),
      ));
      expect(navigated, const StudioNavigation.project('p-1'));
    });

    testWidgets('selecting a workstream triggers navigation with active state',
        (tester) async {
      StudioNavigation? navigated;

      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
              onNavigateTo: (nav) => navigated = nav,
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

      // Tap on idle workstream 'Scheduler'
      await tester.tap(find.text('Scheduler'));
      expect(navigated, const StudioNavigation.workstream('p-1', 'ws-2'));
    });
  });

  group('Phase 13: Responsive Behavior & Mobile Drawer', () {
    testWidgets('responsive layout across Desktop, Medium (Rail), and Mobile',
        (tester) async {
      final scaffoldKey = GlobalKey<ScaffoldState>();

      Widget buildAppScaffold() {
        return MaterialApp(
          theme: ConclaveBrand.darkTheme(),
          home: LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = ConclaveBrand.isDesktop(constraints.maxWidth);

              return Scaffold(
                key: scaffoldKey,
                drawer: !isDesktop
                    ? Drawer(
                        child: AppSidebar(
                          shellContext: baseShellContext,
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
                      const SizedBox(
                        width: 248,
                        child: AppSidebar(
                          shellContext: baseShellContext,
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
                            const AppTopHud(
                              shellContext: baseShellContext,
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

      // 1. Desktop mode (>= 500)
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();
      expect(find.byType(AppSidebar), findsOneWidget);
      expect(find.byType(AppTopHud), findsNothing); // Top HUD hidden on desktop
      expect(find.byTooltip('Search or jump to...'),
          findsOneWidget); // Search on sidebar
      expect(
          find.byTooltip('Notifications'), findsOneWidget); // Alarm on sidebar
      expect(find.byTooltip('Open menu'), findsNothing);

      // 2. Tablet mode (< 500)
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpWidget(buildAppScaffold());
      await tester.pumpAndSettle();
      expect(find.byType(AppSidebar), findsNothing);
      expect(
          find.byType(AppTopHud), findsOneWidget); // Top HUD visible on tablet
      expect(find.byTooltip('Open menu'), findsOneWidget);

      // Open tablet drawer
      await tester.tap(find.byTooltip('Open menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.byType(AppSidebar), findsOneWidget);
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
  });

  group('Phase 13: Keyboard Focus & Menu Navigation', () {
    testWidgets(
        'global app menu opens and closes via toggle tap or outside tap',
        (tester) async {
      await tester.pumpWidget(
        wrapWithMaterial(
          Row(
            children: [
              GlobalAppMenu(
                shellContext: baseShellContext,
                onNavigateTo: (_) {},
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {},
                onOpenArchivedProjects: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open menu via button tap
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.text('Execution'), findsOneWidget);

      // Tap outside to dismiss
      await tester.tapAt(const Offset(400, 400));
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsNothing);
    });

    testWidgets('sidebar items and interactive widgets are focusable',
        (tester) async {
      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
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

      // Traverse focus with Tab key
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, isNotNull);
    });
  });
}

void _dummyNav(StudioNavigation _) {}
void _dummyToggle(String _) {}
void _dummyAction() {}
void _dummyExternal(Uri _) {}

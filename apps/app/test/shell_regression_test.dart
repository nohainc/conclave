// Phase 13 - Comprehensive Shell Regression Test Suite
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/navigation/app_menu.dart';
import 'package:conclave_app/src/features/navigation/app_sidebar.dart';
import 'package:conclave_app/src/features/navigation/app_top_hud.dart';
import 'package:conclave_app/src/features/navigation/space_tree.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

void main() {
  const wsRunning = AxThread(
    id: 'ws-1',
    spaceId: 'p-1',
    name: 'Authentication redesign',
    lead: 'Vitalii',
    status: 'running',
    brief: 'Redesign login and session flow',
    primaryWorkspace: 'MacBook Pro',
    queueStatus: 'Running',
  );

  const wsIdle = AxThread(
    id: 'ws-2',
    spaceId: 'p-1',
    name: 'Scheduler',
    lead: 'Vitalii',
    status: 'idle',
    brief: 'Background task scheduling',
    primaryWorkspace: 'MacBook Pro',
    queueStatus: 'Idle',
  );

  const testSpace = AxSpace(
    id: 'p-1',
    name: 'Conclave AX',
    branch: 'main',
    lastActivity: 'today',
    threads: [wsRunning, wsIdle],
  );

  const testWorkspace = AxWorkspace(
    id: 'worker-1',
    name: 'MacBook Pro',
    hostname: 'macbook-pro.local',
    status: 'connected',
    appVersion: '1.0.0',
    workerCount: 3,
    activeTaskCount: 1,
  );

  const baseShellContext = AxShellContext(
    navigation: AxNavigation.thread('p-1', 'ws-1'),
    spaces: [testSpace],
    threadsBySpace: {
      'p-1': [wsRunning, wsIdle]
    },
    selectedSpace: testSpace,
    selectedThread: wsRunning,
    expandedSpaceIds: {'p-1'},
    viewerDisplayName: 'Vitalii Noha',
    viewerEmail: 'vitalii@conclave.ax',
    workspaces: [testWorkspace],
  );

  Widget wrapWithMaterial(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? ConclaveBrand.darkTheme(),
      home: Scaffold(body: child),
    );
  }

  group('Phase 13: Sidebar Content & Isolation Regressions', () {
    testWidgets(
        'sidebar contains Conclave AX brand (home trigger), New Space button, Space tree, User profile, and Menu',
        (tester) async {
      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
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
          findsNWidgets(2)); // Brand Header & Space in tree
      expect(find.byTooltip('New Space'),
          findsOneWidget); // New Space button before alarm
      expect(find.byTooltip('Notifications'), findsOneWidget); // Alarm button
      expect(
          find.descendant(
              of: find.byType(SpaceTree), matching: find.text('Conclave AX')),
          findsOneWidget); // Space name in tree
      expect(find.text('Authentication redesign'),
          findsOneWidget); // Thread in tree
      expect(find.text('Scheduler'), findsOneWidget); // Thread in tree
      expect(find.text('Vitalii Noha'),
          findsOneWidget); // User footer display name
      expect(find.text('VN'), findsOneWidget); // User avatar initials
      expect(find.byTooltip('Application menu'), findsOneWidget); // ⋯ menu

      // FORBIDDEN permanent sidebar items:
      expect(find.text('Home'), findsNothing);
      expect(find.text('Spaces'), findsNothing);
      expect(find.text('SPACES'), findsNothing);
      expect(find.text('Workspaces'), findsNothing);
      expect(find.text('Workers'), findsNothing);
      expect(find.text('Usage'), findsNothing);
      expect(find.text('Profile & Security'), findsNothing);
      expect(find.text('Catalog'), findsNothing);
      expect(find.text('New chat'), findsNothing);
      expect(find.text('ACTIVE GOALS'), findsNothing);
    });

    testWidgets('avatar and name click navigates to Profile & Security',
        (tester) async {
      AxNavigation? target;
      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
              onNavigateTo: (nav) => target = nav,
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
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
      expect(target, const AxNavigation.profileSecurity());
    });
  });

  group('Phase 13: Global Application Menu Regressions', () {
    testWidgets(
        'menu contains Workspaces, Archived Spaces, Appearance, Downloads, Documentation, About Conclave AX, Log out in correct order',
        (tester) async {
      AxNavigation? navigated;
      bool aboutOpened = false;
      Uri? openedUrl;
      bool loggedOut = false;
      bool archivedSpacesOpened = false;

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
                onOpenArchivedSpaces: () => archivedSpacesOpened = true,
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
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Archived Spaces'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Documentation'), findsOneWidget);
      expect(find.text('About Conclave AX'), findsOneWidget);
      expect(find.text('Log out'), findsOneWidget);

      // Verify removed items are NOT present
      expect(find.text('Usage'), findsNothing);
      expect(find.text('GitHub repository'), findsNothing);
      expect(find.text('Website'), findsNothing);

      // Verify destructive / action callbacks:
      // 1. Workspaces
      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(navigated, const AxNavigation.workspaces());

      // Re-open and test Archived Spaces
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archived Spaces'));
      await tester.pumpAndSettle();
      expect(archivedSpacesOpened, isTrue);

      // Re-open and test Downloads
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Downloads'));
      await tester.pumpAndSettle();
      expect(openedUrl, Uri.parse('https://conclaveax.com/downloads/'));

      // Re-open and test Documentation
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();
      expect(openedUrl, Uri.parse('https://conclaveax.com/how-it-works/'));

      // Re-open and test About Conclave AX
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About Conclave AX'));
      await tester.pumpAndSettle();
      expect(aboutOpened, isTrue);

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
                onOpenArchivedSpaces: () {},
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

  group('Phase 13: Space Tree Interaction & Thread Selection', () {
    testWidgets('selecting expanded parent preserves expansion and navigates',
        (tester) async {
      String? toggledSpaceId;
      AxNavigation? navigated;

      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
              onNavigateTo: (nav) => navigated = nav,
              onToggleSpaceExpanded: (id) => toggledSpaceId = id,
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Space tree displays open folder icon when expanded
      expect(
        find.byWidgetPredicate(
            (w) => w is ConclaveFolderIcon && w.isExpanded == true),
        findsOneWidget,
      );

      // Selecting the expanded parent from a Thread preserves expansion.
      await tester.tap(find.descendant(
        of: find.byType(SpaceTree),
        matching: find.text('Conclave AX'),
      ));
      expect(toggledSpaceId, isNull);
      expect(navigated, const AxNavigation.space('p-1'));
    });

    testWidgets('selecting a thread triggers navigation with active state',
        (tester) async {
      AxNavigation? navigated;

      await tester.pumpWidget(
        wrapWithMaterial(
          SizedBox(
            width: 248,
            child: AppSidebar(
              shellContext: baseShellContext,
              onNavigateTo: (nav) => navigated = nav,
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on idle thread 'Scheduler'
      await tester.tap(find.text('Scheduler'));
      expect(navigated, const AxNavigation.thread('p-1', 'ws-2'));
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
                          onToggleSpaceExpanded: (_) {},
                          onCreateSpace: () {},
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
                          onToggleSpaceExpanded: _dummyToggle,
                          onCreateSpace: _dummyAction,
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
                onOpenArchivedSpaces: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open menu via button tap
      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();
      expect(find.text('Workspaces'), findsOneWidget);

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
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
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

void _dummyNav(AxNavigation _) {}
void _dummyToggle(String _) {}
void _dummyAction() {}
void _dummyExternal(Uri _) {}

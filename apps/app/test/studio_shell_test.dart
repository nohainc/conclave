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

      const shellContext = StudioShellContext(
        navigation: StudioNavigation.home(),
        projects: [testProject],
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

      // Check Viewer Initials & Name
      expect(find.text('VN'), findsOneWidget);
      expect(find.text('Vitalii Noha'), findsOneWidget);

      // Tap + button for create project
      await tester.tap(find.byTooltip('Create Project'));
      expect(createProjectCalled, isTrue);

      // Tap workstream row
      await tester.tap(find.text('Authentication redesign'));
      expect(navigatedTo?.kind, StudioRouteKind.workstream);
      expect(navigatedTo?.workstreamId, 'ws-1');

      // Tap chevron to toggle expansion
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      expect(toggledProjectId, 'project-1');
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

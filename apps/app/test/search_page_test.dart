import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/features/navigation/app_sidebar.dart';
import 'package:conclave_app/src/features/navigation/studio_shell_context.dart';
import 'package:conclave_app/src/features/search/search_page.dart';
import 'package:conclave_app/src/navigation/studio_navigation.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

void main() {
  group('Search Control & Search Page', () {
    late StudioSnapshot sampleSnapshot;

    setUp(() {
      sampleSnapshot = StudioSnapshot.empty().copyWith(
        projects: [
          const StudioProject(
            id: 'proj-1',
            name: 'Conclave Core',
            repository: 'nohainc/conclave',
            branch: 'main',
            activeGoals: 1,
            lastActivity: 'now',
            workstreams: [
              StudioWorkstream(
                id: 'ws-1',
                projectId: 'proj-1',
                name: 'Authentication redesign',
                lead: 'Vitalii',
                status: 'active',
                brief: 'Auth overhaul',
                primaryWorkspace: 'local',
                currentCheckpoint: 'checkpoint-1',
                queueStatus: 'idle',
              ),
              StudioWorkstream(
                id: 'ws-2',
                projectId: 'proj-1',
                name: 'Search page integration',
                lead: 'Vitalii',
                status: 'planning',
                brief: 'Search page UX',
                primaryWorkspace: 'local',
                currentCheckpoint: 'checkpoint-2',
                queueStatus: 'idle',
              ),
            ],
          ),
          const StudioProject(
            id: 'proj-2',
            name: 'Data Pipeline',
            repository: 'nohainc/pipeline',
            branch: 'develop',
            activeGoals: 0,
            lastActivity: 'yesterday',
          ),
        ],
        workers: [
          const StudioWorker(
            id: 'worker-1',
            name: 'Codex AI',
            provider: 'OpenAI',
            role: 'Implementation',
            capabilities: ['code'],
            status: 'ready',
            cost: '\$0.02',
          ),
        ],
      );
    });

    testWidgets('Search control allows typing and displays clear button when non-empty',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      final shellContext = StudioShellContext(
        navigation: const StudioNavigation.home(),
        projects: sampleSnapshot.projects,
        workspaces: const [],
        workers: sampleSnapshot.workers,
        accounts: const [],
        unreadNotificationCount: 0,
        isDarkTheme: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 250,
              child: AppSidebar(
                shellContext: shellContext,
                searchController: controller,
                onNavigateTo: (_) {},
                onToggleProjectExpanded: (_) {},
                onCreateProject: () {},
                onClearSearch: () => controller.clear(),
                onLogout: () {},
                onOpenAbout: () {},
                onOpenExternal: (_) {},
              ),
            ),
          ),
        ),
      );

      // Initially empty -> no clear button
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsNothing);

      // User types query
      await tester.enterText(find.byType(TextField), 'auth');
      await tester.pumpAndSettle();

      // Non-empty -> clear button appears
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      // Tap clear button
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(controller.text, isEmpty);
      expect(find.byIcon(Icons.close_rounded), findsNothing);

      // Enter text and press Escape
      await tester.enterText(find.byType(TextField), 'testing escape');
      await tester.pumpAndSettle();
      expect(controller.text, 'testing escape');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
    });

    testWidgets('SearchPage filters snapshot and renders categorized results',
        (tester) async {
      StudioNavigation? navigatedTarget;
      var searchCleared = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(
              query: 'auth',
              snapshot: sampleSnapshot,
              onNavigateTo: (nav) => navigatedTarget = nav,
              onSelectProject: (_) {},
              onSelectChat: (_, __) {},
              onClearSearch: () => searchCleared = true,
            ),
          ),
        ),
      );

      expect(find.text('Search Results'), findsOneWidget);
      expect(find.textContaining('for "auth"'), findsOneWidget);

      // Should find workstream 'Authentication redesign'
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('WORKSTREAMS'), findsOneWidget);

      // Tap the workstream result
      await tester.tap(find.text('Authentication redesign'));
      await tester.pumpAndSettle();

      expect(searchCleared, isTrue);
      expect(
        navigatedTarget,
        const StudioNavigation.workstream('proj-1', 'ws-1'),
      );
    });

    testWidgets('SearchPage displays friendly empty state when no results match',
        (tester) async {
      var searchCleared = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(
              query: 'nonexistentquery123',
              snapshot: sampleSnapshot,
              onNavigateTo: (_) {},
              onSelectProject: (_) {},
              onSelectChat: (_, __) {},
              onClearSearch: () => searchCleared = true,
            ),
          ),
        ),
      );

      expect(find.text('No results found for "nonexistentquery123"'), findsOneWidget);
      expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);

      // Tap back button in empty state
      await tester.tap(find.text('Back to previous page'));
      await tester.pumpAndSettle();

      expect(searchCleared, isTrue);
    });
  });
}

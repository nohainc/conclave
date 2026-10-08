import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/features/navigation/app_sidebar.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/search/search_page.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

void main() {
  group('Search Control & Search Page', () {
    late AxSnapshot sampleSnapshot;

    setUp(() {
      sampleSnapshot = AxSnapshot.empty().copyWith(
        spaces: [
          const AxSpace(
            id: 'proj-1',
            name: 'Conclave Core',
            branch: 'main',
            lastActivity: 'now',
            threads: [
              AxThread(
                id: 'ws-1',
                spaceId: 'proj-1',
                name: 'Authentication redesign',
                lead: 'Vitalii',
                status: 'active',
                brief: 'Auth overhaul',
                primaryWorkspace: 'local',
                queueStatus: 'idle',
              ),
              AxThread(
                id: 'ws-2',
                spaceId: 'proj-1',
                name: 'Search page integration',
                lead: 'Vitalii',
                status: 'planning',
                brief: 'Search page UX',
                primaryWorkspace: 'local',
                queueStatus: 'idle',
              ),
            ],
          ),
          const AxSpace(
            id: 'proj-2',
            name: 'Data Pipeline',
            branch: 'develop',
            lastActivity: 'yesterday',
          ),
        ],
      );
    });

    testWidgets(
        'Search control allows typing and displays clear button when non-empty',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      final shellContext = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: sampleSnapshot.spaces,
        workspaces: const [],
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
                onToggleSpaceExpanded: (_) {},
                onCreateSpace: () {},
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
      AxNavigation? navigatedTarget;
      var searchCleared = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(
              query: 'auth',
              spaces: sampleSnapshot.spaces,
              workspaces: sampleSnapshot.workspaces,
              run: sampleSnapshot.run,
              threadsBySpace: {
                for (final space in sampleSnapshot.spaces)
                  space.id: space.threads
              },
              onNavigateTo: (nav) => navigatedTarget = nav,
              onSelectSpace: (_) {},
              onClearSearch: () => searchCleared = true,
            ),
          ),
        ),
      );

      expect(find.text('Search Results'), findsOneWidget);
      expect(find.textContaining('for "auth"'), findsOneWidget);

      // Should find thread 'Authentication redesign'
      expect(find.text('Authentication redesign'), findsOneWidget);
      expect(find.text('THREADS'), findsOneWidget);

      // Tap the thread result
      await tester.tap(find.text('Authentication redesign'));
      await tester.pumpAndSettle();

      expect(searchCleared, isTrue);
      expect(
        navigatedTarget,
        const AxNavigation.thread('proj-1', 'ws-1'),
      );
    });

    testWidgets(
        'SearchPage displays friendly empty state when no results match',
        (tester) async {
      var searchCleared = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPage(
              query: 'nonexistentquery123',
              spaces: sampleSnapshot.spaces,
              workspaces: sampleSnapshot.workspaces,
              run: sampleSnapshot.run,
              threadsBySpace: {
                for (final space in sampleSnapshot.spaces)
                  space.id: space.threads
              },
              onNavigateTo: (_) {},
              onSelectSpace: (_) {},
              onClearSearch: () => searchCleared = true,
            ),
          ),
        ),
      );

      expect(find.text('No results found for "nonexistentquery123"'),
          findsOneWidget);
      expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);

      // Tap back button in empty state
      await tester.tap(find.text('Back to previous page'));
      await tester.pumpAndSettle();

      expect(searchCleared, isTrue);
    });
  });
}

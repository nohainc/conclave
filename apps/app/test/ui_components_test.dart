import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/common/code_block_view.dart';
import 'package:conclave_app/src/features/common/command_palette.dart';
import 'package:conclave_app/src/features/common/toast_overlay.dart';
import 'package:conclave_app/src/features/execution/task_pipeline_dag.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'ax_fixture_snapshot.dart';

void main() {
  group('UI & UX Feature Components', () {
    testWidgets('renders CodeBlockView with language tag and copy button',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.lightTheme(),
          home: const Scaffold(
            body: CodeBlockView(
              code: 'function hello() {\n  return "world";\n}',
              language: 'typescript',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('TYPESCRIPT'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.textContaining('return "world"'), findsOneWidget);

      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('renders ToastOverlay and triggers dismiss and copy',
        (WidgetTester tester) async {
      String? dismissedId;

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.lightTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                ToastOverlay(
                  toasts: const [
                    ToastMessage(
                      id: 'toast-1',
                      message: 'Goal created successfully',
                      type: ToastType.success,
                    ),
                  ],
                  onDismiss: (id) => dismissedId = id,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Goal created successfully'), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(dismissedId, 'toast-1');
    });

    testWidgets('renders TaskPipelineDAG with live task progression',
        (WidgetTester tester) async {
      String? selectedTaskId;
      final tasks = [
        const AxTask(
          id: 'task-1',
          title: 'Research architecture',
          phase: 'Research',
          status: TaskStatus.completed,
          worker: 'conclave.research',
          detail: 'Done',
          progress: 1.0,
          dependencies: [],
        ),
        const AxTask(
          id: 'task-2',
          title: 'Implement feature',
          phase: 'Implementation',
          status: TaskStatus.running,
          worker: 'conclave.implement',
          detail: 'In progress',
          progress: 0.5,
          dependencies: ['task-1'],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.lightTheme(),
          home: Scaffold(
            body: TaskPipelineDAG(
              tasks: tasks,
              selectedTaskId: 'task-2',
              onSelectTask: (id) => selectedTaskId = id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('EXECUTION PIPELINE'), findsOneWidget);
      expect(find.text('Research architecture'), findsOneWidget);
      expect(find.text('Implement feature'), findsOneWidget);

      await tester.tap(find.text('Research architecture'));
      expect(selectedTaskId, 'task-1');
    });

    testWidgets('renders CommandPaletteDialog and filters actions',
        (WidgetTester tester) async {
      AxNavigation? navigatedTo;
      final snapshot = axFixtureSnapshot();

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.lightTheme(),
          home: Scaffold(
            body: CommandPaletteDialog(
              snapshot: snapshot,
              onSelectProject: (_) {},
              onNavigateTo: (route) => navigatedTo = route,
              onToggleTheme: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsWidgets);
      expect(find.text('Workers'), findsNothing);
      expect(find.text('Profile & Security'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Workspaces');
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsWidgets);
      expect(find.text('Workers'), findsNothing);

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.workspaces);

      // Search for Profile & Security
      await tester.enterText(find.byType(TextField), 'Profile');
      await tester.pumpAndSettle();

      expect(find.text('Profile & Security'), findsOneWidget);
      await tester.tap(find.text('Profile & Security'));
      await tester.pumpAndSettle();
      expect(navigatedTo?.kind, AxRouteKind.profileSecurity);
    });

    testWidgets('CommandPaletteDialog supports keyboard navigation',
        (WidgetTester tester) async {
      AxNavigation? navigatedTo;

      await tester.pumpWidget(
        MaterialApp(
          theme: ConclaveBrand.lightTheme(),
          home: Scaffold(
            body: CommandPaletteDialog(
              snapshot: axFixtureSnapshot(),
              onSelectProject: (_) {},
              onNavigateTo: (route) => navigatedTo = route,
              onToggleTheme: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Navigate down from Home (index 0) to Workspaces (index 1)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(navigatedTo?.kind, AxRouteKind.workspaces);
    });
  });
}

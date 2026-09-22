import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:conclave_app/main.dart';
import 'demo_studio_data.dart';

void main() {
  testWidgets('renders the chat-first Studio workspace',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: DemoStudioDataSource()));
    await tester.pumpAndSettle();
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Improve authentication architecture'), findsWidgets);
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Streaming assignment protocol', skipOffstage: false),
        findsOneWidget);
    await tester.tap(find.text('Close menu'));
    await tester.pumpAndSettle();
    expect(find.text('Research'), findsOneWidget);
    expect(find.text('Synthesis'), findsOneWidget);
    expect(find.text('Implementation'), findsOneWidget);
  });

  testWidgets('can open run details and return to chat',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: DemoStudioDataSource()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Open run details'));
    await tester.tap(find.text('Open run details'));
    await tester.pumpAndSettle();
    expect(find.text('Execution tree'), findsOneWidget);
    expect(find.text('Evidence & findings'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Conversation'), findsOneWidget);
  });

  testWidgets('can pause a run and open goal creation',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: DemoStudioDataSource()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Open run details'));
    await tester.tap(find.text('Open run details'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Pause'));
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);

    await tester.ensureVisible(find.text('New goal'));
    await tester.tap(find.text('New goal'));
    await tester.pump();
    expect(find.text('Create a goal'), findsOneWidget);
    expect(find.text('What should Conclave accomplish?'), findsOneWidget);
  });

  testWidgets('switches project chats and sends a new prompt',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: DemoStudioDataSource()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Atlas API', skipOffstage: false));
    await tester.tap(find.text('Atlas API'));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.text('Database migration v2', skipOffstage: false));
    await tester.tap(find.text('Database migration v2', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.text('Database migration v2'), findsWidgets);

    final prompt = find.byType(TextField);
    await tester.enterText(
        prompt, 'Compare the migration rollback strategies.');
    await tester.ensureVisible(find.byIcon(Icons.arrow_upward_rounded));
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(
        find.text('Compare the migration rollback strategies.'), findsWidgets);
  });

  testWidgets('opens separate Agent, Plugin, and Worker management pages',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: DemoStudioDataSource()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Development Agent'), findsOneWidget);
    expect(find.text('3 plugins'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plugins'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Docker'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workers'));
    await tester.pumpAndSettle();
    expect(find.text('Configured resources'), findsOneWidget);
    expect(find.text('Lead'), findsOneWidget);
  });
}

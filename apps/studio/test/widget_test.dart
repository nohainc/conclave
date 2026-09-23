import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:conclave_studio/main.dart';
import 'studio_fixture_data.dart';

void main() {
  testWidgets('renders the chat-first Conclave AX workspace',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: StudioFixtureDataSource()));
    await tester.pumpAndSettle();
    expect(find.text('Conclave AX'), findsOneWidget);
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
        .pumpWidget(const ConclaveApp(dataSource: StudioFixtureDataSource()));
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
        .pumpWidget(const ConclaveApp(dataSource: StudioFixtureDataSource()));
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
        .pumpWidget(const ConclaveApp(dataSource: StudioFixtureDataSource()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Atlas API', skipOffstage: false));
    await tester.tap(find.text('Atlas API'));
    await tester.pumpAndSettle();
    final migrationChat =
        find.text('Database migration v2', skipOffstage: false).last;
    await tester.ensureVisible(migrationChat);
    await tester.tap(migrationChat);
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

  testWidgets('opens Hosts, Workers, and Accounts without v3 terminology',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: StudioFixtureDataSource()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hosts'));
    await tester.pumpAndSettle();
    expect(find.text('Development Host'), findsOneWidget);
    expect(find.text('Pair Host'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workers'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Docker'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Accounts'), findsWidgets);
    expect(find.text('Vitalii Codex'), findsOneWidget);
    expect(find.text('Create Worker'), findsNothing);
    expect(find.text('Agents'), findsNothing);
    expect(find.text('Plugins'), findsNothing);
  });

  testWidgets(
      'chat composer defaults to Auto and Balanced with advanced controls',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const ConclaveApp(dataSource: StudioFixtureDataSource()));
    await tester.pumpAndSettle();

    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Balanced'), findsOneWidget);
    await tester.ensureVisible(find.text('Advanced execution'));
    await tester.tap(find.text('Advanced execution'));
    await tester.pumpAndSettle();
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Candidates'), findsOneWidget);
    expect(find.text('Cost'), findsOneWidget);
  });

  testWidgets('navigation adapts from wide sidebar to compact drawer',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester
        .pumpWidget(const ConclaveApp(dataSource: StudioFixtureDataSource()));
    await tester.pumpAndSettle();
    expect(find.text('Hosts'), findsOneWidget);
    expect(find.text('Accounts'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(720, 900));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Hosts', skipOffstage: false), findsOneWidget);
    expect(find.text('Accounts', skipOffstage: false), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('opens the human Account page with methods and sessions',
      (WidgetTester tester) async {
    await tester.pumpWidget(ConclaveApp(
        dataSource: const StudioFixtureDataSource(),
        initialUri: Uri(path: '/account')));
    await tester.pumpAndSettle();

    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Linked login methods'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Active sessions'), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
    expect(find.text('Passkeys'), findsOneWidget);
    expect(find.text('MacBook Touch ID'), findsOneWidget);
    expect(find.text('Add passkey'), findsOneWidget);
  });

  testWidgets('auth redirects to sign-in without loading workspace data',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ConclaveApp(
        dataSource: StudioFixtureDataSource(authenticated: false)));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Conclave'), findsOneWidget);
    expect(find.text('Continue with GitHub'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Passkey'), findsOneWidget);
    expect(find.text('Improve authentication architecture'), findsNothing);
  });

  testWidgets('chat and run links can be opened from a refreshed URL',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ConclaveApp(
        dataSource: const StudioFixtureDataSource(),
        initialUri: Uri(path: '/projects/forge/chats/chat-auth-1'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('Improve authentication architecture'), findsWidgets);
  });
}

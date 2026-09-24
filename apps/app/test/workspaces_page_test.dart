import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'studio_fixture_snapshot.dart';

void main() {
  group('WorkspacesPage (Consolidated Execution Configuration Center)', () {
    testWidgets('exposes top-level tabs: Workspaces, Workers, and AI Accounts',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      var addWorkspaceCalled = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacesPage(
            workspaces: snapshot.agents,
            workers: snapshot.workers,
            accounts: snapshot.accounts,
            plugins: snapshot.plugins,
            onAdd: () => addWorkspaceCalled = true,
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onGrant: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Verify product title
      expect(find.text('Workspaces'), findsWidgets);
      expect(find.text('Execution environments, Workers, and AI Accounts.'),
          findsOneWidget);

      // Verify top-level tabs
      expect(find.widgetWithText(Tab, 'Workspaces'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Workers'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'AI Accounts'), findsOneWidget);

      // Verify Workspaces tab is active by default
      expect(find.text('Development Workspace'), findsOneWidget);
      expect(find.text('5 Workers'), findsOneWidget);

      // Add Workspace action
      await tester.tap(find.text('Add Workspace').first);
      expect(addWorkspaceCalled, isTrue);

      // Switch to Workers tab
      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      expect(find.text('Codex'), findsWidgets);
      expect(find.text('View capabilities'), findsWidgets);
      expect(find.text('View requirements'), findsWidgets);
      expect(find.text('Connect Account'), findsWidgets);

      // Switch to AI Accounts tab
      await tester.tap(find.widgetWithText(Tab, 'AI Accounts'));
      await tester.pumpAndSettle();

      expect(find.text('Add AI Account'), findsOneWidget);
      expect(find.text('Vitalii Codex'), findsOneWidget);
    });

    testWidgets('respects initialTab parameter', (tester) async {
      final snapshot = studioFixtureSnapshot();

      // initialTab: 1 (Workers)
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacesPage(
            workspaces: snapshot.agents,
            workers: snapshot.workers,
            accounts: snapshot.accounts,
            plugins: snapshot.plugins,
            initialTab: 1,
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onGrant: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Codex'), findsWidgets);

      // initialTab: 2 (AI Accounts)
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacesPage(
            workspaces: snapshot.agents,
            workers: snapshot.workers,
            accounts: snapshot.accounts,
            plugins: snapshot.plugins,
            initialTab: 2,
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onGrant: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Vitalii Codex'), findsOneWidget);
      expect(find.text('Add AI Account'), findsOneWidget);
    });

    testWidgets('Workers tab triggers capability and account callbacks',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      StudioPlugin? detailsPlugin;
      var navigateToAccountsCalled = false;
      StudioPlugin? toggledPlugin;
      StudioAgent? toggledHost;
      bool? toggledDesired;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacesPage(
            workspaces: snapshot.agents,
            workers: snapshot.workers,
            accounts: snapshot.accounts,
            plugins: snapshot.plugins,
            initialTab: 1,
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onGrant: (_) {},
            onShowWorkerDetails: (p) => detailsPlugin = p,
            onNavigateToAccounts: () => navigateToAccountsCalled = true,
            onSetWorkerAvailability: (p, h, d) {
              toggledPlugin = p;
              toggledHost = h;
              toggledDesired = d;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // View capabilities
      await tester.tap(find.text('View capabilities').first);
      expect(detailsPlugin?.name, 'Codex');

      // Connect Account
      await tester.tap(find.text('Connect Account').first);
      expect(navigateToAccountsCalled, isTrue);

      // Toggle worker availability
      if (find.text('Remove from Workspace').evaluate().isNotEmpty) {
        await tester.tap(find.text('Remove from Workspace').first);
        expect(toggledPlugin, isNotNull);
        expect(toggledHost, isNotNull);
        expect(toggledDesired, isFalse);
      }
    });

    testWidgets('AI Accounts tab triggers add, setup, and revoke callbacks',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      var createAccountCalled = false;
      StudioCredentialProfile? setupProfile;
      StudioCredentialProfile? revokeProfile;
      var dismissedBanner = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacesPage(
            workspaces: snapshot.agents,
            workers: snapshot.workers,
            accounts: snapshot.accounts,
            plugins: snapshot.plugins,
            initialTab: 2,
            workerActionMessage: 'Action in progress...',
            onDismissWorkerActionMessage: () => dismissedBanner = true,
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onGrant: (_) {},
            onCreateAccount: () => createAccountCalled = true,
            onRequestAccountSetup: (p) => setupProfile = p,
            onRevokeAccount: (p) => revokeProfile = p,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Banner check and dismiss
      expect(find.text('Action in progress...'), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      expect(dismissedBanner, isTrue);

      // Add Account
      await tester.tap(find.text('Add AI Account'));
      expect(createAccountCalled, isTrue);

      // Account actions menu
      await tester.tap(find.byTooltip('Account actions').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reconnect / re-authenticate'));
      await tester.pumpAndSettle();
      expect(setupProfile?.displayName, 'Vitalii Codex');

      await tester.tap(find.byTooltip('Account actions').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Revoke Account'));
      await tester.pumpAndSettle();
      expect(revokeProfile?.displayName, 'Vitalii Codex');
    });

    testWidgets('Workspace detail navigation and inner detail tabs',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacesPage(
            workspaces: snapshot.agents,
            workers: snapshot.workers,
            accounts: snapshot.accounts,
            plugins: snapshot.plugins,
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onGrant: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('View Workspace'));
      await tester.pumpAndSettle();

      for (final label in [
        'Overview',
        'Workers',
        'AI Accounts',
        'Project access',
        'Repositories & permissions',
        'Activity',
        'Settings',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('Project access'));
      await tester.pumpAndSettle();
      expect(find.text('Grant to Project'), findsOneWidget);

      // Back to workspaces list
      await tester.tap(find.byTooltip('Back to Workspaces'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Tab, 'Workspaces'), findsOneWidget);
    });
  });
}


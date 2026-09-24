import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';

import 'studio_fixture_snapshot.dart';

void main() {
  testWidgets('Workspace directory exposes runtime detail sections',
      (tester) async {
    final snapshot = studioFixtureSnapshot();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorkspacesPage(
          workspaces: snapshot.agents,
          workers: snapshot.workers,
          accounts: snapshot.accounts,
          onAdd: () {},
          onRename: (_) {},
          onUpdate: (_) {},
          onRevoke: (_) {},
          onGrant: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Add Workspace'), findsOneWidget);
    expect(find.text('Development Workspace'), findsOneWidget);
    expect(find.text('5 Workers'), findsOneWidget);
    expect(find.textContaining('Project Grants'), findsOneWidget);

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
  });
}

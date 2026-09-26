import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

void main() {
  testWidgets('empty Workspaces invites users to connect a desktop',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorkspacesPage(
          workspaces: const [],
          onAdd: () {},
          onRename: (_) {},
          onUpdate: (_) {},
          onRevoke: (_) {},
          onGrant: (_) {},
        ),
      ),
    ));

    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Connect Workspace'), findsNWidgets(2));
    expect(find.text('Pair Workspace'), findsNothing);
    expect(find.text('Download Conclave Workspace'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('connected Workspace card remains the unit of the page',
      (tester) async {
    const workspace = StudioWorkspace(
      id: 'workspace-1',
      name: 'Vitalii’s MacBook Pro',
      status: 'online',
      platform: 'macos',
      architecture: 'arm64',
      hostname: 'macbook.local',
      appVersion: '1.0.0',
      workerCount: 3,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorkspacesPage(
          workspaces: const [workspace],
          onAdd: () {},
          onRename: (_) {},
          onUpdate: (_) {},
          onRevoke: (_) {},
          onGrant: (_) {},
        ),
      ),
    ));

    expect(find.text('Vitalii’s MacBook Pro'), findsOneWidget);
    expect(find.textContaining('macOS'), findsOneWidget);
    expect(find.text('Pair Workspace'), findsNothing);
  });
}

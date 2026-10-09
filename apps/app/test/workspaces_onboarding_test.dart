import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

void main() {
  testWidgets('empty Workspaces explains desktop-owned registration',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkspacesPage(
            workspaces: const [],
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onOpenDownloads: () {},
          ),
        ),
      ),
    ));

    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('Connect Workspace'), findsNothing);
    expect(find.text('Pair Workspace'), findsNothing);
    expect(find.text('No Workspaces connected'), findsOneWidget);
    expect(
      find.text(
          'Register a Workspace from the Conclave Workspace desktop app. Its status and Workers will appear here for Space activity.'),
      findsOneWidget,
    );
    expect(find.text('Download Conclave Workspace'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('connected Workspace card remains the unit of the page',
      (tester) async {
    const workspace = AxWorkspace(
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
        body: SingleChildScrollView(
          child: WorkspacesPage(
            workspaces: const [workspace],
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
          ),
        ),
      ),
    ));

    expect(find.text('Vitalii’s MacBook Pro'), findsOneWidget);
    expect(find.textContaining('macOS'), findsNWidgets(2));
    expect(find.text('Pair Workspace'), findsNothing);
  });

  testWidgets('registered offline Workspace stays read-only', (tester) async {
    const workspace = AxWorkspace(
      id: 'workspace-offline',
      name: 'Paired Mac',
      status: 'offline',
      hasRuntimeIdentity: true,
      appVersion: '1.2.0',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkspacesPage(
            workspaces: const [workspace],
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onConnect: (_) async {},
          ),
        ),
      ),
    ));

    expect(find.text('Paired Mac'), findsOneWidget);
    expect(find.text('Connect Machine'), findsNothing);
  });
}

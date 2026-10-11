import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/worker_execution_options.dart';

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
          'Download and register Conclave Workspace to make a Workspace and its Workers available here.'),
      findsOneWidget,
    );
    expect(find.text('Download Conclave Workspace'), findsNothing);
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
    expect(find.textContaining('macOS'), findsOneWidget);
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

  testWidgets('Workspace worker rows show runtime metadata without expansion',
      (tester) async {
    const worker = AxWorker(
      id: 'worker-1',
      workspaceId: 'workspace-1',
      workspaceName: 'Workspace',
      workerTypeId: 'gemini',
      displayName: 'Gemini',
      status: 'ready',
      readinessState: 'ready',
      localConcurrencyLimit: 1,
      providerToolName: 'agy',
      providerToolVersion: '1.2.3',
      profileReleaseVersion: 4,
      executionOptions: AxWorkerExecutionOptions(
        modelSelectionSupported: true,
        modelDiscovery: 'provider_catalog',
        allowsCustomModel: false,
        allowedModelIds: [],
        models: [
          AxWorkerModelOption(
            id: 'gemini-pro',
            name: 'Gemini Pro',
            effort: AxWorkerEffortOptions(
              supported: true,
              values: ['high'],
            ),
          ),
        ],
        modelSwitchSupported: true,
        effort: AxWorkerEffortOptions(
          supported: true,
          values: ['high'],
        ),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkspacesPage(
            workspaces: const [
              AxWorkspace(
                id: 'workspace-1',
                name: 'Workspace',
                status: 'online',
              ),
            ],
            workspaceWorkers: const [worker],
          ),
        ),
      ),
    ));

    expect(find.text('agy 1.2.3'), findsOneWidget);
    expect(find.text('Profile v4'), findsOneWidget);
    expect(find.text('Models: Gemini Pro'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });
}

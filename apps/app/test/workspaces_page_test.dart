import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/features/common/workspace_release.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'studio_fixture_snapshot.dart';

void main() {
  Widget buildTestScaffold(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );
  }

  group('Execution page', () {
    test('detects an available Workspace update', () {
      expect(workspaceUpdateAvailable('1.0.2'), isTrue);
      expect(workspaceUpdateAvailable('1.0.3'), isFalse);
      expect(workspaceUpdateAvailable('not-installed'), isFalse);
    });

    test('parses runtime-reported machine facts', () {
      final workspace = StudioWorkspace.fromJson({
        'id': 'workspace-1',
        'name': 'MacBook Pro',
        'slug': 'macbook-pro',
        'status': 'online',
        'lifecycleStatus': 'pairing',
        'role': 'owner',
        'platform': 'macos',
        'architecture': 'arm64',
        'hostname': 'Vitalii-MacBook-Pro',
        'appVersion': '1.0.3',
        'runtimeCapabilitiesJson': '["dart", "shell"]',
      });

      expect(workspace.platform, 'macos');
      expect(workspace.status, 'pairing');
      expect(workspace.architecture, 'arm64');
      expect(workspace.hostname, 'Vitalii-MacBook-Pro');
      expect(workspace.appVersion, '1.0.3');
      expect(workspace.runtimeCapabilities, ['dart', 'shell']);
    });

    testWidgets('explains the execution model in product language',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        configuredWorkers: const [],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(
          find.textContaining('Workspaces are where AI runs'), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();
      expect(find.textContaining('A Worker is a configured AI/tool identity'),
          findsOneWidget);
      expect(find.textContaining('AI Account'), findsNothing);
      expect(find.textContaining('Credential Profile'), findsNothing);
      expect(find.textContaining('desired state'), findsNothing);
      expect(find.textContaining('package '), findsNothing);
    });

    testWidgets('shows the Execution shell with Workspaces and Workers tabs',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      var addWorkspaceCalled = false;

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        plugins: snapshot.plugins,
        onAdd: () => addWorkspaceCalled = true,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Execution'), findsOneWidget);
      expect(
          find.textContaining('Workspaces are where AI runs'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Workspaces'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Workers'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'AI Accounts'), findsNothing);

      await tester.tap(find.byTooltip('Add Workspace'));
      expect(addWorkspaceCalled, isTrue);

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'A Worker is a configured AI/tool identity. Connect it to the Workspaces where it can run.'),
          findsOneWidget);
      expect(find.text('Connect Account'), findsNothing);
      expect(find.text('Make available'), findsNothing);
      expect(find.text('Remove from Workspace'), findsNothing);
      expect(find.text('View capabilities'), findsNothing);
    });

    testWidgets('clamps legacy account tab indexes to Workers', (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        plugins: snapshot.plugins,
        initialTab: 2,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(
          find.text(
              'A Worker is a configured AI/tool identity. Connect it to the Workspaces where it can run.'),
          findsOneWidget);
      expect(find.text('Add AI Account'), findsNothing);
    });

    testWidgets('renders configured Worker readiness and opens its details',
        (tester) async {
      const worker = StudioConfiguredWorker(
        id: 'configured-1',
        name: 'Codex Personal',
        workerTypeId: 'codex',
        workerTypeName: 'Codex',
        status: 'active',
        defaultModel: 'gpt-5',
        concurrencyLimit: 2,
        bindings: [
          StudioWorkerWorkspaceBinding(
            workspaceId: 'workspace-1',
            workspaceName: 'Development Workspace',
            workspaceStatus: 'online',
            enabled: true,
            localReadiness: 'ready',
            packageStatus: 'ready',
            credentialStatus: 'ready',
            permissionsStatus: 'ready',
          ),
        ],
      );
      StudioConfiguredWorker? opened;
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [],
        workers: const [],
        configuredWorkers: [worker],
        initialTab: 1,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
        onOpenConfiguredWorker: (value) => opened = value,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Codex Personal'), findsOneWidget);
      expect(find.text('1/1 Workspaces ready · concurrency 2'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      await tester.tap(find.text('Open Worker'));
      expect(opened?.id, 'configured-1');
    });

    testWidgets('keeps Add Workspace available when none exist',
        (tester) async {
      var addWorkspaceCalled = false;
      var downloadsOpened = false;
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [],
        workers: const [],
        onAdd: () => addWorkspaceCalled = true,
        onOpenDownloads: () => downloadsOpened = true,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('No workspaces yet.'), findsOneWidget);
      await tester.tap(find.byTooltip('Add Workspace'));
      expect(addWorkspaceCalled, isTrue);
      await tester.tap(find.text('Download Conclave Workspace'));
      expect(downloadsOpened, isTrue);
    });

    testWidgets(
        'allows opening a Workspace detail view from the Workspaces tab',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        plugins: snapshot.plugins,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text(snapshot.agents.first.name).first);
      await tester.pumpAndSettle();
      expect(find.text('Workspace overview'), findsOneWidget);
      expect(find.text('Project access'), findsOneWidget);
      expect(find.byTooltip('Back to Workspaces'), findsOneWidget);
    });

    testWidgets(
        'Workspace detail lists configured Workers and removes AI Accounts',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      const worker = StudioConfiguredWorker(
        id: 'configured-1',
        name: 'Codex Personal',
        workerTypeId: 'codex',
        workerTypeName: 'Codex',
        status: 'active',
        defaultModel: 'Auto',
        concurrencyLimit: 1,
        bindings: [
          StudioWorkerWorkspaceBinding(
            workspaceId: 'agent-macbook',
            workspaceName: 'Development Workspace',
            workspaceStatus: 'ONLINE',
            enabled: true,
            localReadiness: 'ready',
            packageStatus: 'ready',
            credentialStatus: 'ready',
            permissionsStatus: 'ready',
          ),
        ],
      );
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        configuredWorkers: const [worker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text(snapshot.agents.first.name).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      expect(find.text('Codex Personal'), findsOneWidget);
      expect(find.textContaining('Ready to run'), findsOneWidget);
      expect(find.text('AI Accounts'), findsNothing);
      expect(find.byTooltip('Open Worker'), findsOneWidget);
      expect(find.byTooltip('Remove binding'), findsOneWidget);
    });

    testWidgets('renders without layout exceptions in a scroll view',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        plugins: snapshot.plugins,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

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

  group('Workspaces page', () {
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

    testWidgets('shows Workspaces as the single execution destination',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text(snapshot.agents.first.name), findsOneWidget);
      expect(find.textContaining('AI Account'), findsNothing);
      expect(find.textContaining('Credential Profile'), findsNothing);
      expect(find.textContaining('desired state'), findsNothing);
      expect(find.textContaining('package '), findsNothing);
    });

    testWidgets('shows the Workspace list without page-level tabs',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      var addWorkspaceCalled = false;

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        onAdd: () => addWorkspaceCalled = true,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text(snapshot.agents.first.name), findsOneWidget);
      expect(find.widgetWithText(Tab, 'AI Accounts'), findsNothing);

      await tester.tap(find.byTooltip('Add Workspace'));
      expect(addWorkspaceCalled, isTrue);

      expect(find.text('Connect Account'), findsNothing);
      expect(find.text('Make available'), findsNothing);
      expect(find.text('Remove from Workspace'), findsNothing);
      expect(find.text('View capabilities'), findsNothing);
    });

    testWidgets('Workspace page has no detached global Worker inventory',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('Add AI Account'), findsNothing);
      expect(find.text('Workers from your Workspaces'), findsNothing);
    });

    testWidgets('shows Workspace-owned inventory without credential details',
        (tester) async {
      final worker = StudioWorkspaceWorker.fromJson({
        'id': 'local-worker-1',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'codex',
        'name': 'Codex Personal',
        'status': 'ready',
        'authStrategy': 'browser_auth',
        'credentialStatus': 'ready',
        'localConcurrencyLimit': 2,
        'revision': 4,
        'capabilities': ['code'],
        'allowedModels': ['gpt-5.5'],
        'defaultModel': 'gpt-5.5',
      });
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          StudioAgent(
            id: 'workspace-1',
            name: 'Build Mac',
            hostname: 'build-mac.local',
            status: 'online',
            version: '1.2.0',
            pluginCount: 0,
            workerCount: 1,
            activeTaskCount: 0,
            appVersion: '1.2.0',
          ),
        ],
        workspaceWorkers: [worker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Workers'), findsNWidgets(2));
      expect(find.text('Codex Personal'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('Cloud scheduling · Disabled'), findsOneWidget);
      expect(find.text('Auth strategy'), findsNothing);
      expect(find.textContaining('credentialRef'), findsNothing);
      expect(find.text('Add legacy Cloud Worker'), findsNothing);
    });

    testWidgets('keeps Add Workspace available when none exist',
        (tester) async {
      var addWorkspaceCalled = false;
      var downloadsOpened = false;
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [],
        onAdd: () => addWorkspaceCalled = true,
        onOpenDownloads: () => downloadsOpened = true,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('No Workspaces yet'), findsOneWidget);
      await tester.tap(find.byTooltip('Add Workspace'));
      expect(addWorkspaceCalled, isTrue);
      await tester.tap(find.text('Download Conclave Workspace'));
      expect(downloadsOpened, isTrue);
    });

    testWidgets('shows useful Workspace detail inline in its expanded card',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Hostname'), findsOneWidget);
      expect(find.text('App version'), findsOneWidget);
      expect(find.text('Last seen'), findsOneWidget);
      expect(find.text('Active work'), findsOneWidget);
      expect(find.text('Workers'), findsNWidgets(2));
    });

    testWidgets('expands one or two Workspaces and uses an accordion for more',
        (tester) async {
      StudioAgent workspace(String id) => StudioAgent(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            version: '1.0.0',
            pluginCount: 0,
            workerCount: 0,
            activeTaskCount: 0,
          );

      WorkspacesPage page(int count) => WorkspacesPage(
            workspaces: List.generate(count, (index) => workspace('$index')),
            onAdd: () {},
            onRename: (_) {},
            onUpdate: (_) {},
            onRevoke: (_) {},
            onGrant: (_) {},
          );

      await tester.pumpWidget(buildTestScaffold(page(2)));
      await tester.pumpAndSettle();
      expect(find.text('Hostname'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(buildTestScaffold(page(3)));
      await tester.pumpAndSettle();
      expect(find.text('Hostname'), findsOneWidget);
      await tester.ensureVisible(find.text('Workspace 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workspace 2'));
      await tester.pumpAndSettle();
      expect(find.text('Hostname'), findsOneWidget);
      expect(find.text('2.local'), findsOneWidget);
    });

    testWidgets('Workspace deep link expands and focuses the target card',
        (tester) async {
      StudioAgent workspace(String id) => StudioAgent(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            version: '1.0.0',
            pluginCount: 0,
            workerCount: 0,
            activeTaskCount: 0,
          );

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: List.generate(3, (index) => workspace('$index')),
        initialWorkspaceId: '2',
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('2.local'), findsOneWidget);
      final targetCard = tester.widget<Card>(find.byType(Card).last);
      final targetShape = targetCard.shape! as RoundedRectangleBorder;
      expect(targetShape.side.color, isNot(Colors.transparent));
    });

    testWidgets('expanded Workspace lists its locally configured Workers',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      const localWorker = StudioWorkspaceWorker(
        id: 'local-worker-1',
        workspaceId: 'agent-macbook',
        workspaceName: 'MacBook Pro',
        workerTypeId: 'codex',
        name: 'Codex Local',
        status: 'ready',
        authStrategy: 'browser_auth',
        credentialStatus: 'ready',
        localConcurrencyLimit: 2,
        revision: 5,
        capabilities: ['code'],
        allowedModels: ['gpt-5.5'],
      );
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        workspaceWorkers: const [localWorker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Codex Local'), findsOneWidget);
      expect(find.text('Codex Personal'), findsNothing);
      expect(find.text('AI Accounts'), findsNothing);
      expect(find.byTooltip('Remove binding'), findsNothing);
    });

    testWidgets('Worker rows show V7 status and scheduling controls',
        (tester) async {
      final worker = StudioWorkspaceWorker.fromJson({
        'id': 'worker-claude',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'claude-code',
        'name': 'Claude on Build Mac',
        'status': 'ready',
        'authStrategy': 'browser_auth',
        'credentialStatus': 'expired',
        'localConcurrencyLimit': 2,
        'revision': 3,
        'capabilities': ['code'],
        'allowedModels': ['claude-sonnet'],
        'schedulingState': 'enabled',
        'defaultModel': 'claude-sonnet-4',
      });
      final actions = <String>[];
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          StudioAgent(
            id: 'workspace-1',
            name: 'Build Mac',
            hostname: 'build-mac.local',
            status: 'online',
            version: '1.0.0',
            pluginCount: 0,
            workerCount: 1,
            activeTaskCount: 0,
          ),
        ],
        workspaceWorkers: [worker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
        onWorkspaceWorkerScheduling: (worker, action) async {
          actions.add(action);
        },
      )));
      await tester.pumpAndSettle();

      expect(find.text('Claude on Build Mac'), findsOneWidget);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('Model · claude-sonnet-4'), findsOneWidget);
      expect(find.text('Ready locally'), findsOneWidget);
      expect(find.text('Sign-in expired'), findsOneWidget);
      expect(find.text('Cloud scheduling · Enabled'), findsOneWidget);
      expect(
        find.text(
            'Worker configuration and authentication are managed in Conclave Workspace on this computer.'),
        findsOneWidget,
      );
      expect(find.text('Authentication · browser_auth'), findsNothing);

      await tester.tap(find.text('Claude on Build Mac'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Local attention'), findsOneWidget);
      expect(
          find.textContaining(
              'Complete sign-in or setup in Conclave Workspace on Build Mac.'),
          findsOneWidget);
      expect(find.text('Allowed models'), findsNothing);

      await tester.tap(find.text('Disable'));
      await tester.tap(find.text('Drain'));
      expect(actions, ['disable', 'drain']);
    });

    testWidgets('Workers are grouped only under their owning Workspace ID',
        (tester) async {
      StudioAgent workspace(String id) => StudioAgent(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            version: '1.0.0',
            pluginCount: 0,
            workerCount: 1,
            activeTaskCount: 0,
          );
      StudioWorkspaceWorker worker(String id, String workspaceId) =>
          StudioWorkspaceWorker(
            id: id,
            workspaceId: workspaceId,
            workspaceName: 'Workspace $workspaceId',
            workerTypeId: 'ollama',
            name: 'Worker $id',
            status: 'ready',
            authStrategy: 'none',
            credentialStatus: 'not_required',
            localConcurrencyLimit: 1,
            revision: 1,
            capabilities: const [],
            allowedModels: const [],
          );

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [workspace('one'), workspace('two')],
        workspaceWorkers: [worker('one', 'one'), worker('two', 'two')],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      final cards = find.byType(Card);
      final firstCard = tester.widget<Card>(cards.at(0));
      final secondCard = tester.widget<Card>(cards.at(1));
      expect(firstCard, isNot(same(secondCard)));
      expect(
          find.descendant(of: cards.at(0), matching: find.text('Worker one')),
          findsOneWidget);
      expect(
          find.descendant(of: cards.at(0), matching: find.text('Worker two')),
          findsNothing);
      expect(
          find.descendant(of: cards.at(1), matching: find.text('Worker two')),
          findsOneWidget);
    });

    testWidgets('disabled Worker exposes the Enable scheduling action',
        (tester) async {
      final actions = <String>[];
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          StudioAgent(
            id: 'workspace-enable',
            name: 'Enable Workspace',
            hostname: 'enable.local',
            status: 'online',
            version: '1.0.0',
            pluginCount: 0,
            workerCount: 1,
            activeTaskCount: 0,
          ),
        ],
        workspaceWorkers: const [
          StudioWorkspaceWorker(
            id: 'worker-disabled',
            workspaceId: 'workspace-enable',
            workspaceName: 'Enable Workspace',
            workerTypeId: 'ollama',
            name: 'Local model',
            status: 'ready',
            authStrategy: 'local_endpoint',
            credentialStatus: 'not_required',
            localConcurrencyLimit: 1,
            revision: 1,
            capabilities: [],
            allowedModels: [],
          ),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
        onWorkspaceWorkerScheduling: (_, action) async => actions.add(action),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enable'));
      expect(actions, ['enable']);
    });

    testWidgets('renders without layout exceptions in a scroll view',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.agents,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(tester.takeException(), isNull);
    });
  });
}

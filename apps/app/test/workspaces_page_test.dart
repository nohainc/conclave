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

    testWidgets('shows the paired machine facts and live Workspace summary',
        (tester) async {
      final workspace = StudioWorkspace.fromJson({
        'id': 'workspace-paired',
        'name': 'Vitalii’s MacBook Pro',
        'status': 'online',
        'platform': 'macos',
        'architecture': 'arm64',
        'hostname': 'vitalii-macbook.local',
        'appVersion': '1.4.2',
        'runtimeCapabilitiesJson':
            '{"os":"macos","arch":"arm64","appVersion":"1.4.2","supportedRuntimes":["dart"],"maxConcurrentWorkers":2}',
        'lastSeen': '2026-09-26T12:30:00.000Z',
        'workerCount': 3,
        'activeTaskCount': 2,
        'hasRuntimeIdentity': 1,
      });

      expect(workspace.runtimeCapabilities,
          ['dart', 'Up to 2 concurrent Workers']);

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [workspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Vitalii’s MacBook Pro'), findsOneWidget);
      expect(find.text('vitalii-macbook.local'), findsOneWidget);
      expect(find.text('1.4.2'), findsOneWidget);
      expect(find.text('dart · Up to 2 concurrent Workers'), findsOneWidget);
      expect(find.textContaining('3 Workers'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('2026-09-26T12:30:00.000Z'), findsOneWidget);
    });

    testWidgets('shows Workspaces as the single execution destination',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text(snapshot.workspaces.first.name), findsOneWidget);
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
        workspaces: snapshot.workspaces,
        onAdd: () => addWorkspaceCalled = true,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text(snapshot.workspaces.first.name), findsOneWidget);
      expect(find.widgetWithText(Tab, 'AI Accounts'), findsNothing);

      await tester.tap(find.byTooltip('Connect Workspace'));
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
        workspaces: snapshot.workspaces,
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
      final worker = StudioWorker.fromJson({
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
          StudioWorkspace(
            id: 'workspace-1',
            name: 'Build Mac',
            hostname: 'build-mac.local',
            status: 'online',
            appVersion: '1.2.0',
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

    testWidgets('keeps Connect Workspace available when none exist',
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

      expect(find.text('No Workspaces connected'), findsOneWidget);
      await tester.tap(find.text('Connect Workspace'));
      expect(addWorkspaceCalled, isTrue);
      await tester.tap(find.text('Download Conclave Workspace'));
      expect(downloadsOpened, isTrue);
    });

    testWidgets('shows useful Workspace detail inline in its expanded card',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
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
      // A single Workspace opens with runtime facts visible immediately.
      expect(find.text('development-agent.local'), findsOneWidget);
    });

    testWidgets('expands one or two Workspaces and uses an accordion for more',
        (tester) async {
      StudioWorkspace workspace(String id) => StudioWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            appVersion: '1.0.0',
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
      StudioWorkspace workspace(String id) => StudioWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            appVersion: '1.0.0',
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

    testWidgets('expanded Workspace lists its V7 Worker projections',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      const localWorker = StudioWorker(
        id: 'local-worker-1',
        workspaceId: 'workspace-macbook',
        workspaceName: 'Development Workspace',
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
        workspaces: snapshot.workspaces,
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
      final worker = StudioWorker.fromJson({
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
          StudioWorkspace(
            id: 'workspace-1',
            name: 'Build Mac',
            hostname: 'build-mac.local',
            status: 'online',
            appVersion: '1.0.0',
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
            'Configure and authenticate Workers in Conclave Workspace on this computer. Synced Workers appear here for Cloud scheduling.'),
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

      await tester.ensureVisible(find.text('Disable'));
      await tester.tap(find.text('Disable'));
      await tester.ensureVisible(find.text('Drain'));
      await tester.tap(find.text('Drain'));
      expect(actions, ['disable', 'drain']);
    });

    testWidgets('Workers are grouped only under their owning Workspace ID',
        (tester) async {
      StudioWorkspace workspace(String id) => StudioWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            appVersion: '1.0.0',
            workerCount: 1,
            activeTaskCount: 0,
          );
      StudioWorker worker(String id, String workspaceId) => StudioWorker(
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

    testWidgets('needs-authentication points to Conclave Workspace desktop',
        (tester) async {
      final worker = StudioWorker.fromJson({
        'id': 'worker-needs-auth',
        'workspaceId': 'workspace-auth',
        'workspaceName': 'Auth Mac',
        'workerTypeId': 'codex',
        'name': 'Codex Personal',
        'status': 'needs_attention',
        'authStrategy': 'browser_auth',
        'credentialStatus': 'needs_authentication',
        'localConcurrencyLimit': 1,
        'revision': 1,
        'capabilities': ['code'],
        'allowedModels': [],
      });
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          StudioWorkspace(
            id: 'workspace-auth',
            name: 'Auth Mac',
            status: 'online',
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

      expect(find.text('Sign-in required'), findsOneWidget);
      await tester.tap(find.text('Codex Personal'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Complete sign-in or setup in Conclave Workspace on Auth Mac.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('disconnected Workspace offers the Connect Machine flow',
        (tester) async {
      StudioWorkspace? connectedWorkspace;
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          StudioWorkspace(
            id: 'workspace-offline',
            name: 'Offline Mac',
            status: 'offline',
            appVersion: '1.4.0',
          ),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
        onConnect: (workspace) async => connectedWorkspace = workspace,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Offline'), findsNWidgets(2));
      expect(find.text('Connect Machine'), findsOneWidget);
      await tester.ensureVisible(find.text('Connect Machine'));
      await tester.tap(find.text('Connect Machine'));
      expect(connectedWorkspace?.id, 'workspace-offline');
    });

    testWidgets('zero Workers explains local desktop configuration',
        (tester) async {
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          StudioWorkspace(id: 'workspace-empty', name: 'New Mac'),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'No Workers have synced yet. Configure your first Worker in Conclave Workspace on this computer.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('disabled Worker exposes the Enable scheduling action',
        (tester) async {
      final actions = <String>[];
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          StudioWorkspace(
            id: 'workspace-enable',
            name: 'Enable Workspace',
            hostname: 'enable.local',
            status: 'online',
            appVersion: '1.0.0',
            workerCount: 1,
            activeTaskCount: 0,
          ),
        ],
        workspaceWorkers: const [
          StudioWorker(
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

      await tester.ensureVisible(find.text('Enable'));
      await tester.tap(find.text('Enable'));
      expect(actions, ['enable']);
    });

    testWidgets('renders without layout exceptions in a scroll view',
        (tester) async {
      final snapshot = studioFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
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

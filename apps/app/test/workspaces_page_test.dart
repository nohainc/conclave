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
        'activeTransport': 'http_long_poll',
        'connectionMode': 'Connected · HTTPS fallback',
        'runtimeCapabilitiesJson': '["dart", "shell"]',
      });

      expect(workspace.platform, 'macos');
      expect(workspace.status, 'pairing');
      expect(workspace.architecture, 'arm64');
      expect(workspace.hostname, 'Vitalii-MacBook-Pro');
      expect(workspace.appVersion, '1.0.3');
      expect(workspace.activeTransport, 'http_long_poll');
      expect(workspace.connectionMode, 'Connected · HTTPS fallback');
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
        'activeTransport': 'http_long_poll',
        'connectionMode': 'Connected · HTTPS fallback',
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
      expect(find.text('Connected · HTTPS fallback'), findsOneWidget);
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

    testWidgets('shows the Workspace list without lifecycle controls',
        (tester) async {
      final snapshot = studioFixtureSnapshot();

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
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

      expect(find.byTooltip('Connect Workspace'), findsNothing);
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Update Workspace'), findsNothing);
      expect(find.text('Unpair Workspace'), findsNothing);

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
        'workerTypeId': 'chatgpt',
        'name': 'ChatGPT Personal',
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
      expect(find.text('ChatGPT'), findsNWidgets(2));
      expect(find.textContaining('Cloud scheduling'), findsNothing);
      expect(find.text('Auth strategy'), findsNothing);
      expect(find.textContaining('credentialRef'), findsNothing);
      expect(find.text('Add legacy Cloud Worker'), findsNothing);
    });

    testWidgets('empty state explains desktop registration and offers download',
        (tester) async {
      var downloadsOpened = false;
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [],
        onOpenDownloads: () => downloadsOpened = true,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('No Workspaces connected'), findsOneWidget);
      expect(find.text('Connect Workspace'), findsNothing);
      expect(
          find.textContaining(
              'Register a Workspace from the Conclave Workspace desktop app'),
          findsOneWidget);
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
        workerTypeId: 'chatgpt',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 2,
        capabilities: ['code'],
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
      expect(find.text('ChatGPT'), findsNWidgets(2));
      expect(find.text('Codex Personal'), findsNothing);
      expect(find.text('AI Accounts'), findsNothing);
      expect(find.byTooltip('Remove binding'), findsNothing);
    });

    testWidgets('Worker rows show safe readiness only', (tester) async {
      final worker = StudioWorker.fromJson({
        'id': 'worker-chatgpt',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'chatgpt',
        'status': 'ready',
        'readinessState': 'ready',
        'localConcurrencyLimit': 2,
        'capabilities': ['code'],
        'authStrategy': 'must-not-display',
        'credentialStatus': 'must-not-display',
        'model': 'must-not-display',
      });
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
      )));
      await tester.pumpAndSettle();

      expect(find.text('ChatGPT'), findsNWidgets(2));
      expect(find.text('Ready locally'), findsOneWidget);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
      expect(find.textContaining('Model'), findsNothing);
      expect(
        find.text(
            'Conclave Workspace reports local readiness. Choose Workers for a Project or Workstream in its Execution settings.'),
        findsOneWidget,
      );
      expect(find.text('Authentication · browser_auth'), findsNothing);

      await tester.tap(find.text('ChatGPT').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Local attention'), findsNothing);
      expect(find.text('Allowed models'), findsNothing);

      expect(find.text('Disable'), findsNothing);
      expect(find.text('Drain'), findsNothing);
    });

    testWidgets('expanded Worker details use v8 runtime terminology',
        (tester) async {
      final worker = StudioWorker.fromJson({
        'id': 'worker-chatgpt',
        'workspaceId': 'workspace-1',
        'workerTypeId': 'chatgpt',
        'status': 'ready',
        'readinessState': 'ready',
        'localConcurrencyLimit': 1,
        'capabilities': ['text'],
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 4,
        'providerToolName': 'Codex CLI',
        'providerToolVersion': '0.190.0',
      });

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
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      final workerRow =
          find.byKey(const Key('workspace-worker-row-worker-chatgpt'));
      await tester.ensureVisible(workerRow);
      await tester.tap(workerRow);
      await tester.pumpAndSettle();

      expect(find.text('Engine · 1.0.0'), findsOneWidget);
      expect(find.text('Integration · chatgpt-codex@4'), findsOneWidget);
      expect(find.text('Provider CLI · Codex CLI'), findsOneWidget);
      expect(find.text('Provider CLI version · 0.190.0'), findsOneWidget);
      expect(find.text('Adapter'), findsNothing);
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
      StudioWorker worker(String id, String workspaceId, String workerTypeId) =>
          StudioWorker(
            id: id,
            workspaceId: workspaceId,
            workerTypeId: workerTypeId,
            status: 'ready',
            readinessState: 'ready',
            localConcurrencyLimit: 1,
            capabilities: const [],
          );

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [workspace('one'), workspace('two')],
        workspaceWorkers: [
          worker('one', 'one', 'chatgpt'),
          worker('two', 'two', 'gemini'),
        ],
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
      expect(find.descendant(of: cards.at(0), matching: find.text('ChatGPT')),
          findsNWidgets(2));
      expect(find.descendant(of: cards.at(0), matching: find.text('Gemini')),
          findsNothing);
      expect(find.descendant(of: cards.at(1), matching: find.text('Gemini')),
          findsNWidgets(2));
    });

    testWidgets('needs-attention points to Conclave Workspace desktop',
        (tester) async {
      final worker = StudioWorker.fromJson({
        'id': 'worker-needs-auth',
        'workspaceId': 'workspace-auth',
        'workspaceName': 'Auth Mac',
        'workerTypeId': 'chatgpt',
        'name': 'ChatGPT Personal',
        'status': 'needs_attention',
        'attentionReasonCode': 'authentication_required',
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

      expect(find.text('Needs local attention'), findsOneWidget);
      await tester.tap(find.text('ChatGPT').first);
      await tester.pumpAndSettle();
      expect(
          find.textContaining(
              'Resolve authentication_required in Conclave Workspace.'),
          findsOneWidget);
    });

    testWidgets('disconnected Workspace stays read-only', (tester) async {
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
      expect(find.text('Connect Machine'), findsNothing);
      expect(connectedWorkspace, isNull);
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

    testWidgets('Workspace inventory does not expose usage controls',
        (tester) async {
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
            workerTypeId: 'ollama',
            status: 'ready',
            readinessState: 'ready',
            localConcurrencyLimit: 1,
            capabilities: [],
          ),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Enable'), findsNothing);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
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

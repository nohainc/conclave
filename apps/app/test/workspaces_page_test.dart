import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/features/common/workspace_release.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

import 'ax_fixture_snapshot.dart';

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
      final workspace = AxWorkspace.fromJson({
        'id': 'workspace-1',
        'name': 'MacBook Pro',
        'slug': 'macbook-pro',
        'status': 'online',
        'hasRuntimeIdentity': false,
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
      expect(workspace.status, 'online');
      expect(workspace.architecture, 'arm64');
      expect(workspace.hostname, 'Vitalii-MacBook-Pro');
      expect(workspace.appVersion, '1.0.3');
      expect(workspace.activeTransport, 'http_long_poll');
      expect(workspace.connectionMode, 'Connected · HTTPS fallback');
      expect(workspace.runtimeCapabilities, ['dart', 'shell']);
    });

    testWidgets('shows registered machine facts and live Workspace summary',
        (tester) async {
      final workspace = AxWorkspace.fromJson({
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
      )));
      await tester.pumpAndSettle();

      expect(find.text('Vitalii’s MacBook Pro'), findsOneWidget);
      expect(find.text('macOS · Apple Silicon · vitalii-macbook.local'),
          findsOneWidget);
      expect(find.text('Connected · HTTPS fallback'), findsNothing);
      expect(find.text('1.4.2'), findsNothing);
      expect(find.text('dart · Up to 2 concurrent Workers'), findsNothing);
      expect(find.textContaining('3 Workers'), findsNothing);
      expect(find.text('Active work'), findsNothing);
      expect(find.text('Runtime capabilities'), findsNothing);
      expect(find.text('2026-09-26T12:30:00.000Z'), findsNothing);
    });

    testWidgets('shows Workspaces as the single execution destination',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(
        find.text(
            'Workspaces are connected execution environments. Workers are the AI integrations configured on each Workspace.'),
        findsOneWidget,
      );
      expect(find.byType(TabBar), findsNothing);
      expect(find.text(snapshot.workspaces.first.name), findsOneWidget);
      expect(find.textContaining('AI Account'), findsNothing);
      expect(find.textContaining('Credential Profile'), findsNothing);
      expect(find.textContaining('desired state'), findsNothing);
      expect(find.textContaining('package '), findsNothing);
    });

    testWidgets('shows the Workspace list without lifecycle controls',
        (tester) async {
      final snapshot = axFixtureSnapshot();

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text(snapshot.workspaces.first.name), findsOneWidget);

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
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('Add AI Account'), findsNothing);
      expect(find.text('Workers from your Workspaces'), findsNothing);
    });

    testWidgets('shows Workspace-owned inventory without credential details',
        (tester) async {
      final worker = AxWorker.fromJson({
        'id': 'local-worker-1',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
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
          AxWorkspace(
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
      )));
      await tester.pumpAndSettle();
      expect(find.text('Workers'), findsOneWidget);
      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
      expect(find.text('Auth strategy'), findsNothing);
      expect(find.textContaining('credentialRef'), findsNothing);
      expect(find.text('Add legacy Cloud Worker'), findsNothing);
    });

    testWidgets('empty state explains Workspace registration', (tester) async {
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [],
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('No Workspaces connected'), findsOneWidget);
      expect(find.text('Connect Workspace'), findsNothing);
      expect(
          find.textContaining(
              'Download and register Conclave Workspace to make a Workspace and its Workers available here.'),
          findsOneWidget);
      expect(find.text('Download Conclave Workspace'), findsNothing);
    });

    testWidgets('shows Workspace machine and Workers without extra details',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Hostname'), findsNothing);
      expect(find.text('App version'), findsNothing);
      expect(find.text('Last seen'), findsNothing);
      expect(find.text('Connection status'), findsNothing);
      expect(find.text('Machine'), findsNothing);
      expect(find.text('Active work'), findsNothing);
      expect(find.text('Workers'), findsOneWidget);
      expect(
          find.textContaining('development-workspace.local'), findsOneWidget);
    });

    testWidgets('shows all Workspace cards without a Workspace expansion',
        (tester) async {
      AxWorkspace workspace(String id) => AxWorkspace(
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
          );

      await tester.pumpWidget(buildTestScaffold(page(2)));
      await tester.pumpAndSettle();
      expect(find.text('0.local'), findsOneWidget);
      expect(find.text('1.local'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(buildTestScaffold(page(3)));
      await tester.pumpAndSettle();
      expect(find.text('2.local'), findsOneWidget);
    });

    testWidgets(
        'Workspace cards are informational and use two columns when wide',
        (tester) async {
      AxWorkspace workspace(String id) => AxWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
          );

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1000, 800)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: WorkspacesPage(
                workspaces: [workspace('one'), workspace('two')],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final header = tester.widget<ListTile>(find.byType(ListTile).first);
      expect(header.onTap, isNull);

      final cards = find.byType(Card);
      expect(cards, findsNWidgets(2));
      expect(tester.getTopLeft(cards.at(1)).dx,
          greaterThan(tester.getTopLeft(cards.at(0)).dx));
      expect(tester.getTopLeft(cards.at(1)).dy,
          closeTo(tester.getTopLeft(cards.at(0)).dy, 1));
    });

    testWidgets('Workspace deep link focuses the target card', (tester) async {
      AxWorkspace workspace(String id) => AxWorkspace(
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
      )));
      await tester.pumpAndSettle();

      expect(find.text('2.local'), findsOneWidget);
      final targetCard = tester.widget<Card>(find.byType(Card).last);
      final targetShape = targetCard.shape! as RoundedRectangleBorder;
      expect(targetShape.side.color, isNot(Colors.transparent));
    });

    testWidgets('expanded Workspace lists its Worker projections',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      final localWorker = const AxWorker(
        id: 'local-worker-1',
        workspaceId: 'workspace-macbook',
        workspaceName: 'MacBook Pro',
        workerTypeId: 'chatgpt',
        displayName: 'ChatGPT',
        description: 'ChatGPT coding assistant',
        status: 'ready',
        readinessState: 'ready',
        localConcurrencyLimit: 2,
        capabilities: ['code'],
      );
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        workspaceWorkers: [localWorker],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.text('Codex Personal'), findsNothing);
      expect(find.byTooltip('Remove binding'), findsNothing);
    });

    testWidgets('Worker rows show safe readiness only', (tester) async {
      final worker = AxWorker.fromJson({
        'id': 'worker-chatgpt',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
        'readinessState': 'ready',
        'localConcurrencyLimit': 2,
        'capabilities': ['code'],
        'authStrategy': 'must-not-display',
        'credentialStatus': 'must-not-display',
        'model': 'must-not-display',
      });
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
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
      )));
      await tester.pumpAndSettle();

      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.text('Ready locally'), findsNothing);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
      expect(find.textContaining('Model'), findsNothing);
      expect(find.text('Workers'), findsOneWidget);
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
      final worker = AxWorker.fromJson({
        'id': 'worker-chatgpt',
        'workspaceId': 'workspace-1',
        'workspaceName': 'Build Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
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
          AxWorkspace(
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
    });

    testWidgets('Workers are grouped only under their owning Workspace ID',
        (tester) async {
      AxWorkspace workspace(String id) => AxWorkspace(
            id: id,
            name: 'Workspace $id',
            hostname: '$id.local',
            status: 'online',
            appVersion: '1.0.0',
            workerCount: 1,
            activeTaskCount: 0,
          );
      AxWorker worker(String id, String workspaceId, String workerTypeId,
              String displayName) =>
          AxWorker(
            id: id,
            workspaceId: workspaceId,
            workspaceName: 'Workspace $workspaceId',
            workerTypeId: workerTypeId,
            displayName: displayName,
            description: '$displayName coding assistant',
            status: 'ready',
            readinessState: 'ready',
            localConcurrencyLimit: 1,
            capabilities: const [],
          );

      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: [workspace('one'), workspace('two')],
        workspaceWorkers: [
          worker('one', 'one', 'chatgpt', 'ChatGPT'),
          worker('two', 'two', 'gemini', 'Gemini'),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      final cards = find.byType(Card);
      final firstCard = tester.widget<Card>(cards.at(0));
      final secondCard = tester.widget<Card>(cards.at(1));
      expect(firstCard, isNot(same(secondCard)));
      expect(find.descendant(of: cards.at(0), matching: find.text('ChatGPT')),
          findsOneWidget);
      expect(find.descendant(of: cards.at(0), matching: find.text('Gemini')),
          findsNothing);
      expect(find.descendant(of: cards.at(1), matching: find.text('Gemini')),
          findsOneWidget);
    });

    testWidgets('needs-attention points to Conclave Workspace desktop',
        (tester) async {
      final worker = AxWorker.fromJson({
        'id': 'worker-needs-auth',
        'workspaceId': 'workspace-auth',
        'workspaceName': 'Auth Mac',
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'description': 'ChatGPT coding assistant',
        'name': 'ChatGPT Personal',
        'readinessState': 'sign_in_required',
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
          AxWorkspace(
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
      )));
      await tester.pumpAndSettle();

      expect(find.text('Provider sign-in required'), findsNothing);
      await tester.tap(find.text('ChatGPT').first);
      await tester.pumpAndSettle();
      expect(
          find.textContaining(
              'Resolve authentication_required in Conclave Workspace.'),
          findsOneWidget);
    });

    testWidgets('disconnected Workspace stays read-only', (tester) async {
      AxWorkspace? connectedWorkspace;
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
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
        onConnect: (workspace) async => connectedWorkspace = workspace,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Connect Machine'), findsNothing);
      expect(connectedWorkspace, isNull);
    });

    testWidgets('zero Workers explains local desktop configuration',
        (tester) async {
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(id: 'workspace-empty', name: 'New Mac'),
        ],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'No Workers are available for this Workspace yet. Configure Workers in Conclave Workspace on this computer.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Workspace inventory does not expose usage controls',
        (tester) async {
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: const [
          AxWorkspace(
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
          AxWorker(
            id: 'worker-disabled',
            workspaceId: 'workspace-enable',
            workspaceName: 'Enable Mac',
            workerTypeId: 'ollama',
            displayName: 'Ollama',
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
      )));
      await tester.pumpAndSettle();

      expect(find.text('Enable'), findsNothing);
      expect(find.textContaining('Cloud scheduling'), findsNothing);
    });

    testWidgets('renders without layout exceptions in a scroll view',
        (tester) async {
      final snapshot = axFixtureSnapshot();
      await tester.pumpWidget(buildTestScaffold(WorkspacesPage(
        workspaces: snapshot.workspaces,
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(tester.takeException(), isNull);
    });
  });
}

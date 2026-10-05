import 'dart:io';

import 'package:conclave_profile_lab/views/workspaces_view.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late ProfileLabPaths tempPaths;
  late ProfileLabController controller;

  setUp(() async {
    final tempDir =
        await Directory.systemTemp.createTemp('profile_lab_ws_test_');
    tempDirectory = tempDir;
    tempPaths = ProfileLabPaths(homeDirectory: tempDir.path);
    await tempPaths.ensureDirectoriesExist();

    controller = ProfileLabController(
      paths: tempPaths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(tempPaths),
    );
    controller.workspaceChannels = [
      {
        'id': 'ws-dev-1',
        'name': 'MacBook Pro Test Lab',
        'channel': 'testing',
        'hostname': 'macbook-dev.local',
        'platform': 'darwin',
        'appVersion': '0.8.2',
      },
      {
        'id': 'ws-beta-1',
        'name': 'CI Build Worker #3',
        'channel': 'beta',
        'hostname': 'ci-runner-3.conclave.test',
        'platform': 'linux',
        'appVersion': '0.8.1',
      },
      {
        'id': 'ws-prod-1',
        'name': 'Production Workspace Main',
        'channel': 'stable',
        'hostname': 'prod-worker-1.conclave.test',
        'platform': 'linux',
        'appVersion': '0.8.0',
      },
    ];
  });

  testWidgets('renders compact Workspace table and channel counts',
      (WidgetTester tester) async {
    controller.setArea(LabArea.workspaces);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspacesView(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Workspace rollout'), findsOneWidget);
    for (final heading in [
      'Workspace',
      'Host',
      'App version',
      'Connection',
      'Channel'
    ]) {
      expect(find.text(heading), findsOneWidget);
    }
    expect(find.text('CONTROLLED WORKSPACE ROLLOUT PATH'), findsNothing);

    // Verify workspace items rendered
    expect(find.text('MacBook Pro Test Lab'), findsOneWidget);
    expect(find.text('CI Build Worker #3'), findsOneWidget);
    expect(find.text('Production Workspace Main'), findsOneWidget);

    // Verify count badges
    expect(find.text('Total: 3'), findsOneWidget);
    expect(find.text('Testing: 1'), findsOneWidget);
    expect(find.text('Beta: 1'), findsOneWidget);
    expect(find.text('Stable: 1'), findsOneWidget);
  });

  tearDown(() async {
    controller.dispose();
    await tempDirectory.delete(recursive: true);
  });

  testWidgets(
      'channel changes require confirmation and Cancel preserves assignment',
      (tester) async {
    final api = _StepUpRequiredApiClient();
    controller.setApiClientForTesting(api);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WorkspacesView(controller: controller))));
    await tester.ensureVisible(
        find.byKey(const ValueKey('workspace-channel-ws-dev-1')));
    await tester.tap(find.byKey(const ValueKey('workspace-channel-ws-dev-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stable').last);
    await tester.pumpAndSettle();
    expect(find.text('Change rollout channel?'), findsOneWidget);
    expect(api.calls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls, 0);
    expect(controller.workspaceChannels.first['channel'], 'testing');
  });

  testWidgets('offers passkey step-up when Stable assignment requires it',
      (WidgetTester tester) async {
    controller.setApiClientForTesting(_StepUpRequiredApiClient());
    controller.setArea(LabArea.workspaces);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkspacesView(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
        find.byKey(const ValueKey('workspace-channel-ws-dev-1')));
    await tester.tap(find.byKey(const ValueKey('workspace-channel-ws-dev-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stable').last);
    await tester.pumpAndSettle();

    expect(find.text('Change rollout channel?'), findsOneWidget);
    await tester.tap(find.text('Change channel'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Complete a passkey verification in Conclave in your browser, then bind it to this Profile Lab session.',
      ),
      findsOneWidget,
    );
    expect(find.text('Bind passkey'), findsOneWidget);
  });
}

class _StepUpRequiredApiClient extends ProfileAdminApiClient {
  _StepUpRequiredApiClient() : super(baseUrl: 'http://127.0.0.1:8787');

  int calls = 0;
  @override
  Future<Map<String, dynamic>> setWorkspaceChannel({
    required String workspaceId,
    required String channel,
  }) async {
    calls++;
    throw StateError('Fresh strong authentication required');
  }
}

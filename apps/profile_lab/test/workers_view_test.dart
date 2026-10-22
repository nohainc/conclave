import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/views/workers_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImmediateApi extends ProfileAdminApiClient {
  _ImmediateApi() : super(baseUrl: 'http://localhost');

  @override
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async => [];

  @override
  Future<List<ProfileLabAuditEventReadModel>> fetchAudit(
          [String? definitionId]) async =>
      [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows Gemini beside ChatGPT before any Gemini release exists',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final temp = Directory.systemTemp.createTempSync('gemini-catalog-view-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final paths = ProfileLabPaths(homeDirectory: temp.path);
    final controller = ProfileLabController(
        paths: paths,
        sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
        apiClientOverride: _ImmediateApi());
    addTearDown(controller.dispose);
    controller.cloudWorkers = [
      {
        'workerTypeId': 'chatgpt',
        'displayName': 'ChatGPT',
        'profileDefinitionId': 'chatgpt-codex',
        'providerToolName': 'codex'
      },
      {
        'workerTypeId': 'gemini',
        'displayName': 'Gemini',
        'profileDefinitionId': 'gemini-antigravity',
        'providerToolName': 'agy'
      },
    ];
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: WorkersView(controller: controller))));
    expect(
        find.descendant(
            of: find.byKey(const Key('worker-tab-chatgpt')),
            matching: find.text('ChatGPT')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('worker-tab-gemini')),
            matching: find.text('Gemini')),
        findsOneWidget);
    expect(find.text('agy'), findsOneWidget);
    expect(find.text('codex'), findsOneWidget);
    expect(find.byKey(const Key('worker-selector-gemini')), findsOneWidget);
    expect(find.byKey(const Key('worker-selector-chatgpt')), findsOneWidget);
  });

  testWidgets(
      'Worker selection opens the compact header and editor workbench directly',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tempDir =
        Directory.systemTemp.createTempSync('workers_overview_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final paths = ProfileLabPaths(homeDirectory: tempDir.path);

    final controller = ProfileLabController(
      paths: paths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
      apiClientOverride: _ImmediateApi(),
    )
      ..currentSession = ProfileLabSession(
        credential: 'test-credential',
        sessionId: 'test-session',
        userId: 'test-user',
        displayName: 'Test User',
        email: 'test@example.invalid',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      )
      ..cloudWorkers = [
        {
          'workerTypeId': 'chatgpt',
          'profileDefinitionId': 'chatgpt-codex',
          'displayName': 'ChatGPT',
          'description': 'Codex CLI worker',
          'providerToolName': 'codex',
          'currentRevision': 4,
        },
      ];
    addTearDown(() async {
      controller.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkersView(controller: controller)),
      ),
    );
    await tester.pump();

    // Select ChatGPT worker directly on controller to verify UI presentation
    controller.selectedCloudWorker = controller.cloudWorkers.first;
    controller.selectedDefinitionId = 'chatgpt-codex';
    controller.selectedCloudDefinition = {
      'profileDefinitionId': 'chatgpt-codex',
      'displayName': 'chatgpt-codex profile',
      'channels': {'stable': 1},
    };
    controller.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Verify sidebar displays Worker name, CLI name, and status.
    expect(find.byKey(const Key('worker-selector-chatgpt')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('worker-selector-chatgpt')),
            matching: find.text('ChatGPT')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('worker-tab-chatgpt')),
            matching: find.text('ChatGPT')),
        findsOneWidget);
    expect(find.text('codex'), findsOneWidget);

    // Verify top/first panel header with worker name, CLI name, and profile chips was deleted.
    expect(find.text('CLI · codex'), findsNothing);
    expect(find.text('Profile not published'), findsNothing);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Draft & Test'), findsNothing);
  });
}

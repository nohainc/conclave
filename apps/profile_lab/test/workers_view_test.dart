import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/views/workers_view.dart';
import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImmediateApi extends ProfileAdminApiClient {
  _ImmediateApi() : super(baseUrl: 'http://localhost');

  @override
  Future<ProfileLabDefinitionReadModel> fetchDefinition(String id) async {
    return ProfileLabDefinitionReadModel.fromJson({
      'profileDefinitionId': id,
      'displayName': '$id profile',
      'channels': {'stable': 1},
    });
  }

  @override
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async => [];

  @override
  Future<List<ProfileLabWorkspaceChannelReadModel>>
      listWorkspaceChannels() async => [];

  @override
  Future<List<ProfileLabReleaseReadModel>> fetchReleases(
          String profileDefinitionId) async =>
      [];

  @override
  Future<List<ProfileLabAuditEventReadModel>> fetchAudit(
          [String? definitionId]) async =>
      [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Create Worker uses catalog stages and canonical capabilities',
      (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('workers_view_test_');
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
          'workerTypeId': 'existing-worker',
          'displayName': 'Existing Worker',
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
    await tester.tap(find.byTooltip('Create Worker + Definition'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Testing'), findsOneWidget);
    expect(find.text('Draft'), findsNothing);
    expect(find.byType(FilterChip), findsNWidgets(8));
    for (final capability in canonicalWorkerCapabilities) {
      expect(find.widgetWithText(FilterChip, capability), findsOneWidget);
    }
    expect(
      tester
          .widget<FilterChip>(
            find.widgetWithText(FilterChip, 'text'),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(
            find.widgetWithText(FilterChip, 'workstream_write'),
          )
          .selected,
      isFalse,
    );

    final imageCapability = find.widgetWithText(FilterChip, 'image');
    await tester.ensureVisible(imageCapability);
    await tester.tap(imageCapability);
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'image'))
          .selected,
      isTrue,
    );
  });

  testWidgets(
      'Worker Overview displays header, 5-step lifecycle, next step card, and collapsible Technical details',
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
          'releaseStage': 'stable',
          'capabilities': ['text'],
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

    // Check sidebar displays Catalog stage: STABLE (not generic STABLE)
    expect(find.text('Catalog stage: stable'), findsOneWidget);

    // Check sidebar displays Profile status
    expect(find.textContaining('Profile:'), findsOneWidget);

    // Check header displays display name, Worker ID, Profile Definition, provider CLI, and provider status
    expect(find.text('ChatGPT'), findsWidgets);
    expect(find.textContaining('(chatgpt)'), findsOneWidget);
    expect(find.textContaining('Def: chatgpt-codex'), findsOneWidget);
    expect(find.textContaining('CLI: codex'), findsWidgets);

    // Check 5-step lifecycle indicator
    expect(find.text('Configure'), findsOneWidget);
    expect(find.text('Test'), findsOneWidget);
    expect(find.text('Sync'), findsOneWidget);
    expect(find.text('Publish'), findsOneWidget);
    expect(find.text('Rollout'), findsOneWidget);

    // Check Next step card is present
    expect(find.text('Next step'), findsOneWidget);

    // Check collapsible Technical details panel
    expect(find.text('Technical details'), findsOneWidget);
    await tester.ensureVisible(find.text('Technical details'));
    await tester.tap(find.text('Technical details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Worker Type ID'), findsOneWidget);
    expect(find.text('Profile Definition ID'), findsOneWidget);
    expect(find.text('Provider CLI Name'), findsOneWidget);
    expect(find.text('Catalog Release Stage'), findsOneWidget);
    expect(find.text('Catalog stage: stable'), findsWidgets);
    controller.labAccess = ProfileLabAccessReadModel.fromJson({
      'permissions': {'profilesAdmin': true, 'releaseManager': true},
      'signer': {'ready': false},
    });
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('Sync'), findsOneWidget);
    expect(find.text('Publish'), findsOneWidget);
    expect(find.text('Rollout'), findsOneWidget);
  });
}

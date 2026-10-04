import 'dart:async';
import 'dart:io';

import 'package:conclave_profile_lab/app.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class DelayedApi extends ProfileAdminApiClient {
  DelayedApi() : super(baseUrl: 'http://localhost');
  late final catalog = Completer<List<ProfileLabWorkerReadModel>>();
  late final workspaces =
      Completer<List<ProfileLabWorkspaceChannelReadModel>>();
  late final definition = Completer<ProfileLabDefinitionReadModel>();
  @override
  Future<ProfileLabDefinitionReadModel> fetchDefinition(String id) =>
      definition.future;
  int catalogCalls = 0;
  int workspaceCalls = 0;
  @override
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() {
    catalogCalls++;
    return catalog.future;
  }

  @override
  Future<List<ProfileLabWorkspaceChannelReadModel>> listWorkspaceChannels() {
    workspaceCalls++;
    return workspaces.future;
  }

  @override
  Future<List<ProfileLabAuditEventReadModel>> fetchAudit(
          [String? definitionId]) async =>
      [];
}

void main() {
  late Directory temp;
  late DelayedApi api;
  late ProfileLabController controller;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('lab-navigation-');
    api = DelayedApi();
    controller = ProfileLabController(
        paths: ProfileLabPaths(homeDirectory: temp.path),
        apiClientOverride: api,
        sessionStore: ProfileLabSessionStore.inMemoryForTesting(
            ProfileLabPaths(homeDirectory: temp.path)))
      ..currentSession = ProfileLabSession(
          credential: 'fixture',
          sessionId: 'fixture',
          userId: 'fixture',
          displayName: 'Operator',
          email: 'operator@example.test',
          expiresAt: DateTime.now().add(const Duration(hours: 1)));
  });
  tearDown(() {
    controller.dispose();
    temp.deleteSync(recursive: true);
  });

  testWidgets(
      'pending catalog and Workspace refreshes never block navigation or duplicate requests',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProfileLabApp(controller: controller));
    await tester.pump();
    expect(api.catalogCalls, 1);
    for (final name in [
      'Workspaces',
      'Workers',
      'Profiles',
      'Audit',
      'Workspaces'
    ]) {
      await tester.tap(find.text(name).first);
      await tester.pump();
      expect(controller.selectedTab.name, name.toLowerCase());
      expect(tester.takeException(), isNull);
    }
    expect(api.workspaceCalls, 1);
    expect(api.catalogCalls, 1);
    expect(controller.isLoadingWorkerCatalog, isTrue);
    api.workspaces.complete([]);
    api.catalog.complete([]);
    await tester.pumpAndSettle();
    expect(controller.isLoadingWorkerCatalog, isFalse);
    expect(controller.isLoadingWorkspaces, isFalse);
  });

  testWidgets(
      'successful empty catalog is loaded and does not refetch on navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProfileLabApp(controller: controller));
    api.catalog.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No logical workers found.'), findsOneWidget);
    expect(controller.hasLoadedWorkerCatalog, isTrue);
    await tester.tap(find.text('Profiles').first);
    await tester.pump();
    await tester.tap(find.text('Workers').first);
    await tester.pump();
    expect(api.catalogCalls, 1);
  });

  test('late definition cannot replace a newer Worker selection', () async {
    final pending = controller.selectWorker(
        {'workerTypeId': 'first', 'profileDefinitionId': 'first-profile'});
    await controller.selectWorker({'workerTypeId': 'second'});
    api.definition.complete(ProfileLabDefinitionReadModel.fromJson(
        {'profileDefinitionId': 'first-profile'}));
    await pending;
    expect(controller.selectedCloudWorker?['workerTypeId'], 'second');
    expect(controller.selectedCloudDefinition, isNull);
    expect(controller.selectedDefinitionId, isNull);
  });

  test('origin change discards a pending catalog response', () async {
    final pending = controller.fetchCloudCatalog();
    await controller.setCloudUrl('http://127.0.0.1:4321');
    api.catalog.complete([
      ProfileLabWorkerReadModel.fromJson(
          {'workerTypeId': 'old-origin', 'displayName': 'Old origin'})
    ]);
    await pending;
    expect(controller.cloudWorkers, isEmpty);
    expect(controller.hasLoadedWorkerCatalog, isFalse);
  });

  for (final unauthorized in [false, true]) {
    testWidgets(
        'catalog failure displays error and Retry, unauthorized=$unauthorized',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProfileLabApp(controller: controller));
      await tester.pump();
      api.catalog.completeError(unauthorized
          ? ProfileAdminUnauthorizedException('Access denied')
          : StateError('Catalog unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('No logical workers found.'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(controller.hasLoadedWorkerCatalog, isFalse);
      expect(controller.workerCatalogUnauthorized, unauthorized);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(api.catalogCalls, 2);
      expect(tester.takeException(), isNull);
    });
  }
}

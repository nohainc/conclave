import 'dart:async';

import 'package:conclave_workspace/main.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/worker_check_progress.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/workspace_manager_worker_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/logical_worker_catalog_fixture.dart';

class _MemoryCredentialStore implements SecureCredentialStore {
  @override
  String? readSync(String key) => null;
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  testWidgets(
      'Worker selector keeps selection and shows real service check stages',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, Object?> snapshot(
            {WorkerCheckProgress? check, bool failed = false}) =>
        {
          'localRegistryLoaded': true,
          'catalogConfirmed': true,
          'descriptors': [
            for (final type in ['chatgpt', 'gemini'])
              logicalWorkerCatalogFixture(type).toJson()
          ],
          'views': [
            for (final type in ['chatgpt', 'gemini'])
              {
                'descriptor': logicalWorkerCatalogFixture(type).toJson(),
                'localState': 'configured',
                'profileState': 'ready',
                'providerToolState': 'available',
                'localWorker': {
                  'workerId': 'local-$type',
                  'workspaceId': 'workspace',
                  'productWorkerTypeId': type,
                  'activationState': 'enabled',
                  'readinessState': 'ready',
                  'localPermissions': <String>[],
                  'localConcurrencyLimit': 5,
                  'revision': 1,
                  'providerToolVersion': '1.0.0',
                  'createdAt': '2026-10-19T10:00:00Z',
                  'updatedAt': '2026-10-19T10:00:00Z',
                  if (failed) ...{
                    'lastLiveTestAt': '2026-10-19T12:00:02Z',
                    'lastLiveTestPassed': false,
                    'lastLiveTestIssueCode': 'provider_authentication_required',
                    'lastLiveTestDetails': 'The provider CLI requires sign-in.',
                  },
                },
              }
          ],
          'checks': {if (check != null) 'gemini': check.toJson()},
        };
    var current = snapshot();
    final catalog =
        IpcWorkspaceWorkerCatalog((_, {payload = const {}}) async => current);
    addTearDown(catalog.dispose);
    catalog.acceptSnapshot(current);
    final pending = Completer<void>();
    String? requestedType;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkspaceDashboard(
      snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.ready,
          title: 'Ready',
          detail: '',
          registered: true,
          workspaceReady: true,
          cloudConnected: true,
          serviceRunning: true),
      credentialStore: _MemoryCredentialStore(),
      workerCatalogCoordinator: catalog,
      onConfigureWorker: (_) async {},
      onReadinessCheck: (
          {LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
          String? workerTypeId}) {
        requestedType = workerTypeId;
        return pending.future;
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('worker-catalog-chatgpt')), findsOneWidget);
    expect(find.byKey(const Key('worker-catalog-gemini')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('worker-selector-gemini')));
    await tester.tap(find.byKey(const Key('worker-selector-gemini')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Test'));
    await tester.tap(find.text('Test'));
    await tester.pump();
    await tester.pump();
    expect(requestedType, 'gemini');
    current = snapshot(
        check: const WorkerCheckProgress(
            mode: 'live',
            phase: WorkerCheckPhase.probe,
            outcome: WorkerCheckOutcome.running,
            startedAt: '2026-10-19T12:00:00Z'));
    catalog.acceptSnapshot(current);
    await tester.pump();
    expect(find.text('Run live CLI test · Running'), findsOneWidget);
    expect(find.text('Resolve current Profile · Passed'), findsOneWidget);
    expect(
        find.text('Record successful verification · Not run'), findsOneWidget);
    expect(find.byKey(const Key('worker-catalog-chatgpt')), findsNothing);
    final testButton = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Testing…'));
    expect(testButton.onPressed, isNull);
    // Switching Worker while a test runs keeps that test on its own Worker.
    await tester
        .ensureVisible(find.byKey(const Key('worker-selector-chatgpt')));
    await tester.tap(find.byKey(const Key('worker-selector-chatgpt')));
    await tester.pump();
    expect(find.text('Run live CLI test · Running'), findsNothing);
    await tester.tap(find.byKey(const Key('worker-selector-gemini')));
    await tester.pump();
    current = snapshot(
        failed: true,
        check: const WorkerCheckProgress(
            mode: 'live',
            phase: WorkerCheckPhase.probe,
            outcome: WorkerCheckOutcome.failed,
            startedAt: '2026-10-19T12:00:00Z',
            completedAt: '2026-10-19T12:00:02Z',
            issueCode: 'provider_authentication_required'));
    catalog.acceptSnapshot(current);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Run live CLI test · Failed'), findsOneWidget);
    expect(
        find.text('Record successful verification · Not run'), findsOneWidget);
    expect(find.text('CLI sign-in required'), findsOneWidget);
    expect(find.text('Needs attention'), findsNothing);
    expect(find.text('The provider CLI requires sign-in.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

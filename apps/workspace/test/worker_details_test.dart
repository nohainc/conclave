import 'dart:async';

import 'package:conclave_workspace/main.dart';
import 'package:conclave_workspace/brand.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/worker_check_progress.dart';
import 'package:conclave_workspace/worker_brand_icon.dart';
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
    tester.view.physicalSize = const Size(1280, 1600);
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
                'profileDetails': {
                  'revision': 7,
                  'hasModelDiscovery': false,
                  'staticModelNames': ['Model A', 'Model B']
                },
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
                  'lastPassiveProbeAt': '2026-10-19T12:00:00Z',
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
    expect(find.byKey(const Key('worker-catalog-chatgpt')), findsNothing);
    await tester.tap(find.widgetWithText(Tab, 'Workers'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('worker-catalog-chatgpt')), findsOneWidget);
    expect(
        tester.getTopLeft(find.byKey(const Key('worker-selector-chatgpt'))).dx,
        lessThan(tester
            .getTopLeft(find.byKey(const Key('worker-catalog-chatgpt')))
            .dx));
    final selector = find.byKey(const Key('worker-selector-chatgpt'));
    final details = find.byKey(const Key('worker-catalog-chatgpt'));
    expect(
        tester.getSize(selector).width, 228); // 244px panel minus list padding.
    expect(find.descendant(of: selector, matching: find.text('ChatGPT')),
        findsOneWidget);
    expect(find.descendant(of: selector, matching: find.text('codex')),
        findsOneWidget);
    expect(
        tester
            .widget<WorkerBrandIcon>(find.descendant(
                of: selector, matching: find.byType(WorkerBrandIcon)))
            .size,
        36);
    expect(find.descendant(of: details, matching: find.byType(WorkerBrandIcon)),
        findsNothing);
    expect(find.descendant(of: details, matching: find.text('ChatGPT')),
        findsNothing);
    expect(find.descendant(of: details, matching: find.text('Enabled')),
        findsNothing);
    expect(find.byKey(const Key('worker-attention-chatgpt')), findsNothing);
    expect(find.textContaining('Select a Worker to view'), findsNothing);
    expect(find.textContaining('A live test runs the same'), findsNothing);
    expect(find.descendant(of: details, matching: find.byType(Card)),
        findsNothing);
    final summary = find.byKey(const Key('worker-summary-chatgpt'));
    final models = find.byKey(const Key('worker-models-chatgpt'));
    final passive = find.byKey(const Key('worker-last-availability-chatgpt'));
    final live = find.byKey(const Key('worker-last-live-chatgpt'));
    expect(find.text('Live tests: Not run'), findsOneWidget);
    expect(
        find.textContaining(
            RegExp(r'^Passive tests: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')),
        findsOneWidget);
    expect(tester.getTopLeft(passive).dy,
        greaterThan(tester.getBottomLeft(models).dy));
    expect(
        tester.getTopLeft(live).dy, greaterThan(tester.getTopLeft(passive).dy));
    expect(find.descendant(of: passive, matching: find.byType(Icon)),
        findsOneWidget);
    expect(
        find.descendant(
            of: live, matching: find.byIcon(Icons.radio_button_unchecked)),
        findsOneWidget);

    expect(tester.widget<SelectableText>(models).data, 'Model A\nModel B');
    expect(tester.widget<SelectableText>(summary).data,
        'codex 1.0.0 · Profile revision 7');
    expect(tester.getTopLeft(models).dy,
        greaterThan(tester.getTopLeft(summary).dy));
    final actions = [
      find.text('Check for updates'),
      find.text('Test'),
      find.text('Disable'),
      find.text('Enable full access'),
    ];
    Finder button(Finder label) => find.ancestor(
        of: label,
        matching:
            find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
    final actionX = tester.getCenter(button(actions.first)).dx;
    var previousY = -1.0;
    for (final action in actions) {
      expect(tester.getCenter(button(action)).dx, closeTo(actionX, 1));
      expect(tester.getCenter(button(action)).dy, greaterThan(previousY));
      expect(tester.getCenter(button(action)).dx,
          greaterThan(tester.getCenter(summary).dx));
      previousY = tester.getCenter(button(action)).dy;
    }
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(800, 1600);
    await tester.pumpAndSettle();
    expect(tester.getCenter(actions.last).dy,
        greaterThan(tester.getCenter(actions.first).dy));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1280, 1600);
    await tester.pumpAndSettle();
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
    expect(find.text('Run live CLI test'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    for (final theme in [
      ConclaveBrand.lightTheme(),
      ConclaveBrand.darkTheme()
    ]) {
      await tester.pumpWidget(MaterialApp(theme: theme, home: app.home));
      await tester.pump(const Duration(milliseconds: 250));
      for (final bar in tester.widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator))) {
        final active = bar.color!.computeLuminance();
        final track = bar.backgroundColor!.computeLuminance();
        final ratio = active > track
            ? (active + .05) / (track + .05)
            : (track + .05) / (active + .05);
        expect(ratio, greaterThanOrEqualTo(3),
            reason: '${theme.brightness} indicator/track contrast');
        expect(bar.minHeight, 6);
      }
    }

    expect(find.text('Resolve current Profile'), findsNothing);
    expect(find.textContaining('Record successful verification'), findsNothing);
    expect(find.byKey(const Key('worker-catalog-chatgpt')), findsNothing);
    final testButton = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Testing…'));
    expect(testButton.onPressed, isNull);
    // Switching Worker while a test runs keeps that test on its own Worker.
    await tester
        .ensureVisible(find.byKey(const Key('worker-selector-chatgpt')));
    await tester.tap(find.byKey(const Key('worker-selector-chatgpt')));
    await tester.pump();
    expect(find.text('Run live CLI test'), findsNothing);
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
            issueCode: 'provider_authentication_required',
            steps: [
              WorkerCheckStep(
                  code: 'provider_tool_version',
                  status: 'passed',
                  message: 'Provider CLI version 9.9.9 detected.'),
              WorkerCheckStep(
                  code: 'model_discovery',
                  status: 'warning',
                  message: 'Model refresh failed; last catalog retained.'),
              WorkerCheckStep(
                  code: 'configuration',
                  status: 'passed',
                  message: 'Local configuration check passed.'),
              WorkerCheckStep(
                  code: 'authentication',
                  status: 'failed',
                  message: 'Local provider check failed.'),
            ]));
    catalog.acceptSnapshot(current);
    pending.complete();
    await tester.pumpAndSettle();
    // A completed probe shows exactly the returned Engine checks, without
    // synthesizing successful discovery or checks that never ran.
    expect(find.text('Run live CLI test · Failed'), findsNothing);
    expect(find.text('Find and start CLI'), findsNothing);
    expect(find.text('CLI version'), findsNothing);
    expect(find.text('Provider CLI version 9.9.9 detected.'), findsNothing);
    expect(find.text('Model list'), findsNothing);
    expect(find.text('Sign-in'), findsNothing);
    expect(find.text('Account check'),
        findsNothing); // Not returned by this probe.
    expect(find.textContaining(' · Passed'), findsNothing);
    expect(find.text('Local configuration check passed.'), findsNothing);
    for (final code in [
      'provider_tool_version',
      'model_discovery',
      'authentication'
    ]) {
      expect(find.byKey(Key('worker-check-step-gemini-$code')), findsNothing);
    }
    expect(find.byKey(const Key('worker-check-step-gemini-configuration')),
        findsOneWidget);
    expect(catalog.snapshot.checks['gemini']!.steps,
        hasLength(4)); // Evidence retained.
    expect(find.text('CLI sign-in required'), findsOneWidget);
    expect(find.text('Needs attention'), findsNothing);
    expect(find.text('The provider CLI requires sign-in.'), findsOneWidget);
    expect(
        find.textContaining(
            RegExp(r'^Live tests: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('worker-last-live-gemini')),
            matching: find.byIcon(Icons.error_outline)),
        findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'Workspace'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('worker-catalog-gemini')), findsNothing);
    await tester.tap(find.widgetWithText(Tab, 'Workers'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('worker-catalog-gemini')), findsOneWidget);

    current = snapshot(
        check: const WorkerCheckProgress(
      mode: 'passive',
      phase: WorkerCheckPhase.probe,
      outcome: WorkerCheckOutcome.passed,
      startedAt: '2026-10-19T12:00:00Z',
      steps: [
        WorkerCheckStep(
            code: 'provider_tool_version',
            status: 'passed',
            message: 'Version 1.0.0')
      ],
    ));
    catalog.acceptSnapshot(current);
    await tester.pumpAndSettle();
    expect(find.text('Availability check'), findsNothing);
    expect(find.text('Live test'), findsNothing);
    expect(find.text('Verification'), findsNothing);
    expect(find.textContaining('No individual check results'), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('worker-last-availability-gemini')),
            matching: find.byIcon(Icons.check_circle_outline)),
        findsOneWidget);
    expect(find.text('Account check'), findsNothing);
    expect(find.text('Passed'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Workers are listed alphabetically by name', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Catalog order is deliberately not alphabetical.
    final descriptors = [
      logicalWorkerCatalogFixture('gemini'),
      logicalWorkerCatalogFixture('zeta', displayName: 'zeta Tool'),
      logicalWorkerCatalogFixture('claude', displayName: 'Claude'),
      logicalWorkerCatalogFixture('chatgpt'),
    ];
    final snapshot = <String, Object?>{
      'localRegistryLoaded': true,
      'catalogConfirmed': true,
      'descriptors': [for (final d in descriptors) d.toJson()],
      'views': [
        for (final d in descriptors)
          {
            'descriptor': d.toJson(),
            'localState': 'notConfigured',
            'profileState': 'ready',
            'providerToolState': 'unknown',
          }
      ],
    };
    final catalog =
        IpcWorkspaceWorkerCatalog((_, {payload = const {}}) async => snapshot);
    addTearDown(catalog.dispose);
    catalog.acceptSnapshot(snapshot);
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
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Workers'));
    await tester.pumpAndSettle();

    final order = ['chatgpt', 'claude', 'gemini', 'zeta'];
    final tops = [
      for (final type in order)
        tester.getTopLeft(find.byKey(Key('worker-selector-$type'))).dy
    ];
    expect(tops, [...tops]..sort());
    expect(tops.toSet(), hasLength(order.length));
    // The first Worker alphabetically is selected by default.
    expect(find.byKey(const Key('worker-catalog-chatgpt')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

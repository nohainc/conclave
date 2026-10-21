import 'dart:async';

import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/worker_usage.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _UsageSource implements AxWorkerUsageDataSource {
  final calls = <String>[];
  AxWorkerUsageReport report =
      const AxWorkerUsageReport(status: 'ok', output: 'Usage report from CLI');
  Completer<AxWorkerUsageReport>? pending;

  @override
  Future<AxWorkerUsageReport> readWorkerUsage({
    required String workspaceId,
    required String workerId,
  }) async {
    calls.add('$workspaceId/$workerId');
    return pending == null ? report : pending!.future;
  }
}

Widget _page(_UsageSource source,
        {String role = 'owner', String status = 'online', bool ready = true}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkspacesPage(
            workerUsageSource: source,
            workspaces: [
              AxWorkspace(
                  id: 'ws', name: 'Workspace', role: role, status: status)
            ],
            workspaceWorkers: [
              AxWorker(
                id: 'worker',
                workspaceId: 'ws',
                workspaceName: 'Workspace',
                workerTypeId: 'test',
                displayName: 'Test Worker',
                status: 'idle',
                readinessState: ready ? 'ready' : 'attention',
                localConcurrencyLimit: 1,
              )
            ],
          ),
        ),
      ),
    );

void main() {
  const action = ValueKey('workspace-worker-usage-worker');

  testWidgets('worker card fetches usage on click, refreshes and closes',
      (tester) async {
    final source = _UsageSource();
    await tester.pumpWidget(_page(source));
    await tester.pumpAndSettle();
    expect(source.calls, isEmpty);
    await tester.tap(find.byKey(action));
    await tester.pumpAndSettle();
    expect(source.calls, ['ws/worker']);
    expect(find.text('Test Worker usage'), findsOneWidget);
    expect(find.text('Usage report from CLI'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh usage'));
    await tester.pumpAndSettle();
    expect(source.calls, ['ws/worker', 'ws/worker']);
    await tester.tap(find.byTooltip('Close usage'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('offline or unready worker cannot run usage', (tester) async {
    final source = _UsageSource();
    for (final config in [
      (status: 'offline', ready: true),
      (status: 'online', ready: false)
    ]) {
      await tester.pumpWidget(
          _page(source, status: config.status, ready: config.ready));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(find.byKey(action)).onPressed, isNull);
    }
    expect(source.calls, isEmpty);
  });

  testWidgets('shared Workspace does not expose owner-only usage',
      (tester) async {
    final source = _UsageSource();
    await tester.pumpWidget(_page(source, role: 'viewer'));
    await tester.pumpAndSettle();
    expect(find.byKey(action), findsNothing);
    expect(source.calls, isEmpty);
  });

  for (final report in [
    const AxWorkerUsageReport(status: 'unavailable'),
    const AxWorkerUsageReport(
        status: 'error', errorMessage: 'Workspace unavailable'),
  ]) {
    testWidgets('dialog displays ${report.status} report', (tester) async {
      final source = _UsageSource()..report = report;
      await tester.pumpWidget(_page(source));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(action));
      await tester.pumpAndSettle();
      expect(
          find.text(report.status == 'unavailable'
              ? 'This Worker does not provide a usage report.'
              : 'Workspace unavailable'),
          findsOneWidget);
    });
  }

  testWidgets('closing pending usage safely ignores the late result',
      (tester) async {
    final source = _UsageSource()..pending = Completer<AxWorkerUsageReport>();
    await tester.pumpWidget(_page(source));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(action));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Close usage'));
    await tester.pumpAndSettle();
    source.pending!.complete(source.report);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';

import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'ax_fixture_data.dart';

class _UsageDataSource extends AxFixtureDataSource
    implements AxWorkerUsageDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Implement the requested work.',
          'steps': [
            {'kind': 'implement', 'order': 0},
          ],
        }),
      ];

  @override
  Future<AxWorkerUsageReport> readWorkerUsage({
    required String workspaceId,
    required String workerId,
  }) async =>
      const AxWorkerUsageReport(status: 'ok', output: 'raw report');
}

void main() {
  test('usage controller shows the provider report unchanged', () async {
    final controller = AxWorkerUsageController(_UsageDataSource());
    await controller.load(
        workspaceId: 'workspace-1', workerId: 'worker-1', workerName: 'Claude');
    expect(controller.visible, isTrue);
    expect(controller.loading, isFalse);
    expect(controller.report!.displayText, 'raw report');
    controller.dismiss();
    expect(controller.visible, isFalse);
  });

  test('API client returns the raw report and maps access failures', () async {
    Future<AxWorkerUsageReport> read(http.Response response) {
      final client = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path,
              '/api/workspaces/workspace-1/workers/worker-1/usage');
          return response;
        }),
      );
      return client.readWorkerUsage(
          workspaceId: 'workspace-1', workerId: 'worker-1');
    }

    final ok = await read(http.Response(
        jsonEncode({
          'status': 'ok',
          'output': 'Current session: 6% used\n',
          'errorOutput': '',
          'exitCode': 0,
          'truncated': false,
          'fetchedAt': '2026-10-16T10:00:00.000Z',
        }),
        200));
    expect(ok.isOk, isTrue);
    expect(ok.output, 'Current session: 6% used\n');

    final unavailable = await read(http.Response(
        jsonEncode(
            {'status': 'unavailable', 'errorCode': 'usage_not_configured'}),
        200));
    expect(unavailable.status, 'unavailable');

    final denied = await read(
        http.Response(jsonEncode({'error': 'Workspace not found'}), 404));
    expect(denied.status, 'error');
    expect(denied.errorMessage, contains('Workspace owner'));
  });

  testWidgets('typing / lists commands and /usage asks for a Worker',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 700,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
              canExecuteWork: true,
            ),
            dataSource: _UsageDataSource(),
            onBackToSpace: () {},
            onArchive: () {},
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('slash-command-palette')), findsNothing);
    await tester.enterText(find.byType(TextField).last, '/');
    await tester.pump();
    expect(find.byKey(const ValueKey('slash-command-usage')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('slash-command-usage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('worker-usage-panel')), findsOneWidget);
    expect(find.text('Choose a Worker to read its usage.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('work-add-attachments')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('work-menu-usage')), findsNothing);
  });
}

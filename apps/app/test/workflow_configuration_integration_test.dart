import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/sync/ax_workflow_configurations.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'workflows_page_test.dart' show WorkflowSource;
import 'workflow_editor_test.dart' show worker;

class IntegrationSource extends WorkflowSource
    implements AxSpaceWorkflowConfigurationDataSource {
  final spaceValues = <String, Map<String, AxUserWorkflowConfiguration>>{};
  int spaceReads = 0;
  @override
  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
      String spaceId) async {
    spaceReads++;
    return {
      ...{for (final c in values) c.workflowId: c},
      ...?spaceValues[spaceId]
    }.values.toList();
  }

  @override
  Future<AxUserWorkflowConfiguration> saveSpaceWorkflowConfiguration(
      String spaceId, AxUserWorkflowConfiguration configuration) async {
    (spaceValues[spaceId] ??= {})[configuration.workflowId] = configuration;
    return configuration;
  }

  @override
  Future<AxUserWorkflowConfiguration> resetSpaceWorkflowConfiguration(
      String spaceId, String workflowId) async {
    spaceValues[spaceId]?.remove(workflowId);
    return values.where((c) => c.workflowId == workflowId).firstOrNull ??
        AxUserWorkflowConfiguration(workflowId: workflowId);
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async =>
      (await super.loadBuiltinWorkflowCatalog())
          .map((workflow) => AxBuiltinWorkflow.fromJson({
                'id': workflow.id,
                'version': workflow.version,
                'name': workflow.name,
                'description': workflow.description,
                'steps': [
                  for (final step in workflow.steps)
                    {'kind': step.kind, 'order': step.order}
                ],
                'composerBindingId': workflow.id == 'direct'
                    ? 'direct'
                    : workflow.steps.length == 1
                        ? workflow.steps.single.kind
                        : null,
                'executionPolicy': {
                  'userSelectsWorker': true,
                  'userSelectsModel': true,
                  'userSelectsEffort': true
                }
              }))
          .toList();

  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkspaces(
          {required String spaceId}) async =>
      [
        {'workspaceId': 'ws'}
      ];
}

void main() {
  testWidgets(
      'global configuration updates and reset reach Thread controls without reloading',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource()
      ..workers = [worker('a'), worker('b')]
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'direct',
            defaults: const AxWorkflowSelection(
                worker: 'a', model: 'analysis', effort: 'high'))
      ];
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    final catalogs = AxSessionCatalogs(source, engine: engine);
    final history = AxWorkHistoryCache(source, engine: engine);
    var submitted = 0;
    Widget page(String id) => MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                key: ValueKey(id),
                initialTab: 1,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: AxThread(
                    id: id,
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: '',
                    canExecuteWork: true,
                    workConfig: const {
                      'defaultWorkflowId': 'direct',
                      'bindings': {
                        'direct': {
                          'workerId': 'obsolete',
                          'model': 'obsolete-model'
                        }
                      }
                    }),
                dataSource: source,
                catalogs: catalogs,
                workflowConfigurations: cache,
                workHistoryCache: history,
                onBackToSpace: () {},
                onArchive: () {},
                onRunWork: (prompt, workflow, attachments, key) async {
                  submitted++;
                  expect(workflow, 'direct');
                  return 'accepted';
                })));
    await tester.pumpWidget(page('one'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Analysis model'), findsOneWidget);
    expect(find.text('obsolete-model'), findsNothing);
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('work-composer-worker')))
            .onTap,
        isNull);
    await cache.save(AxUserWorkflowConfiguration(
        workflowId: 'direct',
        defaults: const AxWorkflowSelection(
            worker: 'b', model: 'other', effort: 'careful')));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    await cache.reset('direct');
    await tester.pumpAndSettle();
    expect(find.text('Automatic'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Run with Automatic');
    await tester.tap(find.byTooltip('Send request'));
    await tester.pumpAndSettle();
    expect(submitted, 1);
    await tester.pumpWidget(page('two'));
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    expect(source.spaceReads, 3);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'Thread settings keep instructions and remove Worker model fallback editors',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = IntegrationSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
                initialTab: 2,
                space: const AxSpace(
                    id: 's',
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: 'owner'),
                thread: const AxThread(
                    id: 't',
                    spaceId: 's',
                    name: 'Thread',
                    lead: '',
                    status: 'active',
                    brief: '',
                    primaryWorkspace: '',
                    queueStatus: ''),
                dataSource: source,
                onBackToSpace: () {},
                onArchive: () {}))));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Worker, model, and effort defaults are configured in this Space’s Workflows tab.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('worker-binding-direct')), findsNothing);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    final configure = find.byKey(const ValueKey('configure-binding-direct'));
    await tester.ensureVisible(configure);
    await tester.tap(configure);
    await tester.pumpAndSettle();
    expect(find.text('Work instructions'), findsOneWidget);
    expect(find.text('Model (optional)'), findsNothing);
    expect(find.text('Fallback Worker (optional)'), findsNothing);
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'Authored instruction');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}

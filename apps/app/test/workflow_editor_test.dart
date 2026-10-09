import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:conclave_app/src/ax/sync/ax_workflow_configurations.dart';
import 'package:conclave_app/src/ax/workflow_configuration_options.dart';
import 'package:conclave_app/src/features/workflows/workflow_editor.dart';
import 'workflows_page_test.dart' show WorkflowSource, workflow;

AxWorker worker(String id,
        {bool offline = false,
        bool metadata = true,
        String workspaceId = 'ws'}) =>
    AxWorker(
      id: id,
      workspaceId: workspaceId,
      workspaceName: 'Laptop',
      workerTypeId: 'custom',
      displayName: id == 'a' ? 'First' : 'Second',
      status: offline ? 'offline' : 'ready',
      readinessState: offline ? 'offline' : 'ready',
      localConcurrencyLimit: 1,
      capabilities: const [],
      executionOptions: !metadata
          ? null
          : AxWorkerExecutionOptions(
              modelSelectionSupported: true,
              modelDiscovery: 'profile_catalog',
              allowsCustomModel: false,
              allowedModelIds: id == 'a' ? ['analysis', 'review'] : ['other'],
              models: id == 'a'
                  ? const [
                      AxWorkerModelOption(
                          id: 'analysis',
                          name: 'Analysis model',
                          effort: AxWorkerEffortOptions(
                              supported: true, values: ['low', 'high'])),
                      AxWorkerModelOption(
                          id: 'review',
                          name: 'Review model',
                          effort: AxWorkerEffortOptions(
                              supported: true, values: ['thorough'])),
                    ]
                  : const [
                      AxWorkerModelOption(
                          id: 'other',
                          name: 'Other model',
                          effort: AxWorkerEffortOptions(
                              supported: true, values: ['careful']))
                    ],
              modelSwitchSupported: false,
              effort: const AxWorkerEffortOptions(supported: false, values: []),
            ),
    );
const defaultSelection =
    AxWorkflowSelection(worker: 'a', model: 'analysis', effort: 'low');
AxUserWorkflowConfiguration configuration(
        {Map<String, AxWorkflowSelection> overrides = const {},
        AxWorkflowSelection defaults = defaultSelection}) =>
    AxUserWorkflowConfiguration(
        workflowId: 'full_cycle', defaults: defaults, stepOverrides: overrides);

Finder picker(String scope, String label) => find.byWidgetPredicate((widget) =>
    widget is DropdownButtonFormField<String> &&
    widget.key is ValueKey<String> &&
    (widget.key as ValueKey<String>).value.startsWith('$scope-$label-'));
Future<void> choose(
    WidgetTester tester, String scope, String label, String text) async {
  await tester.ensureVisible(picker(scope, label));
  await tester.tap(picker(scope, label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Iterable<String?> choices(
        WidgetTester tester, String scope, String label) =>
    tester
        .widget<DropdownButton<String>>(find.descendant(
            of: picker(scope, label),
            matching: find.byType(DropdownButton<String>)))
        .items!
        .map((item) => item.value);
Future<WorkflowSource> mount(
    WidgetTester tester, AxUserWorkflowConfiguration saved,
    {List<AxWorker>? workers}) async {
  tester.view.physicalSize = const Size(1000, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final source = WorkflowSource()
    ..values = [saved]
    ..workers = workers ?? [worker('a'), worker('b')];
  final engine = AxSyncEngine();
  final catalogs = AxSessionCatalogs(source, engine: engine);
  final cache = AxWorkflowConfigurations(source, engine: engine);
  await catalogs.ensureWorkers();
  await cache.ensure();
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => WorkflowEditor(
                            definition: workflow('full_cycle', 'Full Cycle',
                                steps: ['plan', 'implement', 'verify']),
                            configuration: saved,
                            catalogs: catalogs,
                            cache: cache,
                          )),
                  child: const Text('Open'))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return source;
}

Future<void> openStep(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('workflow-advanced')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey('workflow-step-$id')));
  await tester.tap(find.byKey(ValueKey('workflow-step-$id')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'a step can return to already-saved defaults while Worker metadata is unavailable',
      (tester) async {
    final saved = configuration(
        defaults: const AxWorkflowSelection(
            worker: 'missing', model: 'old-model', effort: 'old-effort'),
        overrides: {'verify': const AxWorkflowSelection(effort: 'high')});
    final source = await mount(tester, saved, workers: []);
    await openStep(tester, 'verify');
    await tester.ensureVisible(find.byKey(const ValueKey('reset-step-verify')));
    await tester.tap(find.byKey(const ValueKey('reset-step-verify')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides, isEmpty);
    expect(source.values.single.defaults.toJson(), saved.defaults.toJson());
  });
  testWidgets(
      'inventory refresh revalidates the open draft without erasing saved selections',
      (tester) async {
    final source = await mount(tester, configuration());
    source.workers = [worker('b')];
    final editor = tester.widget<WorkflowEditor>(find.byType(WorkflowEditor));
    await editor.catalogs.refreshWorkers();
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Selected Worker is unavailable.'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Worker'))
            .initialValue,
        'a');
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    expect(source.writes, 0);
  });
  testWidgets(
      'failed save preserves the draft and displays the error for explicit retry',
      (tester) async {
    final source = await mount(tester, configuration());
    await choose(tester, 'defaults', 'Model', 'Review model');
    source.fail = true;
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Write failed'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Model'))
            .initialValue,
        'review');
    expect(source.values.single.defaults.model, 'analysis');
    source.fail = false;
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.defaults.model, 'review');
    expect(source.writes, 2);
    expect(source.reads, 1);
  });
  test(
      'Auto Worker options and validation require a coherent model/effort on one Profile',
      () {
    final options = AxWorkflowSelectionOptions([worker('a'), worker('b')]);
    expect(options.models(null).keys, ['analysis', 'review', 'other']);
    expect(options.efforts(const AxWorkflowSelection(model: 'analysis')),
        ['low', 'high']);
    expect(
        options.validate(
            const AxWorkflowSelection(model: 'analysis', effort: 'careful'),
            saved: const AxWorkflowSelection()),
        isNotNull);
    expect(
        options.validate(
            const AxWorkflowSelection(model: 'review', effort: 'thorough'),
            saved: const AxWorkflowSelection()),
        isNull);
    expect(
        options.validate(
            const AxWorkflowSelection(worker: 'b', model: 'analysis'),
            saved: defaultSelection),
        contains('model'));
    expect(
        options.validate(
            const AxWorkflowSelection(
                worker: 'a', model: 'review', effort: 'low'),
            saved: defaultSelection),
        contains('effort'));
  });
  test(
      'offline readiness preserves valid choices; missing Profile metadata preserves only unchanged intent',
      () {
    expect(
        AxWorkflowSelectionOptions([worker('a', offline: true)])
            .validate(defaultSelection, saved: const AxWorkflowSelection()),
        isNull);
    for (final workers in <List<AxWorker>>[
      [],
      [worker('a', metadata: false)]
    ]) {
      final options = AxWorkflowSelectionOptions(workers);
      expect(
          options.validate(defaultSelection, saved: defaultSelection), isNull);
      expect(
          options.validate(
              const AxWorkflowSelection(worker: 'a', model: 'review'),
              saved: defaultSelection),
          isNotNull);
    }
  });
  testWidgets(
      'Worker and model changes refresh dependent choices and clear explicit downstream values',
      (tester) async {
    final source = await mount(tester, configuration());
    expect(choices(tester, 'defaults', 'Effort'), ['', 'low', 'high']);
    await choose(tester, 'defaults', 'Model', 'Review model');
    expect(choices(tester, 'defaults', 'Effort'), ['', 'thorough']);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Effort'))
            .initialValue,
        '');
    await choose(tester, 'defaults', 'Worker', 'Second · Laptop');
    expect(choices(tester, 'defaults', 'Model'), ['', 'other']);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                picker('defaults', 'Model'))
            .initialValue,
        '');
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.defaults.toJson(), {'worker': 'b'});
  });
  testWidgets(
      'effort-only step override inherits Worker/model and saves only the override; reset step restores inheritance',
      (tester) async {
    final source = await mount(tester, configuration());
    await openStep(tester, 'verify');
    await tester.tap(find.byKey(const ValueKey('override-verify')));
    await tester.pumpAndSettle();
    expect(choices(tester, 'verify', 'Effort'), ['', 'low', 'high']);
    await choose(tester, 'verify', 'Effort', 'High');
    expect(find.text('High effort'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides['verify']!.toJson(),
        {'effort': 'high'});
    expect(source.values.single.selectionFor('verify').worker, 'a');
    expect(source.values.single.selectionFor('plan').effort, 'low');
    final saved = source.values.single;
    final nextSource = await mount(tester, saved);
    await openStep(tester, 'verify');
    await tester.ensureVisible(find.byKey(const ValueKey('reset-step-verify')));
    await tester.tap(find.byKey(const ValueKey('reset-step-verify')));
    await tester.pumpAndSettle();
    expect(picker('verify', 'Worker'), findsNothing);
    expect(find.text('Inherit defaults'), findsNWidgets(3));
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(nextSource.values.single.stepOverrides, isEmpty);
  });
  testWidgets(
      'incompatible inherited combinations block Save until the step model and effort are corrected',
      (tester) async {
    final source = await mount(
        tester,
        configuration(
            overrides: {'verify': const AxWorkflowSelection(worker: 'b')}));
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNull);
    expect(source.writes, 0);
    await openStep(tester, 'verify');
    expect(find.textContaining('Verify: The selected model'), findsOneWidget);
    await choose(tester, 'verify', 'Model', 'Other model');
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNull);
    await choose(tester, 'verify', 'Effort', 'Careful');
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides['verify']!.toJson(),
        {'worker': 'b', 'model': 'other', 'effort': 'careful'});
  });
  testWidgets(
      'use workflow defaults removes the entire override without touching other steps',
      (tester) async {
    final source = await mount(
        tester,
        configuration(overrides: {
          'verify': const AxWorkflowSelection(effort: 'high'),
          'plan': const AxWorkflowSelection(model: 'analysis')
        }));
    await openStep(tester, 'verify');
    await tester.tap(find.byKey(const ValueKey('inherit-verify')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.stepOverrides.keys, ['plan']);
    expect(source.values.single.defaults.toJson(), defaultSelection.toJson());
  });
  testWidgets(
      'missing saved Worker is visible and retained, and full reset restores Automatic',
      (tester) async {
    final saved = configuration(
        defaults: const AxWorkflowSelection(
            worker: 'missing', model: 'old-model', effort: 'old-effort'),
        overrides: {'verify': const AxWorkflowSelection(effort: 'high')});
    final source = await mount(tester, saved, workers: []);
    expect(
        find.textContaining('Selected Worker is unavailable.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('save-workflow')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('save-workflow')));
    await tester.pumpAndSettle();
    expect(source.values.single.toJson(), saved.toJson());
    final next = await mount(tester, saved, workers: []);
    await tester.tap(find.byKey(const ValueKey('reset-workflow')));
    await tester.pumpAndSettle();
    expect(next.values, isEmpty);
    expect(next.reads, 1);
  });
  testWidgets(
      'cancel discards local edits and fixed steps expose no structural editing',
      (tester) async {
    final source = await mount(tester, configuration());
    await choose(tester, 'defaults', 'Model', 'Review model');
    await tester.tap(find.byKey(const ValueKey('workflow-advanced')));
    await tester.pumpAndSettle();
    expect(find.text('1. Plan'), findsOneWidget);
    expect(find.text('2. Implement'), findsOneWidget);
    expect(find.text('3. Verify'), findsOneWidget);
    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.writes, 0);
    expect(source.values.single.defaults.toJson(), defaultSelection.toJson());
  });
}

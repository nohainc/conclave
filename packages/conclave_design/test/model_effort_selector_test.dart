import 'package:conclave_design/conclave_design.dart';
import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const worker = WorkerSelectionCapability(id: 'worker', name: 'Worker', models: [
  ExecutionModelCapability(id: 'one', name: 'One', efforts: ['deep', 'brief']),
  ExecutionModelCapability(id: 'two', name: 'Two', efforts: ['deep']),
  ExecutionModelCapability(id: 'fast', name: 'Fast'),
]);
Finder picker(String label) => find.byWidgetPredicate((w) =>
    w is DropdownButtonFormField<String> &&
    (w.key as ValueKey<String>).value.startsWith('execution-$label-'));
Future<void> choose(WidgetTester tester, String label, String text) async {
  await tester.tap(picker(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'catalog refresh preserves supported choices and exposes removed efforts',
    (tester) async {
      const selection = ExecutionSelection(
        worker: 'worker',
        model: 'one',
        effort: 'deep',
        catalogRevision: 'old',
      );
      final changes = <ExecutionSelection>[];
      Future<void> render(List<String> efforts) => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ModelEffortSelector(
                  catalog: ExecutionSelectionCatalog([
                    WorkerSelectionCapability(
                      id: 'worker',
                      name: 'Worker',
                      catalogRevision: 'current',
                      models: [
                        ExecutionModelCapability(
                          id: 'one',
                          name: 'One',
                          efforts: efforts,
                        ),
                      ],
                    ),
                  ]),
                  value: selection,
                  onChanged: changes.add,
                ),
              ),
            ),
          );
      await render(['deep', 'brief']);
      expect(
        find.text('Worker catalog changed; refresh and confirm the selection.'),
        findsNothing,
      );
      expect(changes, isEmpty);
      await render(['brief']);
      expect(
        find.text(
          'The selected effort is not supported for this Worker and model.',
        ),
        findsOneWidget,
      );
      expect(changes, isEmpty);
      expect(selection.effort, 'deep');
      expect(selection.catalogRevision, 'old');
    },
  );

  test('effort labels agree for selectors and historical summaries', () {
    expect(executionEffortDisplayName('xhigh'), 'Extra High');
    expect(executionEffortDisplayName('medium'), 'Medium');
    expect(executionEffortDisplayName('provider-special'), 'Provider-special');
    expect(executionEffortDisplayName(null), '');
  });

  testWidgets('combined provider models require explicit model and effort',
      (tester) async {
    const gemini = WorkerSelectionCapability(
      id: 'gemini',
      name: 'Gemini',
      models: [
        ExecutionModelCapability(
          id: 'gemini-3.8-flash',
          name: 'Gemini 3.8 Flash',
          efforts: ['low', 'high'],
          selectionMode: 'combined',
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModelEffortSelector(
          catalog: const ExecutionSelectionCatalog([gemini]),
          value: const ExecutionSelection(worker: 'gemini'),
          onChanged: (_) {},
        ),
      ),
    ));
    expect(find.text('Auto'), findsNothing);
    expect(find.text('Auto / Provider default'), findsNothing);
    expect(
        find.text('Select an explicit model for this Worker.'), findsOneWidget);
    await tester.tap(picker('Model'));
    await tester.pumpAndSettle();
    expect(find.text('Select Model...'), findsNWidgets(2));
    expect(find.text('Gemini 3.8 Flash'), findsOneWidget);
  });
  testWidgets('resolved summaries preserve field permissions and inheritance',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
      catalog: const ExecutionSelectionCatalog([worker]),
      value: const ExecutionSelection(),
      inherited: const ExecutionSelection(
          worker: 'worker', model: 'one', effort: 'deep'),
      allowWorkerChange: false,
      allowModelChange: false,
      helperMessage: 'A model change requires a new session.',
      onChanged: (_) {},
    ))));
    expect(
        find.text('Effective selection: Worker · One · Deep'), findsOneWidget);
    expect(find.text('Inherited: One'), findsOneWidget);
    expect(find.text('A model change requires a new session.'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(picker('Worker'))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(picker('Model'))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(picker('Effort'))
            .onChanged,
        isNotNull);
  });
  testWidgets('model changes retain supported efforts and explain a reset',
      (tester) async {
    var value = const ExecutionSelection(
        worker: 'worker', model: 'one', effort: 'deep');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, setState) => ModelEffortSelector(
                    catalog: const ExecutionSelectionCatalog([worker]),
                    value: value,
                    onChanged: (next) => setState(() => value = next))))));
    await choose(tester, 'Model', 'Two');
    expect(value.effort, 'deep');
    await choose(tester, 'Model', 'Fast');
    expect(value.effort, isNull);
    expect(find.textContaining('Effort reset to Auto'), findsOneWidget);
  });
  testWidgets(
      'refresh preserves unavailable saved selections without emitting changes',
      (tester) async {
    var changes = 0;
    const value = ExecutionSelection(
        worker: 'worker', model: 'removed', effort: 'retired');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                catalog: const ExecutionSelectionCatalog([worker]),
                value: value,
                onChanged: (_) => changes++))));
    expect(find.text('removed · Unavailable'), findsOneWidget);
    expect(find.text('retired · Unavailable'), findsOneWidget);
    expect(changes, 0);
    await choose(tester, 'Model', 'One');
    expect(changes, 1);
  });
  testWidgets('read-only mode exposes the matrix and disables editing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                showWorker: false,
                readOnly: true,
                catalog: ExecutionSelectionCatalog([worker]),
                value: ExecutionSelection(worker: 'worker')))));
    expect(find.text('One · Deep, Brief · Listed'), findsOneWidget);
    for (final dropdown in tester.widgetList<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>))) {
      expect(dropdown.onChanged, isNull);
    }
  });
  testWidgets('loading, stale, unavailable and unsupported states are explicit',
      (tester) async {
    for (final state in CapabilityState.values) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ModelEffortSelector(
                  catalog: ExecutionSelectionCatalog([
                    WorkerSelectionCapability(
                        id: 'worker', name: 'Worker', state: state)
                  ]),
                  value: const ExecutionSelection(worker: 'worker'),
                  onChanged: (_) {}))));
      if (state == CapabilityState.loading)
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
      if (state == CapabilityState.stale)
        expect(find.textContaining('capabilities are stale'), findsOneWidget);
      if (state == CapabilityState.unavailable)
        expect(find.textContaining('options are unavailable'), findsOneWidget);
      if (state == CapabilityState.unsupported)
        expect(find.textContaining('Model selection is unsupported'),
            findsOneWidget);
    }
  });
  testWidgets(
      'inheritance is visible and Auto is never a guessed concrete choice',
      (tester) async {
    ExecutionSelection? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(),
                inherited: const ExecutionSelection(
                    worker: 'worker', model: 'one', effort: 'deep'),
                onChanged: (next) => result = next))));
    expect(find.text('Inherited: One'), findsOneWidget);
    await choose(tester, 'Model', 'Two');
    expect(result!.worker, isNull);
    expect(result!.effort, isNull);
  });
  testWidgets(
      'native dropdowns support keyboard focus, selection and semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();

    ExecutionSelection? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                showWorker: false,
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(worker: 'worker'),
                onChanged: (next) => result = next))));
    expect(find.bySemanticsLabel(RegExp('Model')), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result?.model, 'one');
    semantics.dispose();
  });
  testWidgets('compact host opens the same accessible selector',
      (tester) async {
    ExecutionSelection? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(worker: 'worker'),
                onChanged: (next) => result = next))));
    await tester.tap(find.byKey(const ValueKey('execution-open')));
    await tester.pumpAndSettle();
    expect(find.byType(ModelEffortSelector), findsNWidgets(2));
    expect(picker('Model'), findsOneWidget);
    expect(find.text('Explicit selection'), findsNothing);
    expect(find.text('Auto / Provider default'), findsNothing);
    expect(find.text('Effort choices depend on the model.'), findsNothing);
    await choose(tester, 'Model', 'Two');
    expect(result, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.byKey(const ValueKey('execution-open')));
    await tester.pumpAndSettle();
    await choose(tester, 'Model', 'Two');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(result?.model, 'two');
  });
  testWidgets('compact result can show only model and effort', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                showWorkerInCompactSummary: false,
                catalog: const ExecutionSelectionCatalog([worker]),
                value: const ExecutionSelection(
                    worker: 'worker', model: 'one', effort: 'deep'),
                onChanged: (_) {}))));
    expect(find.text('One · Deep'), findsOneWidget);
    expect(find.textContaining('Worker'), findsNothing);
  });
  testWidgets('compact combined selections never render Auto', (tester) async {
    const gemini = WorkerSelectionCapability(
      id: 'gemini',
      name: 'Gemini',
      models: [
        ExecutionModelCapability(
          id: 'gemini-3.8-flash',
          name: 'Gemini 3.8 Flash',
          efforts: ['low', 'high'],
          selectionMode: 'combined',
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ModelEffortSelector(
                compact: true,
                catalog: const ExecutionSelectionCatalog([gemini]),
                value: const ExecutionSelection(worker: 'gemini'),
                onChanged: (_) {}))));
    expect(find.textContaining('Auto'), findsNothing);
    expect(find.textContaining('Select model'), findsOneWidget);
    expect(find.textContaining('Select effort'), findsOneWidget);
  });
}

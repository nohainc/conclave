import 'package:conclave_design/conclave_design.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_workspace/worker_model_catalog_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('missing and refreshing catalogs remain inspectable',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: WorkerModelCatalogView(
                workerId: 'worker',
                workerName: 'Worker',
                catalog: null,
                loading: true))));
    expect(find.byType(ModelEffortSelector), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('options are unavailable'), findsOneWidget);
  });

  testWidgets(
      'Service catalog uses the shared read-only selector with actual efforts and stale state',
      (tester) async {
    final catalog = DiscoveredModelCatalog(
        profileDigest: 'a' * 64,
        providerToolVersion: '1.0.0',
        discoveredAt: '2026-10-11T00:00:00Z',
        stale: true,
        models: [
          DiscoveredModel(
              id: 'family',
              name: 'Family',
              selectionMode: 'combined',
              supportedReasoningEfforts: ['custom'],
              defaultReasoningEffort: 'custom',
              status: 'listed'),
        ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkerModelCatalogView(
                workerId: 'worker', workerName: 'Worker', catalog: catalog))));
    expect(find.byType(ModelEffortSelector), findsOneWidget);
    expect(find.text('Family · Custom · Listed · Default: Custom'),
        findsOneWidget);
    expect(find.textContaining('capabilities are stale'), findsOneWidget);
    for (final control in tester.widgetList<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>))) {
      expect(control.onChanged, isNull);
    }
  });
}

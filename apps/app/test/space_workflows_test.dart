import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_workflow_configuration.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/sync/ax_workflow_configurations.dart';
import 'package:conclave_app/src/ax/sync/ax_space_threads.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'workflow_configuration_integration_test.dart' show IntegrationSource;
import 'workflow_editor_test.dart' show worker;

void main() {
  testWidgets(
      'Space workflows initialize globally, save independently, reset, and reuse their shared cache',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
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
    final streams = AxSpaceThreads(source, engine: engine);
    Widget page(String id, {String role = 'owner'}) => MaterialApp(
        home: Scaffold(
            body: SpacePage(
                key: ValueKey(id),
                space: AxSpace(
                    id: id,
                    name: 'Space',
                    branch: '',
                    lastActivity: '',
                    role: role),
                dataSource: source,
                spaceThreads: streams,
                onOpenThread: (_) {},
                onArchive: () {},
                onDelete: () {})));
    await tester.pumpWidget(page('s'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workflows'));
    await tester.pumpAndSettle();
    expect(find.text('Workspaces'), findsNothing);
    expect(find.text('Using the global Workspace.'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(source.spaceReads, 1);
    await tester.tap(find.byKey(const ValueKey('edit-direct')));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsWidgets);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(source.spaceValues['s']?['direct']?.defaults.worker, 'a');
    expect(source.writes, 0);
    final cache =
        AxWorkflowConfigurations(source, engine: engine, spaceId: 's');
    await cache.save(AxUserWorkflowConfiguration(
        workflowId: 'direct',
        defaults: const AxWorkflowSelection(worker: 'b')));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    expect(source.values.single.defaults.worker, 'a');
    await cache.reset('direct');
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    await tester.tap(find.text('Threads'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workflows'));
    await tester.pumpAndSettle();
    expect(source.spaceReads, 1);

    await tester.tap(find.byKey(const ValueKey('workflow-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Workspace').last);
    await tester.pumpAndSettle();
    expect(find.text('Change Workspace?'), findsOneWidget);
    await tester.tap(find.text('Change and reset'));
    await tester.pumpAndSettle();
    expect(source.selectedSpaceWorkspaces['s'], 'other');
    expect(source.values.single.defaults.worker, 'a');
    expect(engine.peek(cache.query).data, isEmpty);
    expect(find.text('Using the global Workspace.'), findsNothing);
    await tester.tap(find.text('Use global Workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change and reset'));
    await tester.pumpAndSettle();
    expect(source.selectedSpaceWorkspaces.containsKey('s'), isFalse);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Using the global Workspace.'), findsOneWidget);
    final spaceReads = source.spaceReads;
    await tester.pumpWidget(page('other', role: 'collaborator'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workflows'));
    await tester.pumpAndSettle();
    expect(source.spaceReads, spaceReads + 1);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('edit-direct')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

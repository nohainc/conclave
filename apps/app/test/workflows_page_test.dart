import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_app.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/sync/ax_session_catalogs.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/sync/ax_workflow_configurations.dart';
import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/features/workflows/workflows_page.dart';
import 'package:conclave_app/src/navigation/ax_browser_navigation.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'workflow_editor_test.dart' show worker, choices;
import 'ax_fixture_realtime.dart';

AxBuiltinWorkflow workflow(String id, String name,
        {int version = 1, List<String> steps = const ['chat']}) =>
    AxBuiltinWorkflow(
      id: id,
      version: version,
      name: name,
      description: 'Description for $name',
      steps: [
        for (var i = 0; i < steps.length; i++)
          AxBuiltinWorkflowStep(kind: steps[i], order: i)
      ],
      snapshot: const {},
    );

class WorkflowSource extends AxFixtureDataSource
    implements
        AxWorkflowConfigurationDataSource,
        AxWorkflowDefaultDataSource,
        AxWorkflowWorkspaceDataSource {
  String? selectedWorkspace = 'ws';
  int workspaceReads = 0, workspaceWrites = 0;
  final selectedSpaceWorkspaces = <String, String?>{};
  @override
  Future<AxWorkflowWorkspaceSettings> loadWorkflowWorkspace(
      {String? spaceId}) async {
    workspaceReads++;
    return AxWorkflowWorkspaceSettings(
        workspaceId: spaceId == null
            ? selectedWorkspace
            : selectedSpaceWorkspaces.containsKey(spaceId)
                ? selectedSpaceWorkspaces[spaceId]
                : selectedWorkspace,
        inherited:
            spaceId != null && !selectedSpaceWorkspaces.containsKey(spaceId),
        workspaces: const [
          AxWorkflowWorkspace(id: 'ws', name: 'First Workspace'),
          AxWorkflowWorkspace(id: 'other', name: 'Second Workspace')
        ]);
  }

  @override
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
      {String? spaceId, String? workspaceId, bool inherit = false}) async {
    workspaceWrites++;
    if (spaceId == null) {
      selectedWorkspace = workspaceId;
      values = [];
    } else if (inherit) {
      selectedSpaceWorkspaces.remove(spaceId);
    } else {
      selectedSpaceWorkspaces[spaceId] = workspaceId;
    }
    return loadWorkflowWorkspace(spaceId: spaceId);
  }

  int reads = 0, catalogReads = 0, writes = 0;
  bool fail = false;
  Completer<List<AxUserWorkflowConfiguration>>? pending;
  Completer<AxUserWorkflowConfiguration>? pendingSave;
  List<AxWorker> workers = [];
  List<AxUserWorkflowConfiguration> values = [];
  String defaultWorkflow = 'chat';
  @override
  Future<String> loadWorkflowDefault() async => defaultWorkflow;

  @override
  Future<String> saveWorkflowDefault(String workflowId) async {
    defaultWorkflow = workflowId;
    return workflowId;
  }

  @override
  Future<String> loadSpaceWorkflowDefault(String spaceId) async =>
      defaultWorkflow;

  @override
  Future<String> saveSpaceWorkflowDefault(
      String spaceId, String workflowId) async {
    defaultWorkflow = workflowId;
    return workflowId;
  }

  @override
  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations() async {
    reads++;
    if (fail) throw StateError('Read failed');
    return pending?.future ?? values;
  }

  @override
  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration) async {
    writes++;
    if (fail) throw StateError('Write failed');
    if (pendingSave != null) return pendingSave!.future;
    values = [configuration];
    return configuration;
  }

  @override
  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId) async {
    values = [];
    return AxUserWorkflowConfiguration(workflowId: workflowId);
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async {
    catalogReads++;
    return [
      workflow('chat', 'Chat'),
      workflow('direct', 'Direct'),
      workflow('direct', 'Work', version: 2, steps: ['implement']),
      workflow('implement_verify', 'Implement & Verify',
          steps: ['implement', 'verify'])
    ];
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => workers;
}

class MemoryAxBrowserNavigation implements AxBrowserNavigation {
  MemoryAxBrowserNavigation(this.current);
  @override
  Uri current;
  final controller = StreamController<Uri>.broadcast(sync: true);
  @override
  Stream<Uri> get changes => controller.stream;
  @override
  Stream<void> get lifecycleChanges => const Stream.empty();
  void emit(Uri uri) {
    current = uri;
    controller.add(uri);
  }

  @override
  void push(Uri uri) {
    current = uri;
  }

  @override
  void replace(Uri uri) {
    current = uri;
  }

  @override
  void replaceWithLogin(Uri returnTo) {
    current = Uri(path: '/login');
  }

  @override
  void startSocialLogin(String provider, Uri returnTo) {}
  @override
  void openExternal(Uri uri) {}
  @override
  bool closeCurrentWindow() => false;
  @override
  void dispose() {
    unawaited(controller.close());
  }
}

void main() {
  testWidgets(
      'Workspace switch warns, cancellation preserves preferences, confirmation resets and filters Workers',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()
      ..workers = [worker('a'), worker('b', workspaceId: 'other')]
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'chat',
            enabled: false,
            defaults: const AxWorkflowSelection(
                worker: 'a', model: 'analysis', effort: 'high'),
            stepOverrides: const {'chat': AxWorkflowSelection(effort: 'low')})
      ];
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    Widget page() => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations: cache))));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-workflow-chat')));
    await tester.pumpAndSettle();
    expect(choices(tester, 'defaults', 'Worker'), ['', 'a']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    Future<void> switchWorkspace() async {
      await tester.tap(find.byKey(const ValueKey('workflow-workspace')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second Workspace').last);
      await tester.pumpAndSettle();
      expect(find.text('Change Workspace?'), findsOneWidget);
    }

    await switchWorkspace();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.workspaceWrites, 0);
    expect(source.values.single.enabled, isFalse);
    await switchWorkspace();
    await tester.tap(find.text('Change and reset'));
    await tester.pumpAndSettle();
    expect(source.workspaceWrites, 1);
    expect(source.selectedWorkspace, 'other');
    expect(source.values, isEmpty);
    expect(cache.engine.peek(cache.query).data, isEmpty);
    await tester.tap(find.byKey(const ValueKey('open-workflow-chat')));
    await tester.pumpAndSettle();
    expect(choices(tester, 'defaults', 'Worker'), ['', 'b']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    final reads = source.workspaceReads;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(source.workspaceReads, reads);
  });
  testWidgets(
      'edit choices come from owned Profile capabilities and preserve offline selections',
      (tester) async {
    final source = WorkflowSource()
      ..workers = [
        const AxWorker(
          id: 'worker',
          workspaceId: 'ws',
          workspaceName: 'Laptop',
          workerTypeId: 'custom',
          displayName: 'Custom Worker',
          status: 'offline',
          readinessState: 'offline',
          localConcurrencyLimit: 1,
          capabilities: [],
          executionOptions: AxWorkerExecutionOptions(
              modelSelectionSupported: true,
              modelDiscovery: 'profile_catalog',
              allowsCustomModel: false,
              allowedModelIds: ['custom-model'],
              models: [
                AxWorkerModelOption(
                    id: 'custom-model',
                    name: 'Custom Model',
                    effort: AxWorkerEffortOptions(
                        supported: true, values: ['thorough']))
              ],
              modelSwitchSupported: false,
              effort: AxWorkerEffortOptions(supported: false, values: [])),
        )
      ]
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'chat',
            defaults: const AxWorkflowSelection(
                worker: 'worker', model: 'custom-model', effort: 'thorough'))
      ];
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine))))));
    await tester.pumpAndSettle();
    expect(find.text('Custom Worker · Unavailable'), findsOneWidget);
    expect(find.text('Custom Model'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-workflow-chat')));
    await tester.pumpAndSettle();
    final picker = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(DropdownButtonFormField<String>));
    final model = tester.widget<DropdownButtonFormField<String>>(picker.at(1));
    final effort = tester.widget<DropdownButtonFormField<String>>(picker.at(2));
    // Inspect the dropdown items through its rendered DropdownButton.
    final dropdowns = find.descendant(
        of: picker, matching: find.byType(DropdownButton<String>));
    expect(
        tester
            .widget<DropdownButton<String>>(dropdowns.at(1))
            .items!
            .map((item) => item.value),
        ['', 'custom-model']);
    expect(
        tester
            .widget<DropdownButton<String>>(dropdowns.at(2))
            .items!
            .map((item) => item.value),
        ['', 'thorough']);
    expect(model.initialValue, 'custom-model');
    expect(effort.initialValue, 'thorough');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(source.values.single.defaults.effort, 'thorough');
  });
  testWidgets(
      'unselected Workspace disables cards and wide pages use two columns',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = WorkflowSource()..selectedWorkspace = null;
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine))))));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workflow-status-chat')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('workflow-status-direct')), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-status-implement_verify')),
        findsOneWidget);
    expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('open-workflow-chat')))
            .onTap,
        isNull);
    final chat = tester.getRect(find.byKey(const ValueKey('workflow-chat')));
    final work = tester.getRect(find.byKey(const ValueKey('workflow-direct')));
    expect(chat.width, closeTo(work.width, 1));
    expect(chat.width, greaterThan(400));
    final workspace =
        tester.getRect(find.byKey(const ValueKey('workflow-workspace')));
    final defaultWorkflow =
        tester.getRect(find.byKey(const ValueKey('workflow-default')));
    expect(workspace.center.dy, closeTo(defaultWorkflow.center.dy, 1));
  });
  testWidgets('default workflow is selectable only from enabled workflows',
      (tester) async {
    final source = WorkflowSource()
      ..values = [
        AxUserWorkflowConfiguration(workflowId: 'direct', enabled: false),
      ];
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations: cache)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workflow-default-chat')), findsOneWidget);
    final defaultDropdown = tester.widget<DropdownButton<String>>(
        find.descendant(
            of: find.byKey(const ValueKey('workflow-default')),
            matching: find.byType(DropdownButton<String>)));
    expect(defaultDropdown.items!.map((item) => item.value),
        containsAll(<String?>['chat', 'implement_verify']));
    expect(defaultDropdown.items!.map((item) => item.value),
        isNot(contains('direct')));
    expect(source.defaultWorkflow, 'chat');
  });
  test('foreground recovery refreshes only active stale preferences', () async {
    var now = DateTime(2026);
    final source = WorkflowSource();
    final engine = AxSyncEngine(clock: () => now);
    final cache = AxWorkflowConfigurations(source, engine: engine);
    await cache.ensure();
    final cancel = engine.watch(cache.query, (_) {});
    await engine.refreshActiveStale();
    expect(source.reads, 1);
    now = now.add(const Duration(hours: 1));
    await engine.refreshActiveStale();
    expect(source.reads, 2);
    cancel();
    now = now.add(const Duration(hours: 1));
    await engine.refreshActiveStale();
    expect(source.reads, 2);
  });
  test(
      'cache deduplicates, reuses stale preferences on return, publishes writes and preserves failed refresh data',
      () async {
    var now = DateTime(2026);
    final source = WorkflowSource();
    final engine = AxSyncEngine(clock: () => now);
    final cache = AxWorkflowConfigurations(source, engine: engine);
    source.pending = Completer();
    final first = cache.ensure();
    final second = cache.ensure();
    expect(source.reads, 1);
    source.pending!.complete([]);
    await Future.wait([first, second]);
    source.pending = null;
    now = now.add(const Duration(hours: 2));
    await cache.ensure();
    expect(source.reads, 1);
    var notifications = 0;
    final cancel = engine.watch(cache.query, (_) => notifications++,
        fireImmediately: false);
    await cache
        .save(AxUserWorkflowConfiguration(workflowId: 'chat', enabled: false));
    expect(engine.peek(cache.query).data!.single.enabled, false);
    expect(notifications, greaterThan(0));
    expect(source.reads, 1);
    source.fail = true;
    await expectLater(cache.refresh(), throwsStateError);
    expect(engine.peek(cache.query).data!.single.enabled, false);
    await expectLater(
        cache.save(AxUserWorkflowConfiguration(workflowId: 'chat')),
        throwsStateError);
    expect(engine.peek(cache.query).data!.single.enabled, false);
    source.fail = false;
    await cache.reset('chat');
    expect(engine.peek(cache.query).data!.single.defaults.toJson(), isEmpty);
    cancel();
  });
  test(
      'session clearing fences pending reads and prevents a waiting write from starting',
      () async {
    final source = WorkflowSource()..pending = Completer();
    final store = AxStore(source, persistReadCache: false);
    final cache = store.workflowConfigurations;
    final write = cache.save(AxUserWorkflowConfiguration(workflowId: 'chat'));
    final rejected = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
    store.clearServerState();
    source.pending!.complete([]);
    await rejected;
    expect(source.writes, 0);
    expect(store.syncEngine.peek(cache.query).hasData, false);
    source.pending = null;
    await cache.ensure();
    expect(source.reads, 2);
    store.dispose();
  });
  test('late save cannot repopulate another session', () async {
    final source = WorkflowSource()..pendingSave = Completer();
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    await cache.ensure();
    final write = cache
        .save(AxUserWorkflowConfiguration(workflowId: 'chat', enabled: false));
    await Future<void>.delayed(Duration.zero);
    cache.clear();
    source.pendingSave!.complete(
        AxUserWorkflowConfiguration(workflowId: 'chat', enabled: false));
    await write;
    expect(engine.peek(cache.query).hasData, false);
  });
  testWidgets(
      'overview selects latest definitions, supports editing/reset and reuses preferences after recreation',
      (tester) async {
    final source = WorkflowSource()
      ..values = [
        AxUserWorkflowConfiguration(
            workflowId: 'direct',
            defaults:
                const AxWorkflowSelection(worker: 'offline', effort: 'high'))
      ];
    final engine = AxSyncEngine();
    final cache = AxWorkflowConfigurations(source, engine: engine);
    final catalogs = AxSessionCatalogs(source, engine: engine);
    Widget page() => MaterialApp(
        theme: ConclaveBrand.lightTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child:
                    WorkflowsPage(catalogs: catalogs, configurations: cache))));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('Direct'), findsNothing);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('offline · Unavailable'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('2 steps'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-workflow-chat')));
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    await tester.tap(find.byKey(const ValueKey('open-workflow-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-workflow')));
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    expect(source.catalogReads, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'cold failure is a retryable error rather than an empty successful preference read',
      (tester) async {
    final source = WorkflowSource()..fail = true;
    final engine = AxSyncEngine();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: WorkflowsPage(
                    catalogs: AxSessionCatalogs(source, engine: engine),
                    configurations:
                        AxWorkflowConfigurations(source, engine: engine))))));
    await tester.pumpAndSettle();
    expect(find.text('Workflow configuration is unavailable.'), findsOneWidget);
    source.fail = false;
    await tester.tap(find.byTooltip('Refresh workflows'));
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsAtLeastNWidgets(1));
    expect(source.reads, 2);
  });
  testWidgets(
      'global navigation stays in the application menu and page returns do not reload preferences',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = WorkflowSource();
    final browser = MemoryAxBrowserNavigation(Uri.parse('/workflows'));
    await tester.pumpWidget(ConclaveAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        browserNavigation: browser,
        realtimeClient: TestRealtime()));
    await tester.pumpAndSettle();
    expect(find.byType(WorkflowsPage), findsOneWidget);
    expect(find.text('Workspaces'), findsNothing);
    expect(source.reads, 1);
    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Workflows'), findsNothing);
    expect(find.byTooltip('Workspaces'), findsNothing);
    await tester.tap(find.byTooltip('Application menu'));
    await tester.pumpAndSettle();
    expect(find.text('Workflows'), findsNWidgets(2));
    await tester.tap(find.text('Workflows').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    browser.emit(Uri.parse('/spaces/space-auth'));
    await tester.pumpAndSettle();
    browser.emit(Uri.parse('/spaces/space-auth/threads/thread-auth'));
    await tester.pumpAndSettle();
    browser.emit(Uri.parse('/workflows'));
    await tester.pumpAndSettle();
    expect(source.reads, 1);
    expect(find.byType(WorkflowsPage), findsOneWidget);
    expect(AxNavigation.fromUri(Uri.parse('/workflows')).spaceId, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

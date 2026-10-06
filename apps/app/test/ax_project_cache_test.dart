import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_app.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/sync/ax_project_workstreams.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/navigation/project_tree.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_snapshot.dart';

const a = AxProject(
    id: 'project-auth', name: 'Project A', branch: '', lastActivity: '');
const b =
    AxProject(id: 'atlas', name: 'Project B', branch: '', lastActivity: '');
AxWorkstream stream(String project, String name) => AxWorkstream(
    id: '$project-stream',
    projectId: project,
    name: name,
    lead: '',
    status: 'active',
    brief: '',
    primaryWorkspace: '',
    queueStatus: '');

class ControlledSource extends AxFixtureDataSource {
  final requests = <String, List<Completer<List<AxWorkstream>>>>{};
  int snapshots = 0;
  @override
  Future<List<AxWorkstream>> loadProjectWorkstreams(
      {required String projectId}) {
    final request = Completer<List<AxWorkstream>>();
    requests.putIfAbsent(projectId, () => []).add(request);
    return request.future;
  }

  @override
  Future<AxSnapshot> loadReadModels(
      {String? projectId, String? workspaceId}) async {
    snapshots++;
    final fixture = axFixtureSnapshot();
    return AxSnapshot(
        projects: [a, b],
        workspaces: fixture.workspaces,
        tasks: const [],
        findings: const [],
        events: const [],
        artifacts: const []);
  }
}

void main() {
  test('snapshot reload and ProjectStore never own nested Workstreams',
      () async {
    final store = AxStore(const AxFixtureDataSource());
    await store.projectWorkstreams.ensure(a.id);
    final snapshot = await store.reload(projectId: b.id);
    expect(snapshot.projects.every((p) => p.workstreams.isEmpty), isTrue);
    expect(store.projects.items.every((p) => p.workstreams.isEmpty), isTrue);
    expect(store.projectWorkstreams.peek(a.id).single.name,
        'Authentication hardening');
    expect(store.projectWorkstreams.peek(b.id), isEmpty);
  });

  testWidgets(
      'A survives slow B navigation and returning uses the same collection',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = ControlledSource();
    await tester.pumpWidget(MaterialApp(
        home: ConclaveAppShell(
            services: const DefaultPlatformServices(), dataSource: source)));
    await tester.pumpAndSettle();
    final tree = find.byType(ProjectTree);
    Finder text(String name) =>
        find.descendant(of: tree, matching: find.text(name));
    await tester.tap(text('Project A'));
    await tester.pump();
    expect(source.requests[a.id], hasLength(1));
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    await tester.pumpAndSettle();
    await tester.tap(text('Project B'));
    await tester.pump();
    expect(text('A cached'), findsOneWidget);
    expect(text('Loading Workstreams…'), findsOneWidget);
    expect(source.requests[b.id], hasLength(1));
    expect(source.snapshots, 1);
    source.requests[b.id]!.single.complete([stream(b.id, 'B cached')]);
    await tester.pumpAndSettle();
    expect(text('A cached'), findsOneWidget);
    expect(text('B cached'), findsOneWidget);
    await tester.tap(text('Project A'));
    await tester.pump();
    expect(text('A cached'), findsOneWidget);
    expect(text('B cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(1));
    expect(source.snapshots, 1);
    // Only clicking the already-focused Project is an explicit collapse.
    await tester.tap(text('Project A'));
    await tester.pumpAndSettle();
    expect(text('A cached'), findsNothing);
    expect(text('B cached'), findsOneWidget);
    await tester.tap(text('Project A'));
    await tester.pump();
    expect(text('A cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'stale row retains data, scopes updates and preserves collapse during completion',
      (tester) async {
    final source = ControlledSource();
    var now = DateTime.utc(2026);
    final cache =
        AxProjectWorkstreams(source, engine: AxSyncEngine(clock: () => now));
    final first = cache.ensure(a.id);
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    await first;
    now = now.add(const Duration(minutes: 2));
    final expanded = <String>{a.id, b.id};
    var nav = const AxNavigation.home();
    var rootBuilds = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatefulBuilder(builder: (context, update) {
      rootBuilds++;
      return ProjectTree(
          shellContext: AxShellContext(
              navigation: nav,
              projects: const [a, b],
              projectWorkstreams: cache,
              expandedProjectIds: expanded),
          onCreateProject: () {},
          onNavigateTo: (value) => update(() => nav = value),
          onToggleProjectExpanded: (id) => update(() {
                if (!expanded.remove(id)) expanded.add(id);
              }));
    }))));
    await tester.pump();
    expect(find.text('A cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(2));
    final builds = rootBuilds;
    source.requests[b.id]!.single.complete([stream(b.id, 'B cached')]);
    await tester.pumpAndSettle();
    expect(
        rootBuilds, builds); // Query updates do not rebuild the owning shell.
    tester
        .widget<ProjectTree>(find.byType(ProjectTree))
        .onToggleProjectExpanded(a.id);
    await tester.pump();
    source.requests[a.id]!.last.complete([stream(a.id, 'A refreshed')]);
    await tester.pumpAndSettle();
    expect(find.text('A refreshed'), findsNothing);
    expect(expanded, {b.id});
    await tester.tap(find.text('Project A'));
    await tester.pump();
    expect(find.text('A refreshed'), findsOneWidget);
    expect(find.text('B cached'), findsOneWidget);
    expect(source.requests[a.id], hasLength(2));
  });

  testWidgets('cold failure is local and retry works', (tester) async {
    final source = ControlledSource();
    final cache = AxProjectWorkstreams(source);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ProjectTree(
                shellContext: AxShellContext(
                    navigation: const AxNavigation.home(),
                    projects: const [a],
                    projectWorkstreams: cache,
                    expandedProjectIds: {a.id}),
                onCreateProject: () {},
                onNavigateTo: (_) {},
                onToggleProjectExpanded: (_) {}))));
    source.requests[a.id]!.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Retry Workstreams'), findsOneWidget);
    await tester.tap(find.text('Retry Workstreams'));
    await tester.pump();
    source.requests[a.id]!.last.complete([stream(a.id, 'Recovered')]);
    await tester.pumpAndSettle();
    expect(find.text('Recovered'), findsOneWidget);
    expect(find.text('Retry Workstreams'), findsNothing);
  });

  testWidgets('stale refresh failure keeps cached rows', (tester) async {
    final source = ControlledSource();
    final cache = AxProjectWorkstreams(source);
    final first = cache.ensure(a.id);
    source.requests[a.id]!.single.complete([stream(a.id, 'A cached')]);
    await first;
    cache.engine.invalidate(cache.query(a.id).key);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ProjectTree(
                shellContext: AxShellContext(
                    navigation: const AxNavigation.home(),
                    projects: const [a],
                    projectWorkstreams: cache,
                    expandedProjectIds: {a.id}),
                onCreateProject: () {},
                onNavigateTo: (_) {},
                onToggleProjectExpanded: (_) {}))));
    source.requests[a.id]!.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('A cached'), findsOneWidget);
    expect(find.text('Loading Workstreams…'), findsNothing);
    expect(cache.engine.peek(cache.query(a.id)).error, isStateError);
  });
}

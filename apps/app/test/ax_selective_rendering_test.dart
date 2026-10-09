import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_app.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_snapshot.dart';

class SelectiveSource extends AxFixtureDataSource {
  List<AxWorker> workers = [];
  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => workers;
}

void main() {
  final builds = <String, int>{};
  void observe() {
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      final type = element.widget.runtimeType.toString();
      builds.update(type, (count) => count + 1, ifAbsent: () => 1);
      final key = element.widget.key;
      if (key is ValueKey<String>) {
        builds.update(key.value, (count) => count + 1, ifAbsent: () => 1);
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
  }

  Future<AxStore> shell(WidgetTester tester, String route) async {
    tester.view.physicalSize = const Size(1800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ConclaveAppShell(
        services: const DefaultPlatformServices(),
        dataSource: SelectiveSource(),
        initialUri: Uri.parse(route)));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(ConclaveAppShell));
    return state.store as AxStore;
  }

  for (final spacePage in [true, false]) {
    testWidgets(
        'Worker update leaves shell, sidebar, ${spacePage ? 'Space' : 'Chat and Work history'} untouched',
        (tester) async {
      final space = axFixtureSnapshot().spaces.first;
      final route = spacePage
          ? '/spaces/${space.id}'
          : '/spaces/${space.id}/threads/${space.threads.first.id}';
      final store = await shell(tester, route);
      observe();
      builds.clear();
      store.syncEngine.update(
          store.catalogs.workers,
          (_) => [
                AxWorker.fromJson({
                  'id': 'new-worker',
                  'workspaceId': 'workspace-fixture',
                  'displayName': 'Fresh Worker',
                  'readinessState': 'ready'
                })
              ]);
      await tester.pumpAndSettle();
      for (final type in [
        'ConclaveAppShell',
        'MaterialApp',
        'AxSidebar',
        'SpaceTree',
        'SpacePage',
        'ThreadPage',
        'AxDiscussionBuilder',
        'work-history-scroll'
      ]) {
        expect(builds[type] ?? 0, 0,
            reason: '$type must not rebuild for Worker inventory');
      }
      if (!spacePage) {
        expect(builds['ListenableBuilder'] ?? 0, greaterThan(0));
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'Work history and Discussion update their own panes independently',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final id = space.threads.first.id;
    final store = await shell(tester, '/spaces/${space.id}/threads/$id');
    observe();
    builds.clear();
    store.workHistory.replace(id, []);
    await tester.pumpAndSettle();
    expect(builds['work-history-scroll'] ?? 0, greaterThan(0));
    expect(builds['AxDiscussionBuilder'] ?? 0, 0);
    expect(builds['ThreadPage'] ?? 0, 0);
    expect(builds['ConclaveAppShell'] ?? 0, 0);
    builds.clear();
    await store.discussion.synchronize(id, reconcileNewest: true);
    await tester.pumpAndSettle();
    expect(builds['AxDiscussionBuilder'] ?? 0, greaterThan(0));
    expect(builds['work-history-scroll'] ?? 0, 0);
    expect(builds['ThreadPage'] ?? 0, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Space list updates only its consumers and remains current in sidebar',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final store = await shell(tester, '/spaces/${space.id}');
    observe();
    builds.clear();
    store.spaces.replace([space.copyWith(name: 'Updated in background')]);
    await tester.pumpAndSettle();
    expect(find.text('Updated in background'), findsOneWidget);
    expect(builds['ConclaveAppShell'] ?? 0, 0);
    expect(builds['AxSidebar'] ?? 0, 0);
    expect(builds['SpacePage'] ?? 0, 0);
    expect(
        builds['ValueListenableBuilder<List<AxSpace>>'] ?? 0, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Workspace consumers update counts without rebuilding shell or Space tree',
      (tester) async {
    final store = await shell(tester, '/workspaces');
    observe();
    builds.clear();
    store.syncEngine.update(
        store.catalogs.workers,
        (_) => [
              AxWorker.fromJson({'id': 'w', 'workspaceId': 'workspace-fixture'})
            ]);
    await tester.pumpAndSettle();
    expect(builds['WorkspacesPage'] ?? 0, greaterThan(0));
    expect(builds['ConclaveAppShell'] ?? 0, 0);
    expect(builds['SpaceTree'] ?? 0, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Workflow publication updates controls without rebuilding Chat or history',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final id = space.threads.first.id;
    final store = await shell(tester, '/spaces/${space.id}/threads/$id');
    observe();
    builds.clear();
    store.syncEngine.update(
        store.catalogs.workflows,
        (_) => [
              AxBuiltinWorkflow.fromJson(
                  {'id': 'direct', 'version': 2, 'name': 'Published workflow'})
            ]);
    await tester.pumpAndSettle();
    expect(builds['ListenableBuilder'] ?? 0, greaterThan(0));
    for (final type in [
      'ConclaveAppShell',
      'AxSidebar',
      'AxDiscussionBuilder',
      'ThreadPage',
      'work-history-scroll'
    ]) {
      expect(builds[type] ?? 0, 0, reason: type);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reconnect status and notification count update locally',
      (tester) async {
    final space = axFixtureSnapshot().spaces.first;
    final store = await shell(tester, '/spaces/${space.id}');
    observe();
    builds.clear();
    store.realtimeStatus.value = (true, 'Reconnecting selected resources');
    store.unreadNotifications.value = 3;
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Reconnecting selected resources'), findsOneWidget);
    for (final type in [
      'ConclaveAppShell',
      'AxSidebar',
      'SpaceTree',
      'SpacePage'
    ]) {
      expect(builds[type] ?? 0, 0, reason: type);
    }
    store.realtimeStatus.value = (false, null);
    await tester.pumpWidget(const SizedBox());
  });

  test('Space/Workspace list writes do not notify the execution projection',
      () {
    final store = AxStore(SelectiveSource());
    var executionUpdates = 0;
    store.executionChanges.addListener(() => executionUpdates++);
    final fixture = axFixtureSnapshot();
    store.spaces.replace(fixture.spaces);
    store.workspaces.replace(fixture.workspaces);
    store.replaceExecution(fixture);
    final previous = executionUpdates;
    store.spaces.replace([store.spaces.items.first.copyWith(name: 'Renamed')]);
    store.workspaces.replace([]);
    expect(executionUpdates, previous);
    expect(store.spaces.items.first.name, 'Renamed');
    store.dispose();
  });

  test('execution replacement cannot overwrite collaboration or session state',
      () {
    final store = AxStore(SelectiveSource());
    final fixture = axFixtureSnapshot();
    final renamed = fixture.spaces.first.copyWith(name: 'Cached space');
    store.spaces.replace([renamed]);
    store.workspaces.replace(fixture.workspaces);
    store.auth.replace(fixture.viewer);
    store.replaceExecution(fixture);
    expect(store.spaces.items.single.name, 'Cached space');
    expect(store.workspaces.items, fixture.workspaces);
    expect(store.auth.viewer, fixture.viewer);
    expect(store.execution.spaces, isEmpty);
    expect(store.execution.workspaces, isEmpty);
    expect(store.execution.viewer, isNull);
    expect(() => store.execution.tasks.clear(), throwsUnsupportedError);
    store.dispose();
  });

  test('bootstrap populates independent stores without nested Threads',
      () async {
    final store = AxStore(SelectiveSource());
    final loaded = await store.loadBootstrapState();
    expect(store.spaces.items.map((space) => space.id),
        loaded.spaces.map((space) => space.id));
    expect(store.workspaces.items, loaded.workspaces);
    expect(store.auth.viewer, loaded.viewer);
    expect(store.spaces.items.every((space) => space.threads.isEmpty), isTrue);
    expect(store.execution.spaces, isEmpty);
    expect(store.execution.workspaces, isEmpty);
    store.dispose();
  });

  test('cleared/disposed lists reject late reads', () async {
    final source = PendingLists();
    final store = AxStore(source);
    final spaces = store.spaces.refresh();
    final workspaces = store.workspaces.list();
    store.clearServerState();
    source.spaces.complete(axFixtureSnapshot().spaces);
    source.workspaces.complete(axFixtureSnapshot().workspaces);
    await Future.wait([spaces, workspaces]);
    expect(store.spaces.items, isEmpty);
    expect(store.workspaces.items, isEmpty);
    store.dispose();
  });
}

class PendingLists extends AxFixtureDataSource {
  final spaces = Completer<List<AxSpace>>();
  final workspaces = Completer<List<AxWorkspace>>();
  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) =>
      spaces.future;
  @override
  Future<List<AxWorkspace>> loadWorkspaces() => workspaces.future;
}

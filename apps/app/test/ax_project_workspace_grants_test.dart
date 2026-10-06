import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_app.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/sync/ax_project_workspace_grants.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';

Map<String, dynamic> grant(String id, String ws, {String project = 'P'}) => {
      'id': id,
      'workspaceId': ws,
      'projectId': project,
      'status': 'active',
      'allowedPermissions': ['repository:read'],
    };

class GrantSource extends AxFixtureDataSource {
  final records = <String, AxWorkspaceGrants>{
    'P': [grant('g1', 'A'), grant('g2', 'B')]
  };
  final loads = <String>[];
  final reads = <Completer<AxWorkspaceGrants>>[];
  final writes = <Completer<void>>[];
  bool failReads = false;
  @override
  Future<AxWorkspaceGrants> loadProjectWorkspaces({required String projectId}) {
    loads.add(projectId);
    if (failReads) return Future.error(StateError('offline'));
    return reads.isEmpty
        ? Future.value(records[projectId] ?? [])
        : reads.removeAt(0).future;
  }

  Future<void> write(void Function() commit) {
    final response = Completer<void>();
    writes.add(response);
    return response.future.then((_) => commit());
  }

  @override
  Future<void> requestProjectWorkspace(
          {required String projectId,
          required String workspaceId,
          List<String> allowedPermissions = const []}) =>
      write(() {
        records[projectId] = [
          ...records[projectId] ?? [],
          {
            ...grant('server', workspaceId, project: projectId),
            'allowedPermissions': allowedPermissions
          }
        ];
      });
  @override
  Future<void> updateWorkspaceProjectPermissions(
          {required String grantId,
          required List<String> allowedPermissions}) =>
      write(() {
        for (final id in records.keys.toList()) {
          records[id] = [
            for (final row in records[id]!)
              if (row['id'] == grantId)
                {...row, 'allowedPermissions': allowedPermissions}
              else
                row
          ];
        }
      });
  @override
  Future<void> revokeWorkspaceProjectGrant({required String grantId}) =>
      write(() {
        for (final id in records.keys.toList()) {
          records[id] =
              records[id]!.where((row) => row['id'] != grantId).toList();
        }
      });
}

class ManyProjectsSource extends AxFixtureDataSource {
  int grantReads = 0;
  final projects = [
    for (var i = 0; i < 30; i++)
      AxProject.fromJson({'id': 'P$i', 'name': 'Project $i'})
  ];
  final workspaces = [
    const AxWorkspace(id: 'owned', name: 'Owned machine', projectGrantCount: 30)
  ];
  @override
  Future<List<AxProject>> loadProjects({bool includeArchived = false}) async =>
      projects;
  @override
  Future<List<AxWorkspace>> loadWorkspaces() async => workspaces;
  @override
  Future<AxSnapshot> loadBootstrapState(
          {String? projectId, String? workspaceId}) async =>
      (await super.loadBootstrapState())
          .copyWith(projects: projects, workspaces: workspaces);
  @override
  Future<AxWorkspaceGrants> loadProjectWorkspaces(
      {required String projectId}) async {
    grantReads++;
    return [];
  }
}

void main() {
  test(
      'same Project shares reads and nested immutable grant data; other Projects remain separate',
      () async {
    final source = GrantSource();
    final cache = AxProjectWorkspaceGrants(source);
    final pending = Completer<AxWorkspaceGrants>();
    source.reads.add(pending);
    final a = cache.ensure('P');
    expect(cache.ensure('P'), same(a));
    pending.complete(source.records['P']);
    await a;
    await cache.ensure('P');
    await cache.ensure('Q');
    expect(source.loads, ['P', 'Q']);
    expect(() => cache.peek('P').data!.first['status'] = 'revoked',
        throwsUnsupportedError);
    expect(
        () =>
            (cache.peek('P').data!.first['allowedPermissions'] as List).clear(),
        throwsUnsupportedError);
  });
  test('stale grants return immediately and retain data while refreshing',
      () async {
    var now = DateTime.utc(2026);
    final source = GrantSource();
    final cache = AxProjectWorkspaceGrants(source,
        engine: AxSyncEngine(clock: () => now));
    await cache.ensure('P');
    now = now.add(const Duration(minutes: 1));
    final response = Completer<AxWorkspaceGrants>();
    source.reads.add(response);
    expect((await cache.ensure('P')).length, 2);
    expect(cache.peek('P').isFetching, isTrue);
    response.complete([]);
    await Future<void>.delayed(Duration.zero);
    expect(cache.peek('P').data, isEmpty);
  });
  test(
      'create appears in all listeners immediately and reconciles the temporary ID',
      () async {
    final source = GrantSource();
    final cache = AxProjectWorkspaceGrants(source);
    await cache.ensure('P');
    var changes = 0;
    cache.watch('P', (_) => changes++);
    final write = cache.create(projectId: 'P', workspaceId: 'C');
    expect(cache.peek('P').data!.last['id'], startsWith('local-grant:'));
    expect(changes, greaterThan(0));
    source.writes.single.complete();
    await write;
    expect(cache.peek('P').data!.last['id'], 'server');
    expect(source.loads, ['P', 'P']);
    expect(cache.peek('P').isStale, isFalse);
  });
  test(
      'permission edits update optimistically and failed edits restore previous permissions',
      () async {
    final source = GrantSource();
    final cache = AxProjectWorkspaceGrants(source);
    await cache.ensure('P');
    final write = cache.updatePermissions(
        projectId: 'P',
        grantId: 'g1',
        allowedPermissions: ['repository:write']);
    expect(cache.peek('P').data!.first['allowedPermissions'],
        ['repository:write']);
    final check = expectLater(write, throwsStateError);
    source.writes.single.completeError(StateError('denied'));
    await check;
    expect(
        cache.peek('P').data!.first['allowedPermissions'], ['repository:read']);
    expect(source.loads, ['P']);
  });
  test('revoke removes optimistically then reconciles only its Project',
      () async {
    final source = GrantSource();
    final cache = AxProjectWorkspaceGrants(source);
    await cache.ensure('P');
    await cache.ensure('Q');
    final write = cache.revoke(projectId: 'P', grantId: 'g1');
    expect(cache.peek('P').data!.map((row) => row['id']), ['g2']);
    source.writes.single.complete();
    await write;
    expect(source.loads, ['P', 'Q', 'P']);
  });
  test('a failed concurrent edit does not roll back a successful revoke',
      () async {
    final source = GrantSource();
    final cache = AxProjectWorkspaceGrants(source);
    await cache.ensure('P');
    final edit = cache.updatePermissions(
        projectId: 'P',
        grantId: 'g1',
        allowedPermissions: ['repository:write']);
    final revoke = cache.revoke(projectId: 'P', grantId: 'g2');
    source.writes[1].complete();
    await revoke;
    expect(cache.peek('P').data!.single['allowedPermissions'],
        ['repository:write']);
    final check = expectLater(edit, throwsStateError);
    source.writes[0].completeError(StateError('denied'));
    await check;
    expect(cache.peek('P').data!.single['id'], 'g1');
    expect(cache.peek('P').data!.single['allowedPermissions'],
        ['repository:read']);
  });
  test('realtime read during a pending write retains the optimistic overlay',
      () async {
    final source = GrantSource();
    final store = AxStore(source);
    final cache = store.projectWorkspaceGrants;
    await cache.ensure('P');
    final write = cache.revoke(projectId: 'P', grantId: 'g1');
    await store.realtimeCacheRouter
        .handle({'type': 'project_workspace_grant.updated', 'projectId': 'P'});
    expect(cache.peek('P').data!.map((row) => row['id']), ['g2']);
    source.writes.single.complete();
    await write;
  });
  test('grant signals refresh only the owning grant collection', () async {
    final source = GrantSource();
    final store = AxStore(source);
    await store.projectWorkspaceGrants.ensure('P');
    await store.projectWorkspaceGrants.ensure('Q');
    var detailReads = 0;
    final detail = AxQuery<int>(
        key: AxQueryKey(['project', 'P']), load: () async => ++detailReads);
    await store.syncEngine.ensure(detail);
    await store.realtimeCacheRouter
        .handle({'type': 'project_workspace_grant.updated', 'projectId': 'P'});
    expect(source.loads, ['P', 'Q', 'P']);
    expect(detailReads, 1);
  });
  test('confirmed mutation survives a reconciliation failure and can retry',
      () async {
    final source = GrantSource();
    final cache = AxProjectWorkspaceGrants(source);
    await cache.ensure('P');
    final write = cache.revoke(projectId: 'P', grantId: 'g1');
    source.failReads = true;
    source.writes.single.complete();
    await write;
    expect(cache.peek('P').data!.map((row) => row['id']), ['g2']);
    expect(cache.peek('P').error, isA<StateError>());
    source.failReads = false;
    await cache.refresh('P');
    expect(cache.peek('P').error, isNull);
  });
  test('session clear and Project deletion fence pending grant writes',
      () async {
    for (final deleted in [false, true]) {
      final source = GrantSource();
      final store = AxStore(source);
      final cache = store.projectWorkspaceGrants;
      await cache.ensure('P');
      final write = cache.create(projectId: 'P', workspaceId: 'C');
      if (deleted) {
        await store.realtimeCacheRouter
            .handle({'type': 'project.deleted', 'projectId': 'P'});
      } else {
        store.clearServerState();
      }
      source.writes.single.complete();
      await write;
      expect(cache.peek('P').hasData, isFalse);
      expect(source.loads, ['P']);
    }
  });
  testWidgets(
      '30-Project Workspace screen uses aggregate counts with zero Project grant reads',
      (tester) async {
    final source = ManyProjectsSource();
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: ConclaveAppShell(
      services: const DefaultPlatformServices(),
      dataSource: source,
      initialUri: Uri(path: '/workspaces'),
    )));
    await tester.pumpAndSettle();
    expect(source.grantReads, 0);
    expect(find.textContaining('30 Project grants'), findsOneWidget);
  });
}

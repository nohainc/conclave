import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';
import 'package:conclave_app/src/ax/sync/persistence/ax_persistent_read_cache.dart';
import 'ax_fixture_data.dart';

AxStore store(MemoryAxReadCacheBackend backend, {String user = 'A'}) {
  final value = AxStore(const AxFixtureDataSource(), readCacheBackend: backend);
  value.auth.session = AxSession(
      authenticated: true,
      viewer: AxViewer(id: user, displayName: user, email: 'private@test'));
  return value;
}

const project = AxProject(
    id: 'P',
    name: 'Cached Project',
    branch: 'main',
    lastActivity: 'now',
    settings: {
      'token': 'SECRET',
      'providerCredentials': {'apiKey': 'SECRET'},
      'workstreamOrder': ['W']
    });
AxWorkRequest request(String id) => AxWorkRequest(
    id: id,
    requestedByName: 'Human',
    prompt: 'Work',
    workflowId: 'direct',
    workflowVersion: 2,
    status: 'completed',
    createdAt: '2026-10-06T00:00:00Z',
    steps: const []);

class SessionSource extends AxFixtureDataSource {
  final pending = Completer<AxSession>();
  @override
  Future<AxSession> loadSession() => pending.future;
}

class BrokenBackend implements AxReadCacheBackend {
  @override
  Future<AxReadCacheSnapshot> read(String userId) async =>
      throw StateError('storage blocked');
  @override
  Future<bool> write(String userId, int revision,
          List<Map<String, dynamic>> records) async =>
      throw StateError('quota');
  @override
  Future<void> clear(String userId) async => throw StateError('blocked');
  @override
  void close() {}
}

class DelayedBackend extends MemoryAxReadCacheBackend {
  Completer<AxReadCacheSnapshot>? pending;
  @override
  Future<AxReadCacheSnapshot> read(String userId) =>
      pending?.future ?? super.read(userId);
}

void main() {
  test('late authentication cannot reactivate persistence after logout',
      () async {
    final source = SessionSource();
    final value = AxStore(source, readCacheBackend: MemoryAxReadCacheBackend());
    final loading = value.auth.load();
    await value.logout();
    source.pending.complete(const AxSession(
        authenticated: true,
        viewer: AxViewer(id: 'A', displayName: 'A', email: '')));
    await expectLater(loading, throwsStateError);
    expect(value.auth.session!.authenticated, isFalse);
    expect(await value.hydrateReadCache(), isFalse);
    value.dispose();
  });
  test(
      'only the 20 most recently used persisted Workstream histories are retained',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final value = store(backend);
    await value.hydrateReadCache();
    for (var i = 0; i < 25; i++) {
      final query = value.workHistory.query('W$i');
      value.syncEngine.update(
          query,
          (_) =>
              AxWorkHistory(requests: [request('R$i')], initialLoaded: true));
      value.syncEngine.peek(query);
    }
    await value.persistence.flush();
    final records = (await backend.read('A')).records;
    expect(records, hasLength(20));
    expect(records.any((r) => (r['key'] as List)[1] == 'W0'), isFalse);
    expect(records.any((r) => (r['key'] as List)[1] == 'W24'), isTrue);
    value.dispose();
  });

  test(
      'persistent histories are bounded and restore valid pagination frontiers',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    final messages = List.generate(
        120,
        (i) => AxDiscussionMessage(
            id: 'D${i.toString().padLeft(3, '0')}',
            workstreamId: 'W',
            authorUserId: 'A',
            body: 'Message $i',
            createdAt: 'now'));
    first.syncEngine.update(
        first.discussion.query('W'),
        (_) => AxDiscussionHistory(
            messages: messages,
            initialLoaded: true,
            olderCursor: 'older-opaque',
            newestCursor: 'newest-opaque'));
    first.syncEngine.update(
        first.workHistory.query('W'),
        (_) => AxWorkHistory(
            requests: List.generate(120, (i) => request('R$i')),
            initialLoaded: true));
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    expect(second.discussion.peek('W').messages, hasLength(50));
    expect(second.discussion.peek('W').messages.first.id, 'D070');
    expect(second.discussion.peek('W').olderCursor, isNull);
    expect(second.workHistory.peek('W').requests, hasLength(50));
    expect(second.workHistory.peek('W').olderCursor!.id, 'R70');
    first.dispose();
    second.dispose();
  });
  test('five callers see hydrated state and share one background request',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.projects.replace([project]);
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    var reads = 0;
    final pending = Completer<List<AxProject>>();
    final query = AxQuery<List<AxProject>>(
        key: second.projects.query.key,
        load: () {
          reads++;
          return pending.future;
        });
    final values = await Future.wait(
        List.generate(5, (_) => second.syncEngine.ensure(query)));
    expect(values.every((v) => v.single.name == 'Cached Project'), isTrue);
    expect(reads, 1);
    pending.complete([project.copyWith(name: 'Revalidated')]);
    await Future<void>.delayed(Duration.zero);
    expect(second.projects.items.single.name, 'Revalidated');
    first.dispose();
    second.dispose();
  });

  test(
      'hydrates only the authenticated user and renders safe collections without a Cloud read',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.projects.replace([project]);
    first.workspaces.replace([const AxWorkspace(id: 'X', name: 'Workspace')]);
    first.syncEngine.update(
        first.projectWorkstreams.query('P'),
        (_) => [
              AxWorkstream.fromJson(
                  {'id': 'W', 'projectId': 'P', 'name': 'Stream'})
            ]);
    first.syncEngine.update(
        first.discussion.query('W'),
        (_) => AxDiscussionHistory(initialLoaded: true, messages: const [
              AxDiscussionMessage(
                  id: 'D',
                  workstreamId: 'W',
                  authorUserId: 'A',
                  body: 'Hello',
                  createdAt: 'now')
            ]));
    first.syncEngine.update(
        first.workHistory.query('W'),
        (_) => AxWorkHistory(
            initialLoaded: true,
            requests: [request('R')],
            confirmedIds: const ['R']));
    await first.persistence.flush();
    final text = jsonEncode((await backend.read('A')).records);
    expect(text, contains('Cached Project'));
    expect(text, isNot(contains('SECRET')));
    expect(text, isNot(contains('private@test')));
    final other = store(backend, user: 'B');
    expect(await other.hydrateReadCache(), isFalse);
    expect(other.projects.items, isEmpty);
    final reopened = store(backend);
    expect(await reopened.hydrateReadCache(), isTrue);
    expect(reopened.projects.items.single.name, 'Cached Project');
    expect(reopened.workspaces.items.single.name, 'Workspace');
    expect(reopened.discussion.peek('W').messages.single.isMe, isTrue);
    expect(reopened.workHistory.peek('W').requests.single.id, 'R');
    expect(reopened.syncEngine.peek(reopened.projects.query).isStale, isTrue);
    first.dispose();
    other.dispose();
    reopened.dispose();
  });
  test(
      'never persists pending mutation overlays, local Work, security or unknown query keys',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final value = store(backend);
    await value.hydrateReadCache();
    value.projects.replace([project]);
    final overlay = value.syncEngine.optimisticUpdate(
        value.projects.query, (_) => [project.copyWith(name: 'Pending name')]);
    value.syncEngine.update(
        AxQuery<String>(
            key: AxQueryKey(['security']), load: () async => 'SECRET'),
        (_) => 'SECRET');
    value.syncEngine.update(
        value.workHistory.query('W'),
        (_) =>
            AxWorkHistory(requests: [request('local-pending'), request('R')]));
    await value.persistence.flush();
    final text = jsonEncode((await backend.read('A')).records);
    expect(text, isNot(contains('Pending name')));
    expect(text, isNot(contains('SECRET')));
    expect(text, isNot(contains('local-pending')));
    expect(text, contains('Cached Project'));
    overlay.rollback();
    value.dispose();
  });
  test('hydration does not overwrite newer data or in-flight reads', () async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.projects.replace([project]);
    await first.persistence.flush();
    final second = store(backend);
    second.projects.replace([project.copyWith(name: 'New')]);
    await second.hydrateReadCache();
    expect(second.projects.items.single.name, 'New');
    final engine = AxSyncEngine();
    final pending = Completer<List<AxProject>>();
    final query = AxQuery<List<AxProject>>(
        key: AxQueryKey(['projects']), load: () => pending.future);
    final read = engine.refresh(query);
    final cache = AxPersistentReadCache(engine, const AxFixtureDataSource(),
        backend: backend);
    expect(await cache.hydrate('A'), isFalse);
    expect(engine.peek(query).hasData, isFalse);
    pending.complete([project.copyWith(name: 'Network')]);
    await read;
    expect(engine.peek(query).data!.single.name, 'Network');
    cache.dispose();
    first.dispose();
    second.dispose();
  });
  test(
      'logout clears memory and only that user disk data, rejects old tab writes',
      () async {
    final backend = MemoryAxReadCacheBackend();
    final a = store(backend);
    final b = store(backend, user: 'B');
    await a.hydrateReadCache();
    await b.hydrateReadCache();
    a.projects.replace([project]);
    b.projects.replace([project.copyWith(name: 'B')]);
    await a.persistence.flush();
    await b.persistence.flush();
    final stale = await backend.read('A');
    await a.logout();
    expect(a.projects.items, isEmpty);
    expect(a.workHistory.peek('W').requests, isEmpty);
    expect((await backend.read('A')).records, isEmpty);
    expect((await backend.read('B')).records, isNotEmpty);
    expect(await backend.write('A', stale.revision, stale.records), isFalse);
    a.dispose();
    b.dispose();
  });
  test('late hydration after logout cannot restore private history', () async {
    final backend = DelayedBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.projects.replace([project]);
    await first.persistence.flush();
    final snapshot = await backend.read('A');
    backend.pending = Completer();
    final late = store(backend);
    final hydration = late.hydrateReadCache();
    await Future<void>.delayed(Duration.zero);
    late.clearServerState();
    backend.pending!.complete(snapshot);
    expect(await hydration, isFalse);
    expect(late.projects.items, isEmpty);
    await late.persistence.flush();
    expect((await backend.read('A')).records,
        isNotEmpty); // delayed test read returns the captured snapshot
    backend.pending = null;
    expect((await backend.read('A')).records, isEmpty);
    first.dispose();
    late.dispose();
  });
  test(
      'storage unavailable or explicitly disabled leaves ordinary memory caching intact',
      () async {
    for (final enabled in [true, false]) {
      final value = AxStore(const AxFixtureDataSource(),
          readCacheBackend: BrokenBackend(), persistReadCache: enabled);
      value.auth.session = const AxSession(
          authenticated: true,
          viewer: AxViewer(id: 'A', displayName: 'A', email: ''));
      expect(await value.hydrateReadCache(), isFalse);
      value.projects.replace([project]);
      await value.persistence.flush();
      expect(value.projects.items.single.name, 'Cached Project');
      await value.logout();
      expect(value.projects.items, isEmpty);
      value.dispose();
    }
  });
  test('corrupt records and unsupported versions are discarded individually',
      () async {
    final backend = MemoryAxReadCacheBackend();
    await backend.write('A', 0, [
      {
        'version': 999,
        'key': ['projects'],
        'data': []
      },
      {
        'version': 1,
        'key': ['projects'],
        'data': 'bad'
      }
    ]);
    final value = store(backend);
    expect(await value.hydrateReadCache(), isFalse);
    expect(value.projects.items, isEmpty);
    value.dispose();
  });
  testWidgets(
      'hydrated Project renders while background read is pending and remains on failure',
      (tester) async {
    final backend = MemoryAxReadCacheBackend();
    final first = store(backend);
    await first.hydrateReadCache();
    first.projects.replace([project]);
    await first.persistence.flush();
    final second = store(backend);
    await second.hydrateReadCache();
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<List<AxProject>>(
            valueListenable: second.projects,
            builder: (context, values, _) => Text(values.single.name))));
    expect(find.text('Cached Project'), findsOneWidget);
    final pending = Completer<List<AxProject>>();
    final query = AxQuery<List<AxProject>>(
        key: second.projects.query.key, load: () => pending.future);
    await second.syncEngine.ensure(query);
    await tester.pump();
    expect(find.text('Cached Project'), findsOneWidget);
    pending.completeError(StateError('offline'));
    await tester.pump();
    expect(find.text('Cached Project'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  });
}

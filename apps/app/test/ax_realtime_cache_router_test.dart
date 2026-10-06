import 'dart:async';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/sync/ax_realtime_cache_router.dart';

void main() {
  late AxSyncEngine engine;
  late AxRealtimeCacheRouter router;
  late Map<String, int> loads;
  AxQuery<int> query(List<String> parts) => AxQuery(
      key: AxQueryKey(parts),
      load: () async {
        final name = parts.join(':');
        return loads.update(name, (n) => n + 1, ifAbsent: () => 1);
      });
  setUp(() {
    engine = AxSyncEngine();
    router = AxRealtimeCacheRouter(engine);
    loads = {};
  });
  test('background Project updates only its own registered queries', () async {
    final a = query(['project', 'A', 'workstreams']);
    final b = query(['project', 'B', 'workstreams']);
    await engine.ensure(a);
    await engine.ensure(b);
    var aChanges = 0;
    var bChanges = 0;
    engine.watch(a, (_) => aChanges++, fireImmediately: false);
    engine.watch(b, (_) => bChanges++, fireImmediately: false);
    await router.handle(
        {'type': 'workstream.updated', 'projectId': 'A', 'workstreamId': 'W'});
    expect(engine.peek(a).data, 2);
    expect(engine.peek(b).data, 1);
    expect(aChanges, greaterThan(0));
    expect(bChanges, 0);
  });
  test('Discussion routing survives a destroyed view and excludes history',
      () async {
    final chat = query(['workstream', 'W', 'discussion']);
    final history = query(['workstream', 'W', 'work-requests']);
    await engine.ensure(chat);
    await engine.ensure(history);
    await router.handle({
      'type': 'workstream.discussion.created',
      'payload': {'workstreamId': 'W'}
    });
    expect(engine.peek(chat).data, 2);
    expect(engine.peek(history).data, 1);
  });
  test('Workstream ID finds its cached parent without a Project envelope',
      () async {
    var calls = 0;
    final q = AxQuery<List<AxWorkstream>>(
        key: AxQueryKey(['project', 'A', 'workstreams']),
        load: () async {
          calls++;
          return [
            AxWorkstream.fromJson({'id': 'W', 'projectId': 'A'})
          ];
        });
    await engine.ensure(q);
    await router.handle({
      'type': 'workstream.updated',
      'payload': {'entityId': 'W'}
    });
    expect(calls, 2);
  });
  test('failed refresh preserves cached data and exposes a query error',
      () async {
    var fail = false;
    final q = AxQuery<int>(
        key: AxQueryKey(['project', 'A']),
        load: () async {
          if (fail) throw StateError('offline');
          return 1;
        });
    await engine.ensure(q);
    fail = true;
    await expectLater(
        router.handle({'type': 'project.updated', 'projectId': 'A'}),
        throwsStateError);
    expect(engine.peek(q).data, 1);
    expect(engine.peek(q).isStale, isTrue);
    expect(engine.peek(q).error, isA<StateError>());
  });
  test('session clear fences a pending event refresh', () async {
    final delayed = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['project', 'A']),
        load: () => ++calls == 1 ? Future.value(1) : delayed.future);
    await engine.ensure(q);
    final refresh =
        router.handle({'type': 'project.updated', 'projectId': 'A'});
    engine.clear();
    router.reset();
    delayed.complete(2);
    await refresh;
    expect(engine.peek(q).hasData, isFalse);
  });
  test('scoped reconnect does not expand to parent or child queries', () async {
    var collections = 0;
    final q = AxQuery<List<AxWorkstream>>(
        key: AxQueryKey(['project', 'A', 'workstreams']),
        load: () async {
          collections++;
          return [
            AxWorkstream.fromJson({'id': 'W', 'projectId': 'A'})
          ];
        });
    await engine.ensure(q);
    await engine.ensure(query(['workstream', 'W', 'discussion']));
    await engine.ensure(query(['workstream', 'other', 'discussion']));
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'project', 'projectId': 'A'}
    });
    expect(collections, 2);
    expect(loads.values.toList(), [1, 1]);
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'workstream', 'workstreamId': 'W'}
    });
    expect(collections, 2);
    expect(loads.values.toList(), [2, 1]);
  });
  test('stream identity narrows a user-scope gap', () async {
    await engine.ensure(query(['project', 'A']));
    await engine.ensure(query(['project', 'B']));
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'user'},
      'stream': {'kind': 'project', 'id': 'A'},
    });
    expect(loads.values.toList(), [2, 1]);
  });
  test('malformed narrow scope does not reload every cache', () async {
    await engine.ensure(query(['project', 'A']));
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'project'},
    });
    expect(loads.values.single, 1);
  });
  test('user recovery leaves unobserved Project data for stale navigation',
      () async {
    final q = query(['project', 'A']);
    await engine.ensure(q);
    await router.handle({'type': 'realtime.ready'});
    expect(loads.values.single, 1);
    expect(engine.peek(q).data, 1);
    expect(engine.peek(q).isStale, isTrue);
  });
  test('reconnect retains data while only the matching query loads', () async {
    final delayed = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['project', 'A']),
        load: () => ++calls == 1 ? Future.value(1) : delayed.future);
    await engine.ensure(q);
    final other = query(['project', 'B']);
    await engine.ensure(other);
    final recovery = router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'project', 'projectId': 'A'}
    });
    expect(engine.peek(q).data, 1);
    expect(engine.peek(q).isFetching, isTrue);
    expect(engine.peek(other).data, 1);
    delayed.complete(2);
    await recovery;
    expect(engine.peek(q).data, 2);
  });
  test('Discussion recovery uses the incremental integration callback',
      () async {
    final q = query(['workstream', 'W', 'discussion']);
    await engine.ensure(q);
    final ids = <String>[];
    router = AxRealtimeCacheRouter(engine, discussionResynchronize: (id) async {
      ids.add(id);
    });
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'workstream', 'workstreamId': 'W'}
    });
    expect(ids, ['W']);
    expect(loads.values.single, 1);
    expect(engine.peek(q).data, 1);
  });
  test('reconnect bursts share one recovery without detaching it', () async {
    final delayed = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['project', 'A']),
        load: () => ++calls == 1 ? Future.value(1) : delayed.future);
    await engine.ensure(q);
    final event = {
      'type': 'reconnect.required',
      'scope': {'kind': 'project', 'projectId': 'A'}
    };
    final first = router.handle(event);
    final second = router.handle(event);
    expect(calls, 2);
    expect(engine.peek(q).data, 1);
    delayed.complete(2);
    await Future.wait([first, second]);
    expect(engine.peek(q).data, 2);
    expect(engine.peek(q).isStale, isFalse);
  });
  test('cold observed Discussion participates in reconnect recovery', () async {
    final old = Completer<int>();
    final q = AxQuery<int>(
        key: AxQueryKey(['workstream', 'W', 'discussion']),
        load: () => old.future);
    engine.watch(q, (_) {});
    final initial = engine.ensure(q);
    final ids = <String>[];
    router = AxRealtimeCacheRouter(engine, discussionResynchronize: (id) async {
      ids.add(id);
      await engine.refresh<int>(AxQuery<int>(key: q.key, load: () async => 2));
    });
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'workstream', 'workstreamId': 'W'}
    });
    old.complete(1);
    await initial;
    expect(ids, ['W']);
    expect(engine.peek(q).data, 2);
  });
  test('scope invalidation excludes immutable Work cursor pages', () async {
    final current = query(['workstream', 'W', 'work-requests']);
    final older = query(['workstream', 'W', 'work-requests', 'old']);
    await engine.ensure(current);
    await engine.ensure(older);
    engine.invalidateScope(const AxSyncScope('workstream', 'W'));
    expect(engine.peek(current).data, 1);
    expect(engine.peek(current).isStale, isTrue);
    expect(engine.peek(older).isStale, isFalse);
    expect(loads.values.toList(), [1, 1]);
  });
  test('user recovery excludes detached Discussion cache bridge listeners',
      () async {
    final q = query(['workstream', 'W', 'discussion']);
    await engine.ensure(q);
    engine.watch(q, (_) {});
    final ids = <String>[];
    router = AxRealtimeCacheRouter(engine,
        discussionObserved: (_) => false,
        discussionResynchronize: (id) async {
          ids.add(id);
        });
    await router.handle({'type': 'realtime.ready'});
    expect(ids, isEmpty);
    expect(engine.peek(q).isStale, isTrue);
    expect(engine.peek(q).data, 1);
  });
  test('Project deletion fences even an unhydrated in-flight query', () async {
    final response = Completer<int>();
    final q = AxQuery<int>(
        key: AxQueryKey(['project', 'A']), load: () => response.future);
    final read = engine.ensure(q);
    await router.handle({'type': 'project.deleted', 'projectId': 'A'});
    response.complete(1);
    await read;
    expect(engine.peek(q).hasData, isFalse);
  });
  test('unknown resources do not trigger eager requests', () async {
    await router.handle({'type': 'project.updated', 'projectId': 'unknown'});
    expect(loads, isEmpty);
  });
  test('user reconnect revalidates cached resources but never older Work pages',
      () async {
    final keys = [
      ['project', 'A'],
      ['project', 'B', 'workstreams'],
      ['workstream', 'W', 'discussion'],
      ['workstream', 'W', 'work-requests', 'old']
    ];
    for (final key in keys) {
      final q = query(key);
      await engine.ensure(q);
      engine.watch(q, (_) {});
    }
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'user'}
    });
    expect(loads.values.toList(), [2, 2, 2, 1]);
  });
  test('Project reconnect does not refresh another Project', () async {
    await engine.ensure(query(['project', 'A']));
    await engine.ensure(query(['project', 'B']));
    await router.handle({
      'type': 'reconnect.required',
      'scope': {'kind': 'project', 'projectId': 'A'}
    });
    expect(loads.values.toList(), [2, 1]);
  });
  test('duplicate delivery is ignored and reset permits a new session',
      () async {
    await engine.ensure(query(['project', 'A']));
    final event = {'eventId': 'E', 'type': 'project.updated', 'projectId': 'A'};
    await router.handle(event);
    await router.handle(event);
    expect(loads.values.single, 2);
    router.reset();
    await router.handle(event);
    expect(loads.values.single, 3);
  });
  test('late pre-event response cannot overwrite revalidated state', () async {
    final old = Completer<int>();
    var calls = 0;
    final q = AxQuery<int>(
        key: AxQueryKey(['project', 'A']),
        load: () => ++calls == 1 ? old.future : Future.value(2));
    final first = engine.ensure(q);
    await router.handle({'type': 'project.updated', 'projectId': 'A'});
    old.complete(1);
    await first;
    expect(engine.peek(q).data, 2);
  });
}

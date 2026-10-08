import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';
import 'ax_discussion_cache_test.dart' show message, DiscussionSource;
import 'ax_work_history_test.dart' show request;

Future<void> settle() => Future<void>.delayed(Duration.zero);
AxQuery<int> query(List<String> parts) =>
    AxQuery(key: AxQueryKey(parts), load: () async => 1);

void main() {
  test('default retains 20 combined histories and leaves session data alone',
      () async {
    final engine = AxSyncEngine();
    final chat = AxDiscussionCache(null, engine: engine);
    final work = AxWorkHistoryCache(null, engine: engine);
    for (final key in [
      ['spaces'],
      ['space', 'p', 'threads'],
      ['workflow-catalog']
    ]) {
      engine.update(query(key), (_) => 42);
    }
    for (var i = 0; i < 100; i++) {
      chat.peek('$i');
      work.replace('$i', [request('1')]);
      await settle();
    }
    final ids = engine.relevantKeys
        .where((key) => key.parts.first == 'thread')
        .map((key) => key.parts[1])
        .toSet();
    expect(ids.length, 20);
    expect(ids, containsAll(['80', '99']));
    expect(work.threadIds.length, lessThanOrEqualTo(20));
    expect(engine.cachedValues<int>().values, everyElement(42));
  });

  test('touching a cached history changes its LRU position', () async {
    var now = DateTime.utc(2026);
    final engine = AxSyncEngine(clock: () => now, maxRetainedThreads: 2);
    final chat = AxDiscussionCache(null, engine: engine);
    chat.peek('a');
    await settle();
    now = now.add(const Duration(seconds: 1));
    chat.peek('b');
    await settle();
    now = now.add(const Duration(seconds: 1));
    chat.peek('a');
    now = now.add(const Duration(seconds: 1));
    chat.peek('c');
    await settle();
    expect(engine.relevantKeys.map((key) => key.parts[1]),
        unorderedEquals(['a', 'c']));
  });

  test('visible histories survive overflow and release enforces the limit',
      () async {
    final engine = AxSyncEngine(maxRetainedThreads: 1);
    final chat = AxDiscussionCache(null, engine: engine);
    final releaseA = chat.watch('a', (_) {});
    final releaseB = chat.watch('b', (_) {});
    await settle();
    expect(engine.relevantKeys.length, 2);
    releaseA();
    await settle();
    expect(engine.relevantKeys.single.parts[1], 'b');
    releaseB();
  });

  test('read in flight is protected and collection resumes on completion',
      () async {
    final engine = AxSyncEngine(maxRetainedThreads: 1);
    final pending = Completer<int>();
    final a = AxQuery(
        key: AxQueryKey(['thread', 'a', 'discussion']),
        load: () => pending.future);
    final read = engine.refresh(a);
    final b = query(['thread', 'b', 'discussion']);
    final release = engine.watch(b, (_) {});
    await settle();
    expect(engine.relevantKeys.length, 2);
    pending.complete(1);
    await read;
    await settle();
    expect(engine.relevantKeys.single, b.key);
    release();
  });

  test('optimistic write is protected until its overlay is committed',
      () async {
    final engine = AxSyncEngine(maxRetainedThreads: 1);
    final a = query(['thread', 'a', 'work-requests']);
    final overlay = engine.optimisticUpdate(a, (_) => 2);
    final b = query(['thread', 'b', 'discussion']);
    final release = engine.watch(b, (_) {});
    await settle();
    expect(overlay.isCurrent(), isTrue);
    overlay.commit((_) => 3);
    await settle();
    expect(engine.relevantKeys.single, b.key);
    release();
  });

  test('inactive Discussion compacts while cached messages stay visible',
      () async {
    final engine = AxSyncEngine(maxRetainedHistoryItems: 3);
    final chat = AxDiscussionCache(null, engine: engine);
    final release = chat.watch('a', (_) {});
    engine.update(
        chat.query('a'),
        (_) => AxDiscussionHistory(
            messages: List.generate(10, (i) => message('$i', 'message')),
            initialLoaded: true,
            olderCursor: 'opaque'));
    await settle();
    expect(chat.peek('a').messages.length, 10);
    release();
    await settle();
    final state = chat.peek('a');
    expect(state.messages.map((m) => m.id), ['7', '8', '9']);
    expect(state.hasData, isTrue);
    expect(state.olderCursor, isNull);
    expect(engine.peek(chat.query('a')).isStale, isTrue);
  });

  test('Work compaction removes immutable page cache and rebuilds frontier',
      () async {
    final engine = AxSyncEngine(maxRetainedHistoryItems: 3);
    final work = AxWorkHistoryCache(null, engine: engine);
    work.replace('a', List.generate(10, (i) => request('$i')));
    await settle();
    final history = work.peek('a');
    expect(history.requests.map((r) => r.id), ['7', '8', '9']);
    expect(history.olderCursor?.id, '7');
  });

  test('pending Chat send survives navigation and is not replayed', () async {
    final engine = AxSyncEngine(maxRetainedThreads: 1);
    final source = DiscussionSource();
    final chat = AxDiscussionCache(source, engine: engine);
    final write = chat.send('a', 'pending');
    final release = chat.watch('b', (_) {});
    await settle();
    expect(chat.peek('a').messages.single.body, 'pending');
    expect(source.sends.length, 1);
    source.sends.single.complete(message('saved', 'pending', ws: 'a'));
    await write;
    await settle();
    await settle();
    expect(source.sends.length, 1);
    expect(engine.relevantKeys.where((key) => key.parts[1] == 'a'), isEmpty);
    release();
  });

  test('hydrated unvisited histories are bounded without cache owners',
      () async {
    final engine = AxSyncEngine(maxRetainedThreads: 2);
    for (var i = 0; i < 30; i++) {
      engine.seed(query(['thread', '$i', 'discussion']), i,
          accessed: DateTime.utc(2026).add(Duration(seconds: i)));
    }
    await settle();
    expect(engine.cachedValues<int>().values, unorderedEquals([28, 29]));
  });

  test('eviction releases Work bridge context and every cached page', () async {
    final engine = AxSyncEngine(maxRetainedThreads: 1);
    final work = AxWorkHistoryCache(null, engine: engine);
    final releaseA = work.watch('a', () {});
    work.replace('a', [request('1')]);
    for (var i = 0; i < 10; i++) {
      engine.update(
          query(['thread', 'a', 'work-requests', 'page', '$i']), (_) => i);
    }
    final releaseB = work.watch('b', () {});
    releaseA();
    await settle();
    expect(work.threadIds, ['b']);
    expect(engine.relevantKeys.every((key) => key.parts[1] == 'b'), isTrue);
    releaseB();
  });

  test('direct query subscription pins history even with a cache owner',
      () async {
    final engine = AxSyncEngine(maxRetainedThreads: 1);
    final chat = AxDiscussionCache(null, engine: engine);
    final release = engine.watch(chat.query('a'), (_) {});
    chat.peek('b');
    await settle();
    expect(engine.relevantKeys.single.parts[1], 'a');
    release();
  });

  test('Work compaction preserves a reconnect gap cursor', () async {
    final engine = AxSyncEngine(maxRetainedHistoryItems: 3);
    final work = AxWorkHistoryCache(null, engine: engine);
    const gapCursor =
        AxWorkRequestCursor(createdAt: '2026-10-06', id: 'missing');
    engine.update(
        work.query('a'),
        (_) => AxWorkHistory(
            requests: List.generate(10, (i) => request('$i')),
            initialLoaded: true,
            olderCursor: gapCursor,
            gaps: [AxWorkHistoryGap(request('8'), null)]));
    await settle();
    expect(work.peek('a').requests.length, 3);
    expect(work.peek('a').olderCursor, gapCursor);
  });

  test('idle Run queries expire, observed Run and session entities survive',
      () {
    var now = DateTime.utc(2026);
    final engine = AxSyncEngine(clock: () => now);
    final idle = query(['run', 'idle']);
    final active = query(['run', 'active']);
    final space = query(['space', 'a']);
    engine.update(idle, (_) => 1);
    engine.peek(idle);
    engine.update(active, (_) => 1);
    final release = engine.watch(active, (_) {});
    engine.update(space, (_) => 1);
    now = now.add(const Duration(minutes: 6));
    engine.collectRetainedCache();
    expect(engine.cachedValues<int>().keys,
        unorderedEquals([active.key, space.key]));
    release();
  });
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/sync/ax_query_builder.dart';
import 'package:conclave_app/src/ax/sync/ax_lifecycle_sync.dart';
import 'package:conclave_app/src/ax/sync/ax_discussion_cache.dart';

void main() {
  late DateTime now;
  late AxSyncEngine engine;
  late AxLifecycleSync lifecycle;
  late List<String?> notices;
  setUp(() {
    now = DateTime.utc(2026);
    engine = AxSyncEngine(clock: () => now);
    notices = [];
    lifecycle = AxLifecycleSync(engine, onNotice: notices.add);
  });
  AxQuery<int> query(String id, Future<int> Function() load) =>
      AxQuery(key: AxQueryKey(['space', id]), load: load);

  test(
      'foreground refreshes aged active queries, keeps fresh and inactive values',
      () async {
    var calls = 0;
    final old = query('old', () async => ++calls);
    final inactive = query('inactive', () async => ++calls);
    final fresh = query('fresh', () async => ++calls);
    await engine.ensure(old);
    await engine.ensure(inactive);
    engine.watch(old, (_) {});
    now = now.add(const Duration(minutes: 2));
    await engine.ensure(fresh);
    engine.watch(fresh, (_) {});
    await lifecycle.resume();
    expect(calls, 4);
    expect(engine.peek(inactive).data, 2);
    expect(engine.peek(fresh).data, 3);
    expect(notices.last, isNull);
  });

  test('five resume and network triggers share one read and retain cache',
      () async {
    final pending = Completer<int>();
    var calls = 0;
    final q = query('a', () {
      calls++;
      return pending.future;
    });
    engine.seed(q, 7);
    engine.watch(q, (_) {});
    final reads = List.generate(5, (_) => lifecycle.resume());
    reads.add(lifecycle.connectivityChanged(true));
    expect(engine.peek(q).data, 7);
    expect(calls, 1);
    pending.complete(8);
    await Future.wait(reads);
    expect(engine.peek(q).data, 8);
  });

  test('offline performs no reads and online refreshes stale active queries',
      () async {
    var calls = 0;
    final q = query('a', () async => ++calls);
    engine.seed(q, 7);
    engine.watch(q, (_) {});
    await lifecycle.connectivityChanged(false);
    await lifecycle.resume();
    expect(calls, 0);
    expect(engine.peek(q).data, 7);
    expect(notices.last, contains('Connection lost'));
    await lifecycle.connectivityChanged(true);
    expect(calls, 1);
    expect(notices.last, isNull);
  });

  test('failures retain cached data and a later restoration can recover',
      () async {
    var fail = true;
    final q = query('a', () async {
      if (fail) throw StateError('offline');
      return 8;
    });
    engine.seed(q, 7);
    engine.watch(q, (_) {});
    await lifecycle.resume();
    expect(engine.peek(q).data, 7);
    expect(engine.peek(q).error, isStateError);
    expect(notices.last, contains('Showing cached data'));
    fail = false;
    await lifecycle.connectivityChanged(true);
    expect(engine.peek(q).data, 8);
    expect(notices.last, isNull);
  });

  test('restoration retries a read which fails after the online event',
      () async {
    final pending = Completer<int>();
    var calls = 0;
    final q = query('a', () => ++calls == 1 ? pending.future : Future.value(9));
    engine.seed(q, 7);
    engine.watch(q, (_) {});
    final first = lifecycle.resume();
    await lifecycle.connectivityChanged(false);
    final restored = lifecycle.connectivityChanged(true);
    pending.completeError(StateError('old offline request'));
    await first;
    await restored;
    expect(calls, 2);
    expect(engine.peek(q).data, 9);
    expect(notices.last, isNull);
  });

  test('logout cancels pending restoration without starting another read',
      () async {
    final pending = Completer<int>();
    var calls = 0;
    final q = query('a', () {
      calls++;
      return pending.future;
    });
    engine.seed(q, 7);
    engine.watch(q, (_) {});
    final first = lifecycle.resume();
    await lifecycle.connectivityChanged(false);
    final restored = lifecycle.connectivityChanged(true);
    lifecycle.reset();
    engine.clear();
    pending.completeError(StateError('old response'));
    await first;
    await restored;
    expect(calls, 1);
    expect(notices.last, isNull);
  });

  test('internal history bridges and immutable pages are not active queries',
      () async {
    final chat = AxDiscussionCache(null, engine: engine);
    chat.peek('inactive');
    final page = AxQuery<int>(
        key: AxQueryKey(['thread', 'active', 'work-requests', 'page', '1']),
        load: () async => throw StateError('must not load page'));
    engine.seed(page, 1);
    engine.watch(page, (_) {});
    await lifecycle.resume();
    expect(engine.peek(chat.query('inactive')).hasData, isFalse);
    expect(engine.peek(page).data, 1);
    expect(engine.peek(page).error, isNull);
  });

  test('visible Chat cache subscriptions revalidate their stale head',
      () async {
    final chat = AxDiscussionCache(null, engine: engine);
    final release = chat.watch('active', (_) {});
    await lifecycle.resume();
    expect(chat.peek('active').hasData, isTrue);
    release();
  });

  test('logout/reset and disposal fence old status completions', () async {
    final pending = Completer<int>();
    final q = query('a', () => pending.future);
    engine.seed(q, 7);
    engine.watch(q, (_) {});
    final read = lifecycle.resume();
    lifecycle.reset();
    engine.clear();
    lifecycle.dispose();
    final count = notices.length;
    pending.complete(8);
    await read;
    expect(notices.length, count);
    expect(engine.cachedValues<int>(), isEmpty);
  });

  testWidgets('cached UI stays visible during resume and read failure',
      (tester) async {
    final pending = Completer<int>();
    final q = query('a', () => pending.future);
    engine.seed(q, 7);
    await tester.pumpWidget(MaterialApp(
        home: AxQueryBuilder<int>(
            engine: engine,
            query: q,
            ensure: false,
            builder: (_, state) => Text('cached ${state.data}'))));
    final read = lifecycle.resume();
    await tester.pump();
    expect(find.text('cached 7'), findsOneWidget);
    pending.completeError(StateError('temporary failure'));
    await read;
    await tester.pump();
    expect(find.text('cached 7'), findsOneWidget);
    expect(notices.last, contains('Showing cached data'));
  });
}

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';

void main() {
  test(
      'mutation runs optimisticUpdate, execute, commit, invalidate once in order',
      () async {
    final runner = AxMutationRunner();
    final calls = <String>[];
    final response = Completer<int>();
    var value = 1;
    final result = runner.run(AxMutationOperation<int, int>(
      optimisticUpdate: () {
        calls.add('optimisticUpdate');
        final old = value;
        value = 2;
        return old;
      },
      execute: (_) {
        calls.add('execute');
        return response.future;
      },
      commit: (saved, _) {
        calls.add('commit');
        value = saved;
      },
      rollback: (_, __, old) {
        calls.add('rollback');
        value = old;
      },
      invalidate: (_, __) async {
        calls.add('invalidate');
      },
      isCurrent: (_) => true,
    ));
    expect(value, 2);
    expect(calls, ['optimisticUpdate', 'execute']);
    response.complete(3);
    expect(await result, 3);
    expect(value, 3);
    expect(calls, ['optimisticUpdate', 'execute', 'commit', 'invalidate']);
  });

  test('execute failure rolls back once and never commits or invalidates',
      () async {
    final runner = AxMutationRunner();
    var executions = 0, rollbacks = 0, value = 1;
    await expectLater(
        runner.run(AxMutationOperation<int, int>(
          optimisticUpdate: () {
            value = 2;
            return 1;
          },
          execute: (_) async {
            executions++;
            throw StateError('offline');
          },
          commit: (_, __) => fail('commit after failure'),
          rollback: (_, __, previous) {
            rollbacks++;
            value = previous;
          },
          invalidate: (_, __) async => fail('invalidate after failure'),
          isCurrent: (_) => true,
        )),
        throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(value, 1);
    expect(executions, 1);
    expect(rollbacks, 1);
  });

  test(
      'reconciliation failure retains confirmed write and never replays execute',
      () async {
    var executions = 0, value = 0;
    final result = await AxMutationRunner().run(AxMutationOperation<int, int>(
      optimisticUpdate: () => 0,
      execute: (_) async {
        executions++;
        return 9;
      },
      commit: (saved, _) => value = saved,
      rollback: (_, __, ___) => fail('rollback confirmed write'),
      invalidate: (_, __) async => throw StateError('read offline'),
      isCurrent: (_) => true,
    ));
    expect(result, 9);
    expect(value, 9);
    expect(executions, 1);
  });

  test('commit failure cannot roll back or replay an accepted server operation',
      () async {
    var executions = 0;
    await expectLater(
        AxMutationRunner().run(AxMutationOperation<int, int>(
          optimisticUpdate: () => 0,
          execute: (_) async {
            executions++;
            return 9;
          },
          commit: (_, __) => throw StateError('invalid local commit'),
          rollback: (_, __, ___) => fail('rollback accepted write'),
          isCurrent: (_) => true,
        )),
        throwsStateError);
    expect(executions, 1);
  });

  test('throwing optimistic update never executes and releases its key',
      () async {
    final runner = AxMutationRunner();
    await expectLater(
        runner.run(AxMutationOperation<int, int>(
          key: 'key',
          optimisticUpdate: () => throw StateError('transform'),
          execute: (_) async => fail('executed'),
          commit: (_, __) {},
          rollback: (_, __, ___) {},
          isCurrent: (_) => true,
        )),
        throwsStateError);
    expect(runner.isRunning('key'), isFalse);
  });

  test('duplicate operation key rejects a second POST instead of queuing it',
      () async {
    final runner = AxMutationRunner();
    final response = Completer<int>();
    var calls = 0;
    AxMutationOperation<int, int> operation() => AxMutationOperation(
        key: 'expensive-work',
        optimisticUpdate: () => 0,
        execute: (_) {
          calls++;
          return response.future;
        },
        commit: (_, __) {},
        rollback: (_, __, ___) {},
        isCurrent: (_) => true);
    final first = runner.run(operation());
    await expectLater(runner.run(operation()), throwsStateError);
    expect(calls, 1);
    response.complete(1);
    await first;
    expect(runner.isRunning('expensive-work'), isFalse);
  });

  test(
      'session reset releases old keys without letting an old completion release a new lease',
      () async {
    final runner = AxMutationRunner();
    final old = Completer<int>(), latest = Completer<int>();
    var current = true;
    final first = runner.run(AxMutationOperation<int, int>(
        key: 'key',
        optimisticUpdate: () => 0,
        execute: (_) => old.future,
        commit: (_, __) => fail('old commit'),
        rollback: (_, __, ___) => fail('old rollback'),
        isCurrent: (_) => current));
    final firstCheck = expectLater(first, throwsA(isA<AxMutationSuperseded>()));
    current = false;
    runner.reset();
    final second = runner.run(AxMutationOperation<int, int>(
        key: 'key',
        optimisticUpdate: () => 0,
        execute: (_) => latest.future,
        commit: (_, __) {},
        rollback: (_, __, ___) {},
        isCurrent: (_) => true));
    old.complete(1);
    await firstCheck;
    expect(runner.isRunning('key'), isTrue);
    latest.complete(2);
    await second;
    expect(runner.isRunning('key'), isFalse);
  });

  test(
      'independent query overlays survive reads, rollback only their own changes, and fence old reads on commit',
      () async {
    final engine = AxSyncEngine();
    final read = Completer<List<String>>();
    final query = AxQuery<List<String>>(
        key: AxQueryKey(['items']), load: () => read.future);
    engine.update(query, (_) => ['base']);
    final first =
        engine.optimisticUpdate(query, (state) => [...state.data ?? [], 'A']);
    final second =
        engine.optimisticUpdate(query, (state) => [...state.data ?? [], 'B']);
    expect(engine.peek(query).data, ['base', 'A', 'B']);
    final flight = engine.refresh(query);
    engine.update(query, (_) => ['realtime'], fenceReads: false);
    expect(engine.peek(query).data, ['realtime', 'A', 'B']);
    first.rollback();
    expect(engine.peek(query).data, ['realtime', 'B']);
    second.commit((state) => [...state.data ?? [], 'server-B']);
    read.complete(['old']);
    await flight;
    expect(engine.peek(query).data, ['realtime', 'server-B']);
    expect(engine.cachedValues<List<String>>()[query.key],
        ['realtime', 'server-B']);
  });

  test(
      'remove/clear fence optimistic handles even when active subscriptions retain the entry',
      () {
    final engine = AxSyncEngine();
    final query =
        AxQuery<int>(key: AxQueryKey(['entity']), load: () async => 1);
    final cancel = engine.watch(query, (_) {});
    final overlay = engine.optimisticUpdate(query, (_) => 2);
    engine.clear();
    expect(overlay.isCurrent(), isFalse);
    overlay.commit((_) => fail('late commit'));
    overlay.rollback();
    expect(engine.peek(query).hasData, isFalse);
    cancel();
  });

  test('invalidated overlays remain visible throughout a failed read',
      () async {
    final engine = AxSyncEngine();
    final query = AxQuery<int>(
        key: AxQueryKey(['entity']),
        load: () async => throw StateError('offline'));
    engine.update(query, (_) => 1);
    final overlay = engine.optimisticUpdate(query, (_) => 2);
    engine.invalidate(query.key);
    await expectLater(engine.refresh(query), throwsStateError);
    expect(engine.peek(query).data, 2);
    expect(engine.peek(query).error, isStateError);
    overlay.rollback();
    expect(engine.peek(query).data, 1);
  });
}

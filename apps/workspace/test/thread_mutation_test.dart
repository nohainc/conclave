import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/thread_directory.dart';
import 'package:conclave_workspace/thread_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ThreadMutationCoordinator coordinator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-mutation-');
    coordinator = ThreadMutationCoordinator(
      ThreadDirectoryLifecycle(
        pathResolver: ThreadPathResolver(root),
      ),
    );
  });

  tearDown(() => root.delete(recursive: true));

  test('serializes two mutators of one Thread', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final events = <String>[];

    final first = coordinator.withMutation(
      spaceId: 'space-1',
      threadId: 'thread-1',
      leaseId: 'lease-1',
      fencingToken: 1,
      action: (_) async {
        events.add('first-start');
        entered.complete();
        await release.future;
        events.add('first-end');
      },
    );
    await entered.future;

    var secondFinished = false;
    final second = coordinator.withMutation(
      spaceId: 'space-1',
      threadId: 'thread-1',
      leaseId: 'lease-2',
      fencingToken: 2,
      action: (_) async {
        events.add('second-start');
        secondFinished = true;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(secondFinished, isFalse);

    release.complete();
    await Future.wait([first, second]);
    expect(events, ['first-start', 'first-end', 'second-start']);
  });

  test('allows different Threads to run concurrently', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var otherStarted = false;

    final first = coordinator.withMutation(
      spaceId: 'space-1',
      threadId: 'thread-1',
      leaseId: 'lease-1',
      fencingToken: 1,
      action: (_) async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;

    final other = coordinator.withMutation(
      spaceId: 'space-1',
      threadId: 'thread-2',
      leaseId: 'lease-other',
      fencingToken: 1,
      action: (_) async {
        otherStarted = true;
      },
    );
    await other;
    expect(otherStarted, isTrue);

    release.complete();
    await first;
  });

  test('rejects stale fencing tokens after restart/reconnect', () async {
    await coordinator.withMutation(
      spaceId: 'space-1',
      threadId: 'thread-1',
      leaseId: 'lease-new',
      fencingToken: 2,
      action: (_) async {},
    );

    await expectLater(
      coordinator.withMutation(
        spaceId: 'space-1',
        threadId: 'thread-1',
        leaseId: 'lease-stale',
        fencingToken: 1,
        action: (_) async {},
      ),
      throwsA(isA<ThreadMutationViolation>()),
    );
  });
}

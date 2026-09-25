import 'dart:async';
import 'dart:io';

import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late WorkstreamMutationCoordinator coordinator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-mutation-');
    coordinator = WorkstreamMutationCoordinator(
      WorkstreamDirectoryLifecycle(
        pathResolver: WorkstreamPathResolver(root),
      ),
    );
  });

  tearDown(() => root.delete(recursive: true));

  test('serializes two mutators of one Workstream', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final events = <String>[];

    final first = coordinator.withMutation(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
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
      projectId: 'project-1',
      workstreamId: 'workstream-1',
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

  test('allows different Workstreams to run concurrently', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var otherStarted = false;

    final first = coordinator.withMutation(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      leaseId: 'lease-1',
      fencingToken: 1,
      action: (_) async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;

    final other = coordinator.withMutation(
      projectId: 'project-1',
      workstreamId: 'workstream-2',
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
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      leaseId: 'lease-new',
      fencingToken: 2,
      action: (_) async {},
    );

    await expectLater(
      coordinator.withMutation(
        projectId: 'project-1',
        workstreamId: 'workstream-1',
        leaseId: 'lease-stale',
        fencingToken: 1,
        action: (_) async {},
      ),
      throwsA(isA<WorkstreamMutationViolation>()),
    );
  });
}

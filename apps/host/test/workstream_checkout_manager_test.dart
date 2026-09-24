import 'dart:io';

import 'package:test/test.dart';
import 'package:conclave_host/runtime_capabilities.dart';

Future<Directory> createRepository() async {
  final directory = await Directory.systemTemp.createTemp('conclave-checkout-');

  Future<void> git(List<String> arguments) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      throw StateError('${result.stdout}\n${result.stderr}');
    }
  }

  await git(['init', '-q']);
  await git(['config', 'user.email', 'checkout-test@example.com']);
  await git(['config', 'user.name', 'Checkout Test']);
  await File('${directory.path}/README.md').writeAsString('initial\n');
  await git(['add', 'README.md']);
  await git(['commit', '-qm', 'initial']);
  return directory;
}

void main() {
  test('provisions idempotently and resolves after manager reopen', () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final firstManager = WorkstreamCheckoutManager(repository);

    final first = await firstManager.provision(
      checkoutId: 'checkout-auth',
      workstreamId: 'workstream-auth',
    );
    final second = await firstManager.provision(
      checkoutId: 'checkout-auth',
      workstreamId: 'workstream-auth',
    );
    final reopened =
        await WorkstreamCheckoutManager(repository).resolve('checkout-auth');

    expect(second.relativePath, first.relativePath);
    expect(reopened.branch, first.branch);
    expect(reopened.workstreamId, 'workstream-auth');
  });

  test('isolates two Workstreams and rejects path-shaped checkout IDs',
      () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final manager = WorkstreamCheckoutManager(repository);

    final one = await manager.provision(
      checkoutId: 'checkout-one',
      workstreamId: 'workstream-one',
    );
    final two = await manager.provision(
      checkoutId: 'checkout-two',
      workstreamId: 'workstream-two',
    );

    expect(one.relativePath, isNot(two.relativePath));
    expect(one.branch, isNot(two.branch));
    expect(
        () => manager.provision(
              checkoutId: '../outside',
              workstreamId: 'workstream-three',
            ),
        throwsA(isA<RuntimeViolation>()));
    expect(
      () => manager.provision(
        checkoutId: 'checkout-bad-base',
        workstreamId: 'workstream-three',
        revision: 'missing-base-revision',
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('rejects a managed-root symlink escape', () async {
    final repository = await createRepository();
    final outside = await Directory.systemTemp.createTemp('conclave-outside-');
    addTearDown(() async {
      await repository.delete(recursive: true);
      await outside.delete(recursive: true);
    });
    await Link('${repository.path}/.conclave').create(outside.path);

    expect(
      () => WorkstreamCheckoutManager(repository).provision(
        checkoutId: 'checkout-safe',
        workstreamId: 'workstream-safe',
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('reports dirty state, recovers it, and creates a checkpoint commit',
      () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final manager = WorkstreamCheckoutManager(repository);
    final checkout = await manager.provision(
      checkoutId: 'checkout-recover',
      workstreamId: 'workstream-recover',
    );
    final checkoutDirectory = Directory(
      '${repository.path}${Platform.pathSeparator}${checkout.relativePath}',
    );
    final readme = File('${checkoutDirectory.path}/README.md');
    await readme.writeAsString('dirty\n');

    expect((await manager.status(checkout.id)).dirty, isTrue);
    await manager.resetAndRecover(checkout.id);
    expect((await manager.status(checkout.id)).dirty, isFalse);

    await readme.writeAsString('checkpoint\n');
    final revision = await manager.checkpointCommit(
      checkout.id,
      'checkpoint: recoverable state',
    );
    expect(revision, isNotEmpty);
    expect((await manager.status(checkout.id)).dirty, isFalse);
  });

  test('archives and removes an opaque checkout', () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final manager = WorkstreamCheckoutManager(repository);
    final checkout = await manager.provision(
      checkoutId: 'checkout-archive',
      workstreamId: 'workstream-archive',
    );

    await manager.archive(checkout.id);
    expect(
      () => manager.resolve(checkout.id),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => manager.remove(checkout.id),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('fences stale and duplicate stateful assignments', () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final manager = WorkstreamCheckoutManager(repository);
    final checkout = await manager.provision(
      checkoutId: 'checkout-fence',
      workstreamId: 'workstream-fence',
    );
    final revision = (await manager.status(checkout.id)).currentRevision;
    final snapshot = <String, Object?>{
      'executionClass': 'stateful_workstream',
      'workstreamId': checkout.workstreamId,
      'checkoutId': checkout.id,
      'leaseId': 'lease-1',
      'fencingToken': 3,
      'expectedRevision': revision,
    };

    await manager.withStatefulLease(snapshot: snapshot, action: (_) async {});
    expect(
      () => manager.withStatefulLease(
        snapshot: {...snapshot, 'leaseId': 'lease-old', 'fencingToken': 2},
        action: (_) async {},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => manager.withStatefulLease(
        snapshot: {...snapshot, 'leaseId': 'lease-other'},
        action: (_) async {},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => manager.withStatefulLease(
        snapshot: {...snapshot, 'expectedRevision': 'wrong-revision'},
        action: (_) async {},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => manager.withStatefulLease(
        snapshot: {...snapshot, 'checkoutId': 'checkout-forged'},
        action: (_) async {},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => manager.withStatefulLease(
        snapshot: {...snapshot, 'workstreamId': 'different-workstream'},
        action: (_) async {},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('reopens safely after a runtime interruption and quarantines failed rollback',
      () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final manager = WorkstreamCheckoutManager(repository);
    final checkout = await manager.provision(
      checkoutId: 'checkout-restart',
      workstreamId: 'workstream-restart',
    );
    final reopened = WorkstreamCheckoutManager(repository);
    expect((await reopened.resolve(checkout.id)).workstreamId,
        checkout.workstreamId);
    final recovery = await reopened.finalizeStatefulLease(
      checkoutId: checkout.id,
      baseRevision: 'missing-revision-after-crash',
      outcome: 'failure',
    );
    expect(recovery.recoveryStatus, 'quarantined');
  });

  test('serializes stateful mutations with the checkout file lock', () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final manager = WorkstreamCheckoutManager(repository);
    final checkout = await manager.provision(
      checkoutId: 'checkout-lock',
      workstreamId: 'workstream-lock',
    );
    final revision = (await manager.status(checkout.id)).currentRevision;
    var active = 0;
    var maximum = 0;

    Future<void> run(String leaseId, int token) async {
      await manager.withStatefulLease(
        snapshot: {
          'executionClass': 'stateful_workstream',
          'workstreamId': checkout.workstreamId,
          'checkoutId': checkout.id,
          'leaseId': leaseId,
          'fencingToken': token,
          'expectedRevision': revision,
        },
        action: (_) async {
          active++;
          maximum = active > maximum ? active : maximum;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          active--;
        },
      );
    }

    await Future.wait([run('lease-a', 1), run('lease-b', 2)]);
    expect(maximum, 1);
  });

  test(
      'commits changed state, records no-change success, and rolls back failures',
      () async {
    final repository = await createRepository();
    addTearDown(() => repository.delete(recursive: true));
    final manager = WorkstreamCheckoutManager(repository);
    final checkout = await manager.provision(
      checkoutId: 'checkout-lifecycle',
      workstreamId: 'workstream-lifecycle',
    );
    final baseRevision = (await manager.status(checkout.id)).currentRevision;
    final checkoutDirectory = Directory(
      '${repository.path}${Platform.pathSeparator}${checkout.relativePath}',
    );
    final readme = File('${checkoutDirectory.path}/README.md');

    final unchanged = await manager.finalizeStatefulLease(
      checkoutId: checkout.id,
      baseRevision: baseRevision,
      outcome: 'success',
    );
    expect(unchanged.changed, isFalse);
    expect(unchanged.revision, baseRevision);

    await readme.writeAsString('dependency change\n');
    await File('${checkoutDirectory.path}/generated.tmp')
        .writeAsString('generated\n');
    final committed = await manager.finalizeStatefulLease(
      checkoutId: checkout.id,
      baseRevision: baseRevision,
      outcome: 'success',
      message: 'checkpoint: dependency change',
    );
    expect(committed.changed, isTrue);
    expect(committed.revision, isNot(baseRevision));

    await readme.writeAsString('failed mutation\n');
    final rolledBack = await manager.finalizeStatefulLease(
      checkoutId: checkout.id,
      baseRevision: committed.revision,
      outcome: 'failure',
    );
    expect(rolledBack.recoveryStatus, 'rolled_back');
    expect((await manager.status(checkout.id)).dirty, isFalse);

    await readme.writeAsString('rollback cannot resolve\n');
    final quarantine = await manager.finalizeStatefulLease(
      checkoutId: checkout.id,
      baseRevision: 'missing-base-revision',
      outcome: 'cancelled',
    );
    expect(quarantine.recoveryStatus, 'quarantined');
  });
}

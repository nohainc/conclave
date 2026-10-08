import 'dart:io';

import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/runtime_capabilities.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/thread_cleanup.dart';
import 'package:conclave_workspace/thread_directory.dart';
import 'package:conclave_workspace/thread_marker.dart';
import 'package:conclave_workspace/thread_path.dart';
import 'package:test/test.dart';
import 'support/assignment_worker_fixture.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-security-');
  });

  tearDown(() => root.delete(recursive: true));

  test('rejects traversal, separators, and Unicode IDs', () async {
    final resolver = ThreadPathResolver(root);
    for (final spaceId in ['..', '../outside', r'space\outside', '项目']) {
      await expectLater(
        resolver.resolve(spaceId: spaceId, threadId: 'thread-1'),
        throwsA(isA<ThreadPathViolation>()),
      );
    }
    await expectLater(
      resolver.resolve(spaceId: 'space-1', threadId: '../outside'),
      throwsA(isA<ThreadPathViolation>()),
    );
    await expectLater(
      resolver.resolve(spaceId: 'space-1', threadId: r'work\outside'),
      throwsA(isA<ThreadPathViolation>()),
    );
  });

  test('rejects a Work Root symlink that escapes its canonical root', () async {
    final outside =
        await Directory.systemTemp.createTemp('conclave-security-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await Link('${root.path}${Platform.pathSeparator}space-1')
        .create(outside.path);

    await expectLater(
      ThreadPathResolver(root).resolve(
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadPathViolation>()),
    );
  });

  test('does not reuse mismatched, missing, or corrupt markers', () async {
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}space-1${Platform.pathSeparator}thread-1',
    );
    await directory.create(recursive: true);
    final store = const ThreadMarkerStore();

    await expectLater(
      store.reuse(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
    await File(
      '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}',
    ).writeAsString('{bad-json');
    await expectLater(
      store.reuse(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );

    await File(
      '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}',
    ).writeAsString('''
{"schemaVersion":1,"spaceId":"space-2","threadId":"thread-1","createdAt":"2026-01-01T00:00:00.000Z"}
''');
    await expectLater(
      store.reuse(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
  });

  test('rejects an arbitrary Cloud-provided CWD', () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
      threadDirectoryLifecycle: ThreadDirectoryLifecycle(
        pathResolver: ThreadPathResolver(root),
      ),
    );
    await expectLater(
      handler.prepareAssignmentScope(const WorkspaceAssignmentContext(
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'runtime-1',
        workerId: 'worker',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-1',
        idempotencyKey: 'idem-1',
        payload: {
          'workerId': 'worker',
          'workerTypeId': 'test-worker',
          'spaceId': 'space-1',
          'threadId': 'thread-1',
          'executionClass': 'stateful_thread',
          'cwd': '/outside/thread',
          'workingDirectory': '/outside/thread',
        },
      )),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test(
      'keeps path and marker stable across rename and Workspace identity change',
      () async {
    final lifecycle = ThreadDirectoryLifecycle(
      pathResolver: ThreadPathResolver(root),
    );
    final before = await lifecycle.ensureForExecution(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final markerBefore = await const ThreadMarkerStore().reuse(
      threadDirectory: before,
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final renamed = await ThreadPathResolver(root).resolve(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final reRegistered = await ThreadPathResolver(root).resolve(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final markerAfter = await const ThreadMarkerStore().reuse(
      threadDirectory: reRegistered,
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    expect(renamed.path, before.path);
    expect(reRegistered.path, before.path);
    expect(markerAfter.toJson(), markerBefore.toJson());
  });

  test('rejects stale concurrent mutation replay', () async {
    final coordinator = ThreadMutationCoordinator(
      ThreadDirectoryLifecycle(
        pathResolver: ThreadPathResolver(root),
      ),
    );
    await coordinator.withMutation(
      spaceId: 'space-1',
      threadId: 'thread-1',
      leaseId: 'lease-current',
      fencingToken: 2,
      action: (_) async {},
    );
    await expectLater(
      coordinator.withMutation(
        spaceId: 'space-1',
        threadId: 'thread-1',
        leaseId: 'lease-replayed',
        fencingToken: 1,
        action: (_) async {},
      ),
      throwsA(isA<ThreadMutationViolation>()),
    );
  });

  test('refuses cleanup while an assignment is active', () async {
    final directory = await ThreadDirectoryLifecycle(
      pathResolver: ThreadPathResolver(root),
    ).ensureForExecution(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final cleanup = ThreadCleanupService(
      workRoot: root,
      hasActiveAssignment: (_) async => true,
    );
    final candidate = (await cleanup.scan()).candidates.single;
    await expectLater(
      cleanup.delete(candidate, confirmation: candidate.confirmationText),
      throwsA(isA<ThreadCleanupViolation>()),
    );
    expect(await directory.exists(), isTrue);
  });
}

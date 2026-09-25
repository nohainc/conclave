import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/runtime_capabilities.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/workstream_cleanup.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_marker.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-security-');
  });

  tearDown(() => root.delete(recursive: true));

  test('rejects traversal, separators, and Unicode IDs', () async {
    final resolver = WorkstreamPathResolver(root);
    for (final projectId in ['..', '../outside', r'project\outside', '项目']) {
      await expectLater(
        resolver.resolve(projectId: projectId, workstreamId: 'workstream-1'),
        throwsA(isA<WorkstreamPathViolation>()),
      );
    }
    await expectLater(
      resolver.resolve(projectId: 'project-1', workstreamId: '../outside'),
      throwsA(isA<WorkstreamPathViolation>()),
    );
    await expectLater(
      resolver.resolve(projectId: 'project-1', workstreamId: r'work\outside'),
      throwsA(isA<WorkstreamPathViolation>()),
    );
  });

  test('rejects a Work Root symlink that escapes its canonical root', () async {
    final outside =
        await Directory.systemTemp.createTemp('conclave-security-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await Link('${root.path}${Platform.pathSeparator}project-1')
        .create(outside.path);

    await expectLater(
      WorkstreamPathResolver(root).resolve(
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamPathViolation>()),
    );
  });

  test('does not reuse mismatched, missing, or corrupt markers', () async {
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}project-1${Platform.pathSeparator}workstream-1',
    );
    await directory.create(recursive: true);
    final store = const WorkstreamMarkerStore();

    await expectLater(
      store.reuse(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
    await File(
      '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}',
    ).writeAsString('{bad-json');
    await expectLater(
      store.reuse(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );

    await File(
      '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}',
    ).writeAsString('''
{"schemaVersion":1,"projectId":"project-2","workstreamId":"workstream-1","createdAt":"2026-01-01T00:00:00.000Z"}
''');
    await expectLater(
      store.reuse(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });

  test('rejects an arbitrary Cloud-provided CWD', () async {
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => const WorkerProcessSpec(
        workerId: 'worker',
        executable: 'worker',
      ),
      workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
        pathResolver: WorkstreamPathResolver(root),
      ),
    );
    await expectLater(
      handler.prepareProcessSpec(const HostAssignmentContext(
        workspaceId: 'workspace-1',
        hostId: 'runtime-1',
        workerId: 'worker',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-1',
        idempotencyKey: 'idem-1',
        payload: {
          'workerId': 'worker',
          'projectId': 'project-1',
          'workstreamId': 'workstream-1',
          'executionClass': 'stateful_workstream',
          'cwd': '/outside/workstream',
          'workingDirectory': '/outside/workstream',
        },
      )),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test(
      'keeps path and marker stable across rename and Workspace identity change',
      () async {
    final lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
    final before = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final markerBefore = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: before,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final renamed = await WorkstreamPathResolver(root).resolve(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final rePaired = await WorkstreamPathResolver(root).resolve(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final markerAfter = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: rePaired,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(renamed.path, before.path);
    expect(rePaired.path, before.path);
    expect(markerAfter.toJson(), markerBefore.toJson());
  });

  test('rejects stale concurrent mutation replay', () async {
    final coordinator = WorkstreamMutationCoordinator(
      WorkstreamDirectoryLifecycle(
        pathResolver: WorkstreamPathResolver(root),
      ),
    );
    await coordinator.withMutation(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      leaseId: 'lease-current',
      fencingToken: 2,
      action: (_) async {},
    );
    await expectLater(
      coordinator.withMutation(
        projectId: 'project-1',
        workstreamId: 'workstream-1',
        leaseId: 'lease-replayed',
        fencingToken: 1,
        action: (_) async {},
      ),
      throwsA(isA<WorkstreamMutationViolation>()),
    );
  });

  test('refuses cleanup while an assignment is active', () async {
    final directory = await WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    ).ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final cleanup = WorkstreamCleanupService(
      workRoot: root,
      hasActiveAssignment: (_) async => true,
    );
    final candidate = (await cleanup.scan()).candidates.single;
    await expectLater(
      cleanup.delete(candidate, confirmation: candidate.confirmationText),
      throwsA(isA<WorkstreamCleanupViolation>()),
    );
    expect(await directory.exists(), isTrue);
  });
}

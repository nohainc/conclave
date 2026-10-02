import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_marker.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';
import 'support/assignment_worker_fixture.dart';

void main() {
  test('clean-room Workstream execution survives renames and re-enrollment',
      () async {
    // Empty local environment and a newly enrolled Workspace runtime.
    final workRoot =
        await Directory.systemTemp.createTemp('conclave-clean-room-work-');
    addTearDown(() => workRoot.delete(recursive: true));
    final firstWorkspaceId = 'workspace-first';
    final secondWorkspaceId = 'workspace-reenrolled';

    final remote = await _createBareRemote(workRoot);
    final workerScript =
        File('${workRoot.path}${Platform.pathSeparator}clean-room-worker.dart');
    await workerScript.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final remote = args[0];
  final phase = args[1];
  final checkout = Directory('conclave');
  if (!checkout.existsSync()) {
    final clone = await Process.run('git', ['clone', '-q', remote, 'conclave']);
    if (clone.exitCode != 0) exit(clone.exitCode);
  }
  File('conclave/\$phase.txt').writeAsStringSync(phase);
}
''');

    WorkstreamDirectoryLifecycle lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(workRoot),
    );
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
      workstreamDirectoryLifecycle: lifecycle,
    );

    final firstContext = _context(
      workspaceId: firstWorkspaceId,
      workerId: 'codex-personal',
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final firstScope = await handler.prepareAssignmentScope(firstContext);
    final firstDirectory = firstScope.workingDirectory;
    expect(firstDirectory.path,
        endsWith('project-1${Platform.pathSeparator}workstream-1'));
    expect(firstDirectory.path, isNot(contains('Original Project')));
    expect(firstDirectory.path, isNot(contains('Original Workstream')));
    expect(firstDirectory.path, isNot(contains(firstWorkspaceId)));

    final firstWorker = await Process.run(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [workerScript.path, remote.path, 'first-worker'],
      workingDirectory: firstDirectory.path,
    );
    expect(firstWorker.exitCode, 0,
        reason: '${firstWorker.stdout}\n${firstWorker.stderr}');
    final markerBeforeRename = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: firstDirectory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    // Cloud/UI renames are display-only and do not enter runtime path APIs.
    var projectName = 'Original Project';
    var workstreamName = 'Original Workstream';
    projectName = 'Renamed Project';
    workstreamName = 'Renamed Workstream';
    workstreamName = 'Renamed Again';
    expect(projectName, 'Renamed Project');
    expect(workstreamName, 'Renamed Again');

    final secondWorkerScope = await handler.prepareAssignmentScope(
      firstContext.copyWith(
        workerId: 'claude-review',
        payload: {
          ...firstContext.payload,
          'workerId': 'claude-review',
        },
      ),
    );
    expect(secondWorkerScope.workingDirectory.path, firstDirectory.path);
    final continuation = await Process.run(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [workerScript.path, remote.path, 'second-worker'],
      workingDirectory: secondWorkerScope.workingDirectory.path,
    );
    expect(continuation.exitCode, 0,
        reason: '${continuation.stdout}\n${continuation.stderr}');
    expect(
      await File(
              '${firstDirectory.path}${Platform.pathSeparator}conclave${Platform.pathSeparator}first-worker.txt')
          .readAsString(),
      'first-worker',
    );
    expect(
      await File(
              '${firstDirectory.path}${Platform.pathSeparator}conclave${Platform.pathSeparator}second-worker.txt')
          .readAsString(),
      'second-worker',
    );

    // A second Workstream in the same Project gets a distinct directory and
    // can clone/use the same repository in parallel.
    final secondWorkstreamScope = await handler.prepareAssignmentScope(
      _context(
        workspaceId: firstWorkspaceId,
        workerId: 'codex-company',
        projectId: 'project-1',
        workstreamId: 'workstream-2',
      ),
    );
    expect(secondWorkstreamScope.workingDirectory.path,
        isNot(firstDirectory.path));
    final parallel = await Process.run(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [workerScript.path, remote.path, 'parallel-worker'],
      workingDirectory: secondWorkstreamScope.workingDirectory.path,
    );
    expect(parallel.exitCode, 0,
        reason: '${parallel.stdout}\n${parallel.stderr}');
    expect(
      await File(
              '${secondWorkstreamScope.workingDirectory.path}${Platform.pathSeparator}conclave${Platform.pathSeparator}parallel-worker.txt')
          .readAsString(),
      'parallel-worker',
    );
    expect(
      await File(
              '${firstDirectory.path}${Platform.pathSeparator}conclave${Platform.pathSeparator}parallel-worker.txt')
          .exists(),
      isFalse,
    );

    // The local Work Root survives Workspace revoke/re-enrollment. A new
    // runtime identity resolves and reuses the same marker-backed directory.
    lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(workRoot),
    );
    final reenrolledHandler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
      workstreamDirectoryLifecycle: lifecycle,
    );
    final reenrolledScope = await reenrolledHandler.prepareAssignmentScope(
      _context(
        workspaceId: secondWorkspaceId,
        workerId: 'codex-personal',
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
    );
    expect(reenrolledScope.workingDirectory.path, firstDirectory.path);
    final reentry = await Process.run(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [workerScript.path, remote.path, 'reenrolled-worker'],
      workingDirectory: reenrolledScope.workingDirectory.path,
    );
    expect(reentry.exitCode, 0, reason: '${reentry.stdout}\n${reentry.stderr}');
    expect(
      await File(
              '${firstDirectory.path}${Platform.pathSeparator}conclave${Platform.pathSeparator}second-worker.txt')
          .exists(),
      isTrue,
    );
    final markerAfterReenrollment = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: firstDirectory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(markerAfterReenrollment.toJson(), markerBeforeRename.toJson());
    expect(
      await File(
              '${firstDirectory.path}${Platform.pathSeparator}conclave${Platform.pathSeparator}reenrolled-worker.txt')
          .readAsString(),
      'reenrolled-worker',
    );
  });
}

HostAssignmentContext _context({
  required String workspaceId,
  required String workerId,
  required String projectId,
  required String workstreamId,
}) =>
    HostAssignmentContext(
      workspaceId: workspaceId,
      hostId: 'runtime-$workspaceId',
      workerId: workerId,
      runId: 'run-$workstreamId',
      taskId: 'task-$workstreamId',
      attemptId: 'attempt-$workstreamId',
      assignmentId: 'assignment-$workstreamId',
      idempotencyKey: 'idempotency-$workstreamId',
      payload: {
        'workerId': workerId,
        'workerTypeId': 'test-worker',
        'projectId': projectId,
        'workstreamId': workstreamId,
        'workRequestId': 'request-$workstreamId',
        'executionClass': 'stateful_workstream',
      },
    );

Future<Directory> _createBareRemote(Directory root) async {
  final source = Directory('${root.path}${Platform.pathSeparator}source');
  await source.create();
  await _git(source, ['init', '-q']);
  await _git(source, ['config', 'user.email', 'test@example.com']);
  await _git(source, ['config', 'user.name', 'Conclave Test']);
  await File('${source.path}${Platform.pathSeparator}README.md')
      .writeAsString('clean-room\n');
  await _git(source, ['add', 'README.md']);
  await _git(source, ['commit', '-qm', 'initial']);
  final remote = Directory('${root.path}${Platform.pathSeparator}remote.git');
  await _git(root, ['clone', '--bare', '-q', source.path, remote.path]);
  return remote;
}

Future<void> _git(Directory directory, List<String> args) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: directory.path,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
}

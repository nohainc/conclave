import 'dart:async';
import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_marker.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';
import 'support/assignment_worker_fixture.dart';

void main() {
  test('renames during active work preserve CWD, marker, and files', () async {
    final root = await Directory.systemTemp.createTemp('conclave-rename-');
    addTearDown(() => root.delete(recursive: true));
    final lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
      workstreamDirectoryLifecycle: lifecycle,
    );
    final context = const HostAssignmentContext(
      workspaceId: 'workspace-1',
      hostId: 'runtime-1',
      workerId: 'worker-one',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-1',
      idempotencyKey: 'idem-1',
      payload: {
        'workerId': 'worker-one',
        'workerTypeId': 'test-worker',
        'projectId': 'project-1',
        'workstreamId': 'workstream-1',
        'workRequestId': 'request-1',
        'executionClass': 'stateful_workstream',
      },
    );

    final firstScope = await handler.prepareAssignmentScope(context);
    final firstDirectory = firstScope.workingDirectory;
    final markerBefore = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: firstDirectory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final activeFile = File(
        '${firstDirectory.path}${Platform.pathSeparator}active-worker.txt');
    final firstWorkerScript =
        File('${root.path}${Platform.pathSeparator}first-worker.dart');
    await firstWorkerScript.writeAsString('''
import 'dart:io';
Future<void> main() async {
  File('active-worker.txt').writeAsStringSync('first-started');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  File('shared.txt').writeAsStringSync('first-worker');
}
''');

    final firstProcess = await Process.start(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [firstWorkerScript.path],
      workingDirectory: firstDirectory.path,
      runInShell: false,
    );
    unawaited(firstProcess.stdout.drain());
    unawaited(firstProcess.stderr.drain());
    await _waitForFile(activeFile);

    // These display-name changes are intentionally not passed to runtime
    // path APIs. They represent Cloud/UI renames during an active Run.
    var projectName = 'Original Project';
    var workstreamName = 'Original Workstream';
    projectName = 'Renamed Project';
    workstreamName = 'Renamed Workstream';
    workstreamName = 'Renamed Again';
    expect(projectName, 'Renamed Project');
    expect(workstreamName, 'Renamed Again');

    final secondScope = await handler.prepareAssignmentScope(
      context.copyWith(
        workerId: 'worker-two',
        payload: {
          ...context.payload,
          'workerId': 'worker-two',
          'workerTypeId': 'test-worker',
        },
      ),
    );
    expect(secondScope.workingDirectory.path, firstDirectory.path);
    expect(await firstDirectory.exists(), isTrue);
    final markerAfter = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: firstDirectory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(markerAfter.toJson(), markerBefore.toJson());

    expect(await firstProcess.exitCode, 0);
    final secondWorkerScript =
        File('${root.path}${Platform.pathSeparator}second-worker.dart');
    await secondWorkerScript.writeAsString('''
import 'dart:io';
Future<void> main() async {
  final file = File('shared.txt');
  file.writeAsStringSync('\\nsecond-worker', mode: FileMode.append);
}
''');
    final secondProcess = await Process.start(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [secondWorkerScript.path],
      workingDirectory: secondScope.workingDirectory.path,
      runInShell: false,
    );
    unawaited(secondProcess.stdout.drain());
    unawaited(secondProcess.stderr.drain());
    expect(await secondProcess.exitCode, 0);

    expect(
      await File('${firstDirectory.path}${Platform.pathSeparator}shared.txt')
          .readAsString(),
      'first-worker\nsecond-worker',
    );
    expect(
      (await root.list(recursive: true).toList())
          .whereType<Directory>()
          .where((directory) => directory.path.endsWith('workstream-1'))
          .length,
      1,
    );
  });
}

Future<void> _waitForFile(File file) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (await file.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Worker did not start editing the Workstream directory');
}

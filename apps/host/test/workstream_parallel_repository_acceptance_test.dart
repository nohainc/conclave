import 'dart:async';
import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';

void main() {
  test('parallel same-repository Workstreams remain isolated', () async {
    final root = await Directory.systemTemp.createTemp('conclave-parallel-');
    addTearDown(() => root.delete(recursive: true));
    final lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (workerId) => WorkerProcessSpec(
        workerId: workerId,
        executable: 'dart',
      ),
      workstreamDirectoryLifecycle: lifecycle,
    );
    final baseContext = const HostAssignmentContext(
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
        'workRequestId': 'request-1',
        'executionClass': 'stateful_workstream',
      },
    );
    final contextA = baseContext.copyWith(
      payload: {
        ...baseContext.payload,
        'workstreamId': 'workstream-a',
      },
    );
    final contextB = baseContext.copyWith(
      payload: {
        ...baseContext.payload,
        'workstreamId': 'workstream-b',
      },
    );

    final specA = await handler.prepareProcessSpec(contextA);
    final specB = await handler.prepareProcessSpec(contextB);
    expect(specA.workingDirectory, isNot(specB.workingDirectory));
    expect(specA.workingDirectory, contains('project-1'));
    expect(specA.workingDirectory, endsWith('workstream-a'));
    expect(specB.workingDirectory, endsWith('workstream-b'));

    final repoA =
        Directory('${specA.workingDirectory}${Platform.pathSeparator}conclave');
    final repoB =
        Directory('${specB.workingDirectory}${Platform.pathSeparator}conclave');
    await repoA.create(recursive: true);
    await repoB.create(recursive: true);
    await _initializeRepository(repoA, 'feature-a');
    await _initializeRepository(repoB, 'feature-b');

    final remote = Directory('${root.path}${Platform.pathSeparator}remote.git');
    await _runGit(root, ['init', '--bare', '-q', remote.path]);
    await _runGit(repoA, ['remote', 'add', 'origin', remote.path]);
    await _runGit(repoB, ['remote', 'add', 'origin', remote.path]);

    final workerScript =
        File('${root.path}${Platform.pathSeparator}worker.dart');
    await workerScript.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final identity = args.single;
  File('conclave/worker.txt').writeAsStringSync(identity);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  File('conclave/finished.txt').writeAsStringSync(identity);
}
''');

    final processA = await Process.start(
      specA.executable,
      [workerScript.path, 'A'],
      workingDirectory: specA.workingDirectory,
      runInShell: false,
    );
    final processB = await Process.start(
      specB.executable,
      [workerScript.path, 'B'],
      workingDirectory: specB.workingDirectory,
      runInShell: false,
    );
    unawaited(processA.stdout.drain());
    unawaited(processA.stderr.drain());
    unawaited(processB.stdout.drain());
    unawaited(processB.stderr.drain());
    expect(await Future.wait([processA.exitCode, processB.exitCode]), [0, 0]);

    expect(
      await File('${repoA.path}${Platform.pathSeparator}worker.txt')
          .readAsString(),
      'A',
    );
    expect(
      await File('${repoB.path}${Platform.pathSeparator}worker.txt')
          .readAsString(),
      'B',
    );
    expect(
      await File('${repoA.path}${Platform.pathSeparator}finished.txt')
          .readAsString(),
      'A',
    );
    expect(
      await File('${repoB.path}${Platform.pathSeparator}finished.txt')
          .readAsString(),
      'B',
    );
    await _commitAndPush(repoA, 'feature-a');
    await _commitAndPush(repoB, 'feature-b');
    final refs = await _runGit(remote, ['show-ref']);
    expect(refs, contains('refs/heads/feature-a'));
    expect(refs, contains('refs/heads/feature-b'));
    expect(await _runGit(repoA, ['branch', '--show-current']), 'feature-a');
    expect(await _runGit(repoB, ['branch', '--show-current']), 'feature-b');

    // A normal assignment resolves only its own CWD. The other repository is
    // not an input and is not reachable through the runtime's path selection.
    expect(specA.workingDirectory, isNot(specB.workingDirectory));
  });
}

Future<void> _initializeRepository(Directory repository, String branch) async {
  await _runGit(repository, ['init', '-q']);
  await _runGit(repository, ['config', 'user.email', 'test@example.com']);
  await _runGit(repository, ['config', 'user.name', 'Conclave Test']);
  await File('${repository.path}${Platform.pathSeparator}README.md')
      .writeAsString('initial\n');
  await _runGit(repository, ['add', 'README.md']);
  await _runGit(repository, ['commit', '-qm', 'initial']);
  await _runGit(repository, ['checkout', '-qb', branch]);
}

Future<void> _commitAndPush(Directory repository, String branch) async {
  await _runGit(repository, ['add', '.']);
  await _runGit(repository, ['commit', '-qm', branch]);
  await _runGit(repository, ['push', '-u', 'origin', branch]);
}

Future<String> _runGit(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError('${result.stdout}\n${result.stderr}');
  }
  return result.stdout.toString().trim();
}

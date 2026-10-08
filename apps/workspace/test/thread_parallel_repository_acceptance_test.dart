import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/thread_directory.dart';
import 'package:conclave_workspace/thread_path.dart';
import 'package:test/test.dart';
import 'support/assignment_worker_fixture.dart';

void main() {
  test('parallel same-repository Threads remain isolated', () async {
    final root = await Directory.systemTemp.createTemp('conclave-parallel-');
    addTearDown(() => root.delete(recursive: true));
    final lifecycle = ThreadDirectoryLifecycle(
      pathResolver: ThreadPathResolver(root),
    );
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
      threadDirectoryLifecycle: lifecycle,
    );
    final baseContext = const WorkspaceAssignmentContext(
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
        'workRequestId': 'request-1',
        'executionClass': 'stateful_thread',
      },
    );
    final contextA = baseContext.copyWith(
      payload: {
        ...baseContext.payload,
        'threadId': 'thread-a',
      },
    );
    final contextB = baseContext.copyWith(
      payload: {
        ...baseContext.payload,
        'threadId': 'thread-b',
      },
    );

    final scopeA = await handler.prepareAssignmentScope(contextA);
    final scopeB = await handler.prepareAssignmentScope(contextB);
    expect(scopeA.workingDirectory.path, isNot(scopeB.workingDirectory.path));
    expect(scopeA.workingDirectory.path, contains('space-1'));
    expect(scopeA.workingDirectory.path, endsWith('thread-a'));
    expect(scopeB.workingDirectory.path, endsWith('thread-b'));

    final repoA = Directory(
        '${scopeA.workingDirectory.path}${Platform.pathSeparator}conclave');
    final repoB = Directory(
        '${scopeB.workingDirectory.path}${Platform.pathSeparator}conclave');
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
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [workerScript.path, 'A'],
      workingDirectory: scopeA.workingDirectory.path,
      runInShell: false,
    );
    final processB = await Process.start(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [workerScript.path, 'B'],
      workingDirectory: scopeB.workingDirectory.path,
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
    expect(scopeA.workingDirectory.path, isNot(scopeB.workingDirectory.path));
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
  await _runGit(repository, ['switch', '-c', branch]);
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

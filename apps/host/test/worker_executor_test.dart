import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/repository_registry.dart';
import 'package:test/test.dart';
import 'fixture_copy.dart';

Future<Directory> createSilentWorker() async {
  final directory = await Directory.systemTemp.createTemp('silent-worker-');
  await File('${directory.path}/silent.dart').writeAsString('''
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 5));
}
''');
  return directory;
}

void main() {
  test('does not inherit unrelated Host secrets into worker processes', () {
    final environment = safeWorkerEnvironment(
      {'WORKER_MODE': 'test'},
      allowedNames: {'WORKER_MODE'},
    );

    expect(environment['WORKER_MODE'], 'test');
    expect(
        environment.keys.where((key) => key.startsWith('CONCLAVE_')), isEmpty);
    expect(
        safeWorkerEnvironment({
          'WORKER_SECRET': 'must-not-leak-without-explicit-grant',
        })['WORKER_SECRET'],
        isNull);
    expect(
        safeWorkerEnvironment(
          {'WORKER_SECRET': 'allowed'},
          allowedNames: {'WORKER_SECRET'},
        )['WORKER_SECRET'],
        'allowed');
  });

  test('executes a real Worker Worker through JSON-RPC', () async {
    final repository = Directory.current.parent.parent;
    final workerDirectory = Directory(
      '${repository.path}/workers/echo',
    );
    final result = await WorkerProcessExecutor().execute(
      WorkerProcessSpec(
        workerId: 'conclave.echo',
        executable: 'dart',
        arguments: ['run', 'bin/echo_worker.dart'],
        workingDirectory: workerDirectory.path,
        secretValues: {'sensitive-token'},
      ),
      {
        'objective': 'inspect repository',
        'workerId': 'conclave.echo',
        'secret': 'sensitive-token',
      },
      timeout: const Duration(seconds: 5),
    );

    expect(result['status'], 'completed');
    expect(result['summary'], contains('echo worker'));
    expect((result['input'] as Map)['secret'], '[REDACTED]');
  });

  test('resolves a worker into an Host assignment result', () async {
    final repository = Directory.current.parent.parent;
    final workerDirectory = Directory(
      '${repository.path}/workers/echo',
    );
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => WorkerProcessSpec(
        workerId: 'conclave.echo',
        executable: 'dart',
        arguments: ['run', 'bin/echo_worker.dart'],
        workingDirectory: workerDirectory.path,
      ),
    );
    final result = await handler.call(const HostAssignmentContext(
      workspaceId: 'workspace-1',
      hostId: 'host-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-1',
      idempotencyKey: 'idem-1',
      payload: {'workerId': 'conclave.echo'},
    ));
    expect(result.summary, contains('echo worker'));
    expect((result.output?['input'] as Map)['conclave']['assignmentId'],
        'assignment-1');
  });

  test('rejects assignment permissions not declared by the installed Worker',
      () async {
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => const WorkerProcessSpec(
        workerId: 'conclave.echo',
        executable: 'missing-worker',
      ),
      resolvePermissions: (_) async => {'workspace:read'},
    );
    await expectLater(
      handler.call(const HostAssignmentContext(
        workspaceId: 'workspace-1',
        hostId: 'host-1',
        workerId: 'worker-1',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-permission-denied',
        idempotencyKey: 'idem-permission-denied',
        payload: {
          'workerId': 'conclave.echo',
          'permissions': ['shell:execute'],
        },
      )),
      throwsA(predicate((error) =>
          error.toString().contains('assignment permission is not allowed'))),
    );
  });

  test('resolves repository IDs through the local registry', () async {
    final repository = await Directory.systemTemp.createTemp('repo-registry-');
    final registryFile = File('${repository.path}/repositories.json')
      ..writeAsStringSync(jsonEncode({'repo-1': repository.path}));
    final registry = await LocalRepositoryRegistry.load(registryFile);
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => WorkerProcessSpec(
        workerId: 'conclave.echo',
        executable: 'dart',
        arguments: ['run', 'bin/echo_worker.dart'],
        workingDirectory:
            '${Directory.current.parent.parent.path}/workers/echo',
      ),
      resolveRepositoryPath: registry.resolve,
    );
    final result = await handler.call(const HostAssignmentContext(
      workspaceId: 'workspace-1',
      hostId: 'host-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-repo-1',
      idempotencyKey: 'idem-repo-1',
      payload: {
        'workerId': 'conclave.echo',
        'repositoryId': 'repo-1',
        'input': <String, Object?>{},
      },
    ));
    expect((result.output?['input'] as Map)['repositoryPath'],
        await repository.resolveSymbolicLinks());
    await repository.delete(recursive: true);
  });

  test('terminates a worker that does not answer before the timeout', () async {
    final directory = await createSilentWorker();
    try {
      await expectLater(
        WorkerProcessExecutor().execute(
          WorkerProcessSpec(
            workerId: 'silent',
            executable: 'dart',
            arguments: ['run', '${directory.path}/silent.dart'],
          ),
          {},
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('cancels an active worker process by operation ID', () async {
    final directory = await createSilentWorker();
    final executor = WorkerProcessExecutor();
    try {
      final execution = executor.execute(
        WorkerProcessSpec(
          workerId: 'silent',
          executable: 'dart',
          arguments: ['run', '${directory.path}/silent.dart'],
        ),
        {},
        operationId: 'assignment-cancel-1',
        timeout: const Duration(seconds: 10),
      );
      final cancellationExpectation =
          expectLater(execution, throwsA(isA<ProcessException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await executor.cancel('assignment-cancel-1'), isTrue);
      await cancellationExpectation;
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('executes the Forge worker against the real fixture repository',
      () async {
    final repository = Directory.current.parent.parent;
    final fixture = await copyForgeFixture();
    try {
      final result = await WorkerProcessExecutor().execute(
        WorkerProcessSpec(
          workerId: 'conclave.forge',
          executable: 'dart',
          arguments: ['--disable-analytics', 'run', 'bin/forge_worker.dart'],
          workingDirectory: '${repository.path}/workers/forge',
        ),
        {
          'objective': 'Fix add and verify the implementation',
          'workerId': 'conclave.forge',
          'input': {'repositoryPath': fixture.path},
        },
        timeout: const Duration(minutes: 1),
      );
      expect(result['status'], 'completed');
      expect(result['summary'], contains('Forge completed'));
    } finally {
      await fixture.parent.delete(recursive: true);
    }
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/worker_protocol.dart' show workerProtocolVersion;
import 'package:conclave_host/repository_registry.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_path.dart';
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

  test('executes a V7 adapter over strict frames with progress and redaction',
      () async {
    final directory = await Directory.systemTemp.createTemp('v7-adapter-');
    addTearDown(() => directory.delete(recursive: true));
    final script = File('${directory.path}/adapter.dart');
    await script.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final type = request['type'];
    final base = {'protocolVersion': '1.0', 'requestId': request['requestId']};
    if (type == 'initialize.request') {
      stdout.writeln(jsonEncode({...base, 'type': 'initialize.result', 'adapterVersion': '1.2.3', 'capabilities': <String>[] }));
    } else if (type == 'version.request') {
      stdout.writeln(jsonEncode({...base, 'type': 'version.result', 'adapterVersion': '1.2.3'}));
    } else if (type == 'health.request') {
      stdout.writeln(jsonEncode({...base, 'type': 'health.result', 'healthy': true}));
    } else if (type == 'validate.request') {
      stdout.writeln(jsonEncode({...base, 'type': 'validate.result', 'ready': true, 'issues': <Object>[] }));
    } else if (type == 'execute.request') {
      stdout.writeln(jsonEncode({...base, 'type': 'progress', 'assignmentId': request['assignmentId'], 'message': 'working', 'percentage': 50}));
      stdout.writeln(jsonEncode({...base, 'type': 'result', 'assignmentId': request['assignmentId'], 'output': request['prompt'], 'artifacts': [{'name': 'trace', 'mediaType': 'text/plain', 'content': request['prompt']}] }));
    }
  }
}
''');
    final progress = <String>[];
    final result = await WorkerProcessExecutor().executeV7Adapter(
      WorkerProcessSpec(
        workerId: 'local-codex',
        executable: 'dart',
        arguments: ['run', script.path],
        workingDirectory: directory.path,
        secretValues: {'sensitive-token'},
      ),
      workerTypeId: 'codex',
      adapterVersion: '1.2.3',
      prompt: 'prompt with sensitive-token',
      operationId: 'v7-assignment-1',
      onProgress: (message, percentage) {
        progress.add('$message:${percentage?.toInt()}');
      },
    );
    expect(progress, ['working:50']);
    expect(result['summary'], 'prompt with [REDACTED]');
    expect((result['output'] as Map)['text'], 'prompt with [REDACTED]');
    expect(
      (((result['output'] as Map)['artifacts'] as List).single
          as Map)['content'],
      'prompt with [REDACTED]',
    );
    final validation = await WorkerProcessExecutor().executeV7Adapter(
      WorkerProcessSpec(
        workerId: 'local-codex-validation',
        executable: 'dart',
        arguments: ['run', script.path],
        workingDirectory: directory.path,
      ),
      workerTypeId: 'codex',
      adapterVersion: '1.2.3',
      prompt: '',
      validateOnly: true,
      config: const {'endpointUrl': 'https://provider.example.test'},
      operationId: 'v7-validation-only',
    );
    expect(validation['validated'], isTrue);
  });

  test('assignment resolution selects an admitted V7 adapter when available',
      () async {
    final directory = await Directory.systemTemp.createTemp('v7-assignment-');
    addTearDown(() => directory.delete(recursive: true));
    final script = File('${directory.path}/adapter.dart');
    await script.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final base = {'protocolVersion': '1.0', 'requestId': request['requestId']};
    switch (request['type']) {
      case 'initialize.request': stdout.writeln(jsonEncode({...base, 'type': 'initialize.result', 'adapterVersion': '1.2.3', 'capabilities': <String>[] }));
      case 'version.request': stdout.writeln(jsonEncode({...base, 'type': 'version.result', 'adapterVersion': '1.2.3'}));
      case 'health.request': stdout.writeln(jsonEncode({...base, 'type': 'health.result', 'healthy': true}));
      case 'validate.request': stdout.writeln(jsonEncode({...base, 'type': 'validate.result', 'ready': true, 'issues': <Object>[] }));
      case 'execute.request': stdout.writeln(jsonEncode({...base, 'type': 'result', 'assignmentId': request['assignmentId'], 'output': request['prompt']}));
    }
  }
}
''');
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => null,
      resolveV7Adapter: (_) => V7AdapterLaunch(
        processSpec: WorkerProcessSpec(
          workerId: 'workspace-worker-1',
          executable: 'dart',
          arguments: ['run', script.path],
          workingDirectory: directory.path,
        ),
        workerTypeId: 'codex',
        adapterVersion: '1.2.3',
      ),
    );
    final result = await handler.call(const HostAssignmentContext(
      workspaceId: 'workspace-1',
      hostId: 'runtime-1',
      workerId: 'workspace-worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-v7-1',
      idempotencyKey: 'idem-v7-1',
      payload: {
        'workerId': 'workspace-worker-1',
        'executionClass': 'stateless_read',
        'prompt': 'explain the change',
        'model': 'codex-latest',
      },
    ));
    expect(result.summary, 'explain the change');
    expect(result.output?['text'], 'explain the change');
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
    final conclave = (result.output?['input'] as Map)['conclave'] as Map;
    expect(conclave['assignmentId'], 'assignment-1');
    expect(conclave['workstreamExecutionGuidance'],
        anyElement(contains('persistent isolated working area')));
    expect(conclave['workstreamExecutionGuidance'],
        anyElement(contains('Fetch before integrating remote changes.')));
  });

  test('resolves process CWD from Project and Workstream IDs', () async {
    final root = await Directory.systemTemp.createTemp('cwd-root-');
    addTearDown(() => root.delete(recursive: true));
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
        pathResolver: WorkstreamPathResolver(root),
      ),
      resolve: (_) => const WorkerProcessSpec(
        workerId: 'cwd-worker',
        executable: 'worker',
        workingDirectory: '/cloud-supplied-path-must-not-be-used',
      ),
    );
    final context = const HostAssignmentContext(
      workspaceId: 'workspace-1',
      hostId: 'runtime-1',
      workerId: 'cwd-worker',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-cwd-1',
      idempotencyKey: 'idem-cwd-1',
      payload: {
        'workerId': 'cwd-worker',
        'projectId': 'project-1',
        'workstreamId': 'workstream-1',
        'workRequestId': 'request-1',
        'executionClass': 'stateless_read',
      },
    );

    final spec = await handler.prepareProcessSpec(context);
    final expected = await Directory(
      '${root.path}${Platform.pathSeparator}project-1${Platform.pathSeparator}workstream-1',
    ).resolveSymbolicLinks();
    expect(spec.workingDirectory, expected);

    final sameWorkstream = await handler.prepareProcessSpec(
      context.copyWith(
        workerId: 'claude-worker',
        payload: {
          ...context.payload,
          'workerId': 'claude-worker',
        },
      ),
    );
    final otherWorkstream = await handler.prepareProcessSpec(
      context.copyWith(
        payload: {
          ...context.payload,
          'workstreamId': 'workstream-2',
        },
      ),
    );
    expect(sameWorkstream.workingDirectory, expected);
    expect(otherWorkstream.workingDirectory, isNot(expected));
  });

  test('requires Workstream identity for stateful process CWD', () async {
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => const WorkerProcessSpec(
        workerId: 'worker',
        executable: 'worker',
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
        assignmentId: 'assignment-stateful-cwd',
        idempotencyKey: 'idem-stateful-cwd',
        payload: {
          'workerId': 'worker',
          'executionClass': 'stateful_workstream',
        },
      )),
      throwsA(predicate(
          (error) => error.toString().contains('projectId is required'))),
    );
  });

  test('applies the local Worker concurrency ceiling to its process spec',
      () async {
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => const WorkerProcessSpec(
        workerId: 'local-worker-1',
        executable: 'worker',
      ),
      resolveConcurrencyLimit: (_) async => 3,
    );
    final spec = await handler.prepareProcessSpec(const HostAssignmentContext(
      workspaceId: 'workspace-1',
      hostId: 'runtime-1',
      workerId: 'local-worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-concurrency-policy',
      idempotencyKey: 'idem-concurrency-policy',
      payload: {'workerId': 'local-worker-1'},
    ));
    expect(spec.maxConcurrentAssignments, 3);
  });

  test('rejects a Cloud-supplied CWD', () async {
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => const WorkerProcessSpec(
        workerId: 'cwd-worker',
        executable: 'missing-worker',
      ),
    );

    await expectLater(
      handler.call(const HostAssignmentContext(
        workspaceId: 'workspace-1',
        hostId: 'runtime-1',
        workerId: 'cwd-worker',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-cwd-rejected',
        idempotencyKey: 'idem-cwd-rejected',
        payload: {
          'workerId': 'cwd-worker',
          'projectId': 'project-1',
          'workstreamId': 'workstream-1',
          'cwd': '/tmp/escape',
        },
      )),
      throwsA(predicate(
          (error) => error.toString().contains('alternate working directory'))),
    );
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

  test('Worker removal cancels both running and queued assignments', () async {
    final directory = await createSilentWorker();
    final executor = WorkerProcessExecutor();
    final spec = WorkerProcessSpec(
      workerId: 'worker-to-remove',
      executable: 'dart',
      arguments: ['run', '${directory.path}/silent.dart'],
      maxConcurrentAssignments: 1,
    );
    try {
      final running = executor.execute(
        spec,
        {},
        operationId: 'remove-running',
        timeout: const Duration(seconds: 10),
      );
      final queued = executor.execute(
        spec,
        {},
        operationId: 'remove-queued',
        timeout: const Duration(seconds: 10),
      );
      final runningFailure =
          expectLater(running, throwsA(isA<ProcessException>()));
      final queuedFailure =
          expectLater(queued, throwsA(isA<ProcessException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await executor.cancelWorker('worker-to-remove'), 2);
      await Future.wait([runningFailure, queuedFailure]);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('cancelling a Worker terminates its nested child process', () async {
    final directory = await Directory.systemTemp.createTemp('worker-tree-');
    addTearDown(() => directory.delete(recursive: true));
    final childPath = '${directory.path}/child.dart';
    final heartbeatPath = '${directory.path}/heartbeat';
    final childPidPath = '${directory.path}/child.pid';
    await File(childPath).writeAsString('''
import 'dart:async';
import 'dart:io';
Future<void> main() async {
  final heartbeat = File(${jsonEncode(heartbeatPath)});
  while (true) {
    await heartbeat.writeAsString(DateTime.now().microsecondsSinceEpoch.toString());
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}
''');
    await File('${directory.path}/parent.dart').writeAsString('''
import 'dart:io';
Future<void> main() async {
  final child = await Process.start(Platform.resolvedExecutable,
      [${jsonEncode(childPath)}]);
  await File(${jsonEncode(childPidPath)}).writeAsString(child.pid.toString());
  await child.exitCode;
}
''');

    final executor = WorkerProcessExecutor();
    final execution = executor.execute(
      WorkerProcessSpec(
        workerId: 'nested-child',
        executable: 'dart',
        arguments: ['run', '${directory.path}/parent.dart'],
        workingDirectory: directory.path,
      ),
      {},
      operationId: 'assignment-cancel-tree',
      timeout: const Duration(seconds: 10),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while ((!await File(childPidPath).exists() ||
            !await File(heartbeatPath).exists()) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await File(childPidPath).exists(), isTrue);
    expect(await File(heartbeatPath).exists(), isTrue);
    final childPid = int.parse(await File(childPidPath).readAsString());
    expect(await executor.cancel('assignment-cancel-tree'), isTrue);
    await expectLater(execution, throwsA(isA<ProcessException>()));

    final heartbeatFile = File(heartbeatPath);
    final postCancelDeadline = DateTime.now().add(const Duration(seconds: 5));
    String? stoppedAt;
    while (DateTime.now().isBefore(postCancelDeadline)) {
      try {
        final before = await heartbeatFile.readAsString();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final after = await heartbeatFile.readAsString();
        if (before == after) {
          stoppedAt = after;
          break;
        }
      } on FileSystemException {
        // Windows may briefly deny reads while the terminated child closes
        // its inherited handle. Retry until the handle is released.
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(stoppedAt, isNotNull,
        reason: 'child process did not release its heartbeat file');
    if (!Platform.isWindows) {
      final probe = await Process.run('kill', ['-0', '$childPid']);
      expect(probe.exitCode, isNonZero);
    }
  });

  test('serializes assignments for one Worker at its local concurrency limit',
      () async {
    final directory = await Directory.systemTemp.createTemp('worker-gate-');
    addTearDown(() => directory.delete(recursive: true));
    final marker = '${directory.path}/started';
    final release = '${directory.path}/release';
    await File('${directory.path}/worker.dart').writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final method = request['method'];
    Object result = method == 'initialize'
        ? {
            'workerId': 'limited-worker',
            'version': '1.0.0',
            'protocolVersion': '$workerProtocolVersion',
            'runtimeLanguage': 'dart',
            'capabilities': <String>[],
          }
        : method == 'health' ? {'status': 'healthy'} : {'status': 'done'};
    if (method == 'execute') {
      await File('$marker').writeAsString('started\\n', mode: FileMode.append);
      while (!await File('$release').exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
  }
}
''');
    final executor = WorkerProcessExecutor();
    final spec = WorkerProcessSpec(
      workerId: 'limited-worker',
      executable: 'dart',
      arguments: ['run', '${directory.path}/worker.dart'],
      workingDirectory: directory.path,
      maxConcurrentAssignments: 1,
    );
    final first = executor.execute(spec, {},
        operationId: 'limited-1', timeout: const Duration(seconds: 10));
    final started = File(marker);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!await started.exists() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await started.exists(), isTrue);
    final second = executor.execute(spec, {},
        operationId: 'limited-2', timeout: const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await started.readAsLines(), hasLength(1));
    await File(release).writeAsString('go');
    await Future.wait([first, second]);
    expect(await started.readAsLines(), hasLength(2));
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

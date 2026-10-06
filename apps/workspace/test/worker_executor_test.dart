import 'dart:io';

import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/workstream_directory.dart';
import 'package:conclave_workspace/workstream_path.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/assignment_worker_fixture.dart';

void main() {
  test('desktop lifecycle wiring executes Work with fencing enabled', () async {
    final root = await Directory.systemTemp.createTemp('direct-runtime-');
    addTearDown(() => root.delete(recursive: true));
    var executions = 0;
    final handler = WorkerAssignmentHandler(
      workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
          pathResolver: WorkstreamPathResolver(root)),
      resolveLogicalWorker: (id) => assignmentWorker(id),
      executeWithToolProfile: (worker, directory, context, payload,
          {onProgress}) async {
        executions++;
        expect(directory.path, contains('workstream-1'));
        return WorkerResult(
            requestId: 'result-1',
            assignmentId: context.assignmentId,
            output: 'Work completed');
      },
    );
    WorkspaceAssignmentContext context(int fence) => WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker-1',
          runId: 'run-1',
          taskId: 'task-1',
          attemptId: 'attempt-1',
          assignmentId: 'assignment-1',
          idempotencyKey: 'idem-1',
          payload: {
            'workerId': 'worker-1',
            'workerTypeId': 'test-worker',
            'projectId': 'project-1',
            'workstreamId': 'workstream-1',
            'executionClass': 'stateful_workstream',
            'leaseId': 'lease-1',
            'fencingToken': fence,
          },
        );
    expect((await handler.call(context(2))).output?['text'], 'Work completed');
    await expectLater(
        handler.call(context(1)), throwsA(isA<WorkstreamMutationViolation>()));
    expect(executions, 1);
  });
  test('assignment execution uses the Tool Profile Engine runner', () async {
    final directory =
        await Directory.systemTemp.createTemp('profile-assignment-');
    addTearDown(() => directory.delete(recursive: true));
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(
        workerId,
        workerTypeId: 'chatgpt',
      ),
      executeWithToolProfile: (worker, workingDirectory, context, payload,
              {onProgress}) async =>
          WorkerResult(
        requestId: 'engine-result',
        assignmentId: context.assignmentId,
        output: 'explain the change',
      ),
    );
    final result = await handler.call(const WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'workspace-worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-engine-1',
      idempotencyKey: 'idem-engine-1',
      payload: {
        'workerId': 'workspace-worker-1',
        'workerTypeId': 'chatgpt',
        'executionClass': 'stateless_read',
        'prompt': 'explain the change',
        'model': 'codex-latest',
        'timeoutMs': 60000,
      },
    ));
    expect(result.summary, 'explain the change');
    expect(result.output?['text'], 'explain the change');
  });

  test('resolves process CWD from Project and Workstream IDs', () async {
    final root = await Directory.systemTemp.createTemp('cwd-root-');
    addTearDown(() => root.delete(recursive: true));
    final handler = WorkerAssignmentHandler(
      workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
        pathResolver: WorkstreamPathResolver(root),
      ),
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );
    final context = const WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'cwd-worker',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-cwd-1',
      idempotencyKey: 'idem-cwd-1',
      payload: {
        'workerId': 'cwd-worker',
        'workerTypeId': 'test-worker',
        'projectId': 'project-1',
        'workstreamId': 'workstream-1',
        'workRequestId': 'request-1',
        'executionClass': 'stateless_read',
      },
    );

    final scope = await handler.prepareAssignmentScope(context);
    final expected = await Directory(
      '${root.path}${Platform.pathSeparator}project-1${Platform.pathSeparator}workstream-1',
    ).resolveSymbolicLinks();
    expect(scope.workingDirectory.path, expected);

    final sameWorkstream = await handler.prepareAssignmentScope(
      context.copyWith(
        workerId: 'claude-worker',
        payload: {
          ...context.payload,
          'workerId': 'claude-worker',
          'workerTypeId': 'test-worker',
        },
      ),
    );
    final otherWorkstream = await handler.prepareAssignmentScope(
      context.copyWith(
        payload: {
          ...context.payload,
          'workstreamId': 'workstream-2',
        },
      ),
    );
    expect(sameWorkstream.workingDirectory.path, expected);
    expect(otherWorkstream.workingDirectory.path, isNot(expected));
  });

  test('requires Workstream identity for stateful process CWD', () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );

    await expectLater(
      handler.prepareAssignmentScope(const WorkspaceAssignmentContext(
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'runtime-1',
        workerId: 'worker',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-stateful-cwd',
        idempotencyKey: 'idem-stateful-cwd',
        payload: {
          'workerId': 'worker',
          'workerTypeId': 'test-worker',
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
      resolveLogicalWorker: (workerId) => assignmentWorker(
        workerId,
        localConcurrencyLimit: 3,
      ),
    );
    final scope =
        await handler.prepareAssignmentScope(const WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'local-worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-concurrency-policy',
      idempotencyKey: 'idem-concurrency-policy',
      payload: {
        'workerId': 'local-worker-1',
        'workerTypeId': 'test-worker',
      },
    ));
    expect(scope.worker.localConcurrencyLimit, 3);
  });

  test('rejects a Cloud-supplied CWD', () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );

    await expectLater(
      handler.call(const WorkspaceAssignmentContext(
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'runtime-1',
        workerId: 'cwd-worker',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-cwd-rejected',
        idempotencyKey: 'idem-cwd-rejected',
        payload: {
          'workerId': 'cwd-worker',
          'workerTypeId': 'test-worker',
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
      resolveLogicalWorker: (workerId) => assignmentWorker(
        workerId,
        permissions: {'repository:read'},
      ),
    );
    await expectLater(
      handler.call(const WorkspaceAssignmentContext(
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'workspace-1',
        workerId: 'worker-1',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-permission-denied',
        idempotencyKey: 'idem-permission-denied',
        payload: {
          'workerId': 'worker-1',
          'workerTypeId': 'test-worker',
          'permissions': ['shell:execute'],
        },
      )),
      throwsA(isA<AssignmentExecutionFailure>().having(
        (error) => error.code,
        'code',
        'permission_denied',
      )),
    );
  });
}

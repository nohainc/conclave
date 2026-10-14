import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show WorkerProfileSnapshotAdmission;
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/tool_profile_resolver.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/worker_launch_plan.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/assignment_worker_fixture.dart';

WorkerLaunchPlan _plan(int revision) => WorkerLaunchPlan(
      workerTypeId: 'test-worker',
      profileDefinitionId: 'test-profile',
      release: WorkerProfileSnapshotAdmission(
        profile: const {'profileDefinitionId': 'test-profile'},
        workerTypeId: 'test-worker',
        revision: revision,
        payloadDigest: 'digest-$revision',
      ),
      profileFile: File('profile-$revision.json'),
      source: ToolProfileResolutionSource.active,
      engineVersion: '1.3.0',
      providerCliVersion: null,
      preparedAt: DateTime.utc(2026, 10, 14),
    );

WorkspaceAssignmentContext _context(String id) => WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: id,
      idempotencyKey: 'idem-$id',
      payload: const {
        'workerId': 'worker-1',
        'workerTypeId': 'test-worker',
      },
    );

void main() {
  test('pins the admitted launch plan for the whole execution', () async {
    var resolutions = 0;
    var current = _plan(1);
    WorkerLaunchPlan? seenDuringExecution;
    late WorkerAssignmentHandler handler;
    handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (id) => assignmentWorker(id),
      resolveLaunchPlan: (worker) async {
        resolutions++;
        return current;
      },
      executeWithToolProfile: (worker, directory, context, payload,
          {onProgress}) async {
        // A newer Profile is activated while the assignment is running (or,
        // in production, queued). The admitted plan must not change.
        current = _plan(2);
        seenDuringExecution = handler.pinnedLaunchPlan(context.assignmentId);
        return WorkerResult(
          requestId: 'result',
          assignmentId: context.assignmentId,
          output: 'done',
        );
      },
    );

    await handler.call(_context('assignment-1'));

    expect(resolutions, 1);
    expect(seenDuringExecution?.profileRevision, 1);
    expect(handler.pinnedLaunchPlan('assignment-1'), isNull);

    // The next assignment is admitted with the newer Profile.
    await handler.call(_context('assignment-2'));
    expect(resolutions, 2);
  });

  test('releases the pinned plan when the assignment fails', () async {
    late WorkerAssignmentHandler handler;
    handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (id) => assignmentWorker(id),
      resolveLaunchPlan: (worker) async => _plan(1),
      executeWithToolProfile: (worker, directory, context, payload,
          {onProgress}) async {
        throw StateError('provider failed');
      },
    );
    await expectLater(
        handler.call(_context('assignment-1')), throwsA(isA<StateError>()));
    expect(handler.pinnedLaunchPlan('assignment-1'), isNull);
  });

  test('fails promptly with a specific error when no plan is available',
      () async {
    var executed = false;
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (id) => assignmentWorker(id),
      resolveLaunchPlan: (worker) async {
        throw const AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message: 'no plan',
          localDiagnostic: '{"reason":"noProfile"}',
        );
      },
      executeWithToolProfile: (worker, directory, context, payload,
          {onProgress}) async {
        executed = true;
        throw StateError('must not execute');
      },
    );
    final stopwatch = Stopwatch()..start();
    await expectLater(
      handler.call(_context('assignment-1')),
      throwsA(isA<AssignmentExecutionFailure>()
          .having((error) => error.code, 'code', 'worker_not_ready')
          .having((error) => error.localDiagnostic, 'diagnostic',
              contains('noProfile'))),
    );
    expect(executed, isFalse);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('records why a Worker is not ready when it is known locally', () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (id) => const AssignmentLogicalWorker(
        id: 'worker-1',
        workerTypeId: 'test-worker',
        enabled: false,
        ready: false,
        permissions: {},
        localConcurrencyLimit: 1,
        notReadyReason: 'catalog_not_synchronized',
      ),
    );
    await expectLater(
      handler.call(_context('assignment-1')),
      throwsA(isA<AssignmentExecutionFailure>()
          .having((error) => error.code, 'code', 'worker_not_ready')
          .having((error) => error.localDiagnostic, 'diagnostic',
              contains('catalog_not_synchronized'))),
    );
  });
}

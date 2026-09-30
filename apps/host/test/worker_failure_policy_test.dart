import 'dart:io';

import 'package:conclave_host/worker_failure_policy.dart';
import 'package:conclave_host/worker_process_supervisor.dart';
import 'package:conclave_host/worker_release_manifest.dart';
import 'package:conclave_host/worker_version_store.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Directory scratch;
  late WorkerFailurePolicy policy;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('worker-failure-policy-');
    final fixture = await Ed25519ReleaseFixture.create();
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/Workers'),
      trustPolicy: fixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
    );
    await store.stateDirectory('test').create(recursive: true);
    await store.releaseStateFile('test').writeAsString(
          '{"schemaVersion":1,"updatePolicy":"notify",'
          '"activeVersion":"1.1.0","lastKnownGoodVersion":"1.0.0"}',
        );
    policy = WorkerFailurePolicy(versionStore: store);
  });

  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test('retries a safe pre-execute crash once and clears its streak on success',
      () async {
    var attempts = 0;
    final output = await policy.run(
      workerTypeId: 'test',
      workerVersion: '1.1.0',
      attempt: () async {
        attempts++;
        if (attempts == 1) {
          throw const WorkerProcessFailure(
            WorkerIssueCode.workerInternalFailure,
            'process did not initialize',
            failureKind: WorkerRuntimeFailureKind.processCrash,
            retrySafe: true,
          );
        }
        return 'ok';
      },
    );

    expect(output, 'ok');
    expect(attempts, 2);
    expect(await policy.readState('test'), isNull);
  });

  test('quarantines repeated release failures and suggests the LKG', () async {
    for (var i = 0; i < 2; i++) {
      await expectLater(
        policy.run<void>(
          workerTypeId: 'test',
          workerVersion: '1.1.0',
          attempt: () async => throw const WorkerProcessFailure(
            WorkerIssueCode.malformedFrame,
            'invalid frame',
          ),
        ),
        throwsA(isA<WorkerProcessFailure>()),
      );
    }
    await expectLater(
      policy.run<void>(
        workerTypeId: 'test',
        workerVersion: '1.1.0',
        attempt: () async => throw const WorkerProcessFailure(
          WorkerIssueCode.workerInternalFailure,
          'worker error',
        ),
      ),
      throwsA(isA<WorkerReleaseNeedsAttention>()),
    );

    final state = await policy.readState('test');
    expect(state?.consecutiveFailureCount, 3);
    expect(state?.needsAttention, isTrue);
    expect(
        state?.lastFailureKind, WorkerRuntimeFailureKind.internalWorkerError);
    expect(state?.rollbackSuggestedVersion, '1.0.0');
    var attempted = false;
    await expectLater(
      policy.run<void>(
        workerTypeId: 'test',
        workerVersion: '1.1.0',
        attempt: () async {
          attempted = true;
        },
      ),
      throwsA(isA<WorkerReleaseNeedsAttention>()),
    );
    expect(attempted, isFalse);
  });

  test('provider and user failures do not increment the crash streak',
      () async {
    for (final code in [
      WorkerIssueCode.providerAuthenticationRequired,
      WorkerIssueCode.providerToolUnavailable,
      WorkerIssueCode.providerFailure,
      WorkerIssueCode.permissionDenied,
      WorkerIssueCode.deadlineExceeded,
    ]) {
      await expectLater(
        policy.run<void>(
          workerTypeId: 'test',
          workerVersion: '1.1.0',
          attempt: () async => throw WorkerProcessFailure(code, 'safe'),
        ),
        throwsA(isA<WorkerProcessFailure>()),
      );
    }
    expect(await policy.readState('test'), isNull);
  });

  test('failure taxonomy separates protocol, internal, and provider errors',
      () {
    expect(
      workerRuntimeFailureKind(WorkerIssueCode.malformedFrame),
      WorkerRuntimeFailureKind.protocolViolation,
    );
    expect(
      workerRuntimeFailureKind(WorkerIssueCode.workerInternalFailure),
      WorkerRuntimeFailureKind.internalWorkerError,
    );
    expect(
      workerRuntimeFailureKind(WorkerIssueCode.providerFailure),
      WorkerRuntimeFailureKind.providerOrUserFailure,
    );
  });
}

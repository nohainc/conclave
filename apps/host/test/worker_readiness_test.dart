import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_host/local_worker_registry.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/worker_readiness.dart';

import 'support/logical_worker_catalog_fixture.dart';

class _ReadinessPlatform implements PlatformRuntime {
  @override
  String get operatingSystem => 'test';
  @override
  bool get isWindows => false;
  @override
  String get homeDirectory => '/tmp';
  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {}
  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [];
  @override
  Future<Process> startIsolatedProcess(
          String executable, List<String> arguments,
          {String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true}) =>
      throw UnsupportedError('the injected readiness probe avoids processes');
  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {}
}

void main() {
  test('readiness assessments retain issue codes directly', () {
    const assessment = WorkerReadinessAssessment(
      WorkerReadinessState.setupRequired,
      issueCode: 'setup_required',
    );
    expect(assessment.state, WorkerReadinessState.setupRequired);
    expect(assessment.issueCode, 'setup_required');
  });

  test('rechecks local Workers and syncs changed readiness state', () async {
    final directory = await Directory.systemTemp.createTemp('worker-ready-');
    addTearDown(() => directory.delete(recursive: true));
    var syncs = 0;
    final registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-ready',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-chatgpt',
      onChanged: () async => syncs++,
    );
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      localPermissions: const ['workstream_filesystem', 'shell_execution'],
      status: LocalWorkerStatus.ready,
      readinessState: WorkerReadinessState.ready,
    );
    await Future<void>.delayed(Duration.zero);
    syncs = 0;
    var checks = 0;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      interval: const Duration(milliseconds: 10),
      assessWorker: (_) async {
        checks++;
        return const WorkerReadinessAssessment(
          WorkerReadinessState.testFailed,
          issueCode: 'unsupported_cli_version',
        );
      },
    );
    await monitor.checkNow();
    final updated = await registry.find(worker.id);
    expect(checks, 1);
    expect(updated!.readinessState, WorkerReadinessState.testFailed);
    expect(updated.readinessIssueCode, 'unsupported_cli_version');
    expect(updated.lastPassiveProbeAt, isNotNull);
    expect(updated.status, LocalWorkerStatus.needsAttention);
    await Future<void>.delayed(Duration.zero);
    expect(syncs, 1);
    final restoredRegistry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-ready',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'unused',
    );
    expect((await restoredRegistry.find(worker.id))!.readinessState,
        WorkerReadinessState.testFailed);
    await monitor.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await monitor.dispose();
    expect(checks, greaterThanOrEqualTo(3));
  });

  test('disabled Workers remain disabled and are not probed', () async {
    final directory = await Directory.systemTemp.createTemp('worker-ready-');
    addTearDown(() => directory.delete(recursive: true));
    final registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-disabled',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-gemini',
    );
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('gemini'),
      localPermissions: const ['workstream_filesystem', 'shell_execution'],
      status: LocalWorkerStatus.disabled,
      readinessState: WorkerReadinessState.setupRequired,
    );
    var checks = 0;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      assessWorker: (_) async {
        checks++;
        return const WorkerReadinessAssessment(WorkerReadinessState.ready);
      },
    );
    await monitor.checkNow();
    expect(checks, 0);
    expect((await registry.find(worker.id))!.activationState,
        LocalWorkerActivationState.disabled);
    expect((await registry.find(worker.id))!.readinessState,
        WorkerReadinessState.setupRequired);
    await monitor.checkNow(mode: LocalWorkerProbeMode.live);
    final tested = (await registry.find(worker.id))!;
    expect(tested.status, LocalWorkerStatus.disabled);
    expect(tested.readinessState, WorkerReadinessState.setupRequired);
    expect(tested.lastLiveTestAt, isNotNull);
    expect(tested.lastLiveTestPassed, isTrue);
    await monitor.dispose();
  });

  test('manual live test targets only the selected Worker Type', () async {
    final directory =
        await Directory.systemTemp.createTemp('worker-live-test-');
    addTearDown(() => directory.delete(recursive: true));
    var nextId = 0;
    final registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-live-test',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-${nextId++}',
    );
    for (final type in const ['chatgpt', 'gemini']) {
      await registry.create(
        catalogEntry: logicalWorkerCatalogFixture(type),
        status: LocalWorkerStatus.ready,
        readinessState: WorkerReadinessState.ready,
      );
    }
    final testedTypes = <String>[];
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      assessWorker: (worker) async {
        testedTypes.add(worker.workerTypeId);
        return const WorkerReadinessAssessment(
          WorkerReadinessState.ready,
          toolVersion: '1.2.3',
          replaceToolVersion: true,
          toolName: 'Antigravity CLI',
          replaceToolName: true,
          toolPath: '/Users/test/.local/bin/agy',
          replaceToolPath: true,
        );
      },
    );

    await monitor.checkNow(
        mode: LocalWorkerProbeMode.live, workerTypeId: 'gemini');

    expect(testedTypes, ['gemini']);
    final gemini = (await registry.list())
        .singleWhere((worker) => worker.workerTypeId == 'gemini');
    final chatgpt = (await registry.list())
        .singleWhere((worker) => worker.workerTypeId == 'chatgpt');
    expect(gemini.lastLiveTestPassed, isTrue);
    expect(gemini.lastLiveTestAt, isNotNull);
    expect(gemini.toolVersion, '1.2.3');
    expect(gemini.toolName, 'Antigravity CLI');
    expect(gemini.toolPath, '/Users/test/.local/bin/agy');
    expect(chatgpt.lastLiveTestAt, isNull);
    await monitor.dispose();
  });

  test('Gemini passive setup state is preserved separately from live result',
      () async {
    final directory = await Directory.systemTemp.createTemp('gemini-probe-');
    addTearDown(() => directory.delete(recursive: true));
    final registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-gemini-probe',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-gemini',
    );
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('gemini'),
    );
    var livePasses = false;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      assessWorker: (current) async =>
          livePasses && current.lastLiveTestAt == null
              ? const WorkerReadinessAssessment(WorkerReadinessState.ready)
              : const WorkerReadinessAssessment(
                  WorkerReadinessState.setupRequired,
                  issueCode: 'setup_required',
                ),
    );

    await monitor.checkNow();
    final passive = (await registry.find(worker.id))!;
    expect(passive.status, LocalWorkerStatus.needsAttention);
    expect(passive.readinessState, WorkerReadinessState.setupRequired);
    expect(passive.readinessIssueCode, 'setup_required');
    expect(passive.lastPassiveProbeAt, isNotNull);
    expect(passive.lastLiveTestAt, isNull);

    livePasses = true;
    await monitor.checkNow(mode: LocalWorkerProbeMode.live);
    final live = (await registry.find(worker.id))!;
    expect(live.status, LocalWorkerStatus.ready);
    expect(live.readinessState, WorkerReadinessState.setupRequired);
    expect(live.readinessIssueCode, 'setup_required');
    expect(live.lastLiveTestPassed, isTrue);
    expect(live.lastLiveTestAt, isNotNull);

    await monitor.checkNow();
    final rechecked = (await registry.find(worker.id))!;
    expect(rechecked.status, LocalWorkerStatus.ready);
    expect(rechecked.readinessState, WorkerReadinessState.setupRequired);
    expect(rechecked.lastLiveTestPassed, isTrue);
    await monitor.dispose();
  });

  test('manual failed test retains safe local details and success clears them',
      () async {
    final directory = await Directory.systemTemp.createTemp('worker-details-');
    addTearDown(() => directory.delete(recursive: true));
    final registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-test-details',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-chatgpt',
    );
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      status: LocalWorkerStatus.ready,
      readinessState: WorkerReadinessState.ready,
    );
    var shouldFail = true;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      assessWorker: (_) async => shouldFail
          ? const WorkerReadinessAssessment(
              WorkerReadinessState.runtimeUnavailable)
          : const WorkerReadinessAssessment(WorkerReadinessState.ready),
    );

    await monitor.checkNow(
        mode: LocalWorkerProbeMode.live, workerTypeId: 'chatgpt');
    final failed = (await registry.find(worker.id))!;
    expect(failed.lastLiveTestPassed, isFalse);
    expect(failed.lastLiveTestDetails, contains('execution_test_failed'));
    expect(failed.lastLiveTestDetails, contains('Tool Profile test failed'));

    shouldFail = false;
    await monitor.checkNow(
        mode: LocalWorkerProbeMode.live, workerTypeId: 'chatgpt');
    final passed = (await registry.find(worker.id))!;
    expect(passed.lastLiveTestPassed, isTrue);
    expect(passed.lastLiveTestDetails, isNull);
    await monitor.dispose();
  });

  test('startup quarantines cached Ready until live checks pass', () async {
    final directory = await Directory.systemTemp.createTemp('worker-ready-');
    addTearDown(() => directory.delete(recursive: true));
    final registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-startup',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-chatgpt',
    );
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      localPermissions: const ['workstream_filesystem', 'shell_execution'],
      status: LocalWorkerStatus.ready,
    );
    final result = Completer<WorkerReadinessAssessment>();
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      interval: const Duration(hours: 1),
      assessWorker: (_) => result.future,
    );
    await monitor.start();
    final quarantined = await registry.find(worker.id);
    expect(quarantined!.status, LocalWorkerStatus.needsAttention);
    expect(quarantined.readinessState, WorkerReadinessState.notProbed);
    expect(quarantined.readinessIssueCode, 'probe_required');
    result
        .complete(const WorkerReadinessAssessment(WorkerReadinessState.ready));
    await monitor.checkNow();
    final checked = await registry.find(worker.id);
    expect(checked!.status, LocalWorkerStatus.ready);
    expect(checked.readinessState, WorkerReadinessState.ready);
    await monitor.dispose();
  });
}

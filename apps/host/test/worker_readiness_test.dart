import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:conclave_host/worker_readiness.dart';

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

class _MissingFirstPartyAdapterStore extends V7AdapterPackageStore {
  _MissingFirstPartyAdapterStore({
    required super.root,
  }) : super(
          trustPolicy: WorkerTrustPolicy(),
          allowedPermissions: WorkerPermission.values.toSet(),
        );

  final ensuredPackageIds = <String>[];

  @override
  Future<bool> hasVerifiedActivePackage(String workerTypeId,
          [List<String>? localPermissions]) async =>
      false;

  @override
  Future<bool> ensureFirstPartyAdapterAvailable(
    String workerTypeId,
  ) async {
    ensuredPackageIds.add(workerTypeId);
    return false;
  }
}

void main() {
  test('readiness assessments retain package issue codes directly', () {
    const assessment = WorkerReadinessAssessment(
      WorkerReadinessState.setupRequired,
      issueCode: 'setup_required',
    );
    expect(assessment.state, WorkerReadinessState.setupRequired);
    expect(assessment.issueCode, 'setup_required');
  });

  test('readiness ensures the mapped package before probing', () async {
    final directory = await Directory.systemTemp.createTemp('worker-fallback-');
    addTearDown(() => directory.delete(recursive: true));
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-fallback',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-chatgpt',
    );
    await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
      localPermissions: const ['workstream_filesystem', 'shell_execution'],
    );
    final adapterStore = _MissingFirstPartyAdapterStore(
      root: Directory('${directory.path}/adapters'),
    );
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: adapterStore,
    );

    await monitor.checkNow();

    expect(adapterStore.ensuredPackageIds, ['codex']);
    final worker = (await registry.list()).single;
    expect(worker.readinessState, WorkerReadinessState.adapterUnavailable);
    expect(worker.readinessIssueCode, 'package_unavailable');
    expect(worker.lastPassiveProbeAt, isNotNull);
    await monitor.dispose();
  });

  test('rechecks configured Workers and syncs changed readiness state',
      () async {
    final directory = await Directory.systemTemp.createTemp('worker-ready-');
    addTearDown(() => directory.delete(recursive: true));
    var syncs = 0;
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-ready',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-chatgpt',
      onChanged: () async => syncs++,
    );
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
      localPermissions: const ['workstream_filesystem', 'shell_execution'],
      credentialStatus: LocalWorkerCredentialStatus.ready,
      status: LocalWorkerStatus.ready,
      readinessState: WorkerReadinessState.ready,
    );
    await Future<void>.delayed(Duration.zero);
    syncs = 0;
    var checks = 0;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: V7AdapterPackageStore(
        root: Directory('${directory.path}/adapters'),
        trustPolicy: WorkerTrustPolicy(),
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
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
    final restoredRegistry = LocalConfiguredWorkerRegistry(
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
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-disabled',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-gemini',
    );
    final worker = await registry.create(
      name: 'Gemini',
      workerTypeId: 'gemini',
      authStrategy: 'browser_auth',
      localPermissions: const ['workstream_filesystem', 'shell_execution'],
      credentialStatus: LocalWorkerCredentialStatus.ready,
      status: LocalWorkerStatus.disabled,
      readinessState: WorkerReadinessState.disabled,
    );
    var checks = 0;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: V7AdapterPackageStore(
        root: Directory('${directory.path}/adapters'),
        trustPolicy: WorkerTrustPolicy(),
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
      assessWorker: (_) async {
        checks++;
        return const WorkerReadinessAssessment(WorkerReadinessState.ready);
      },
    );
    await monitor.checkNow();
    expect(checks, 0);
    expect((await registry.find(worker.id))!.readinessState,
        WorkerReadinessState.disabled);
    await monitor.checkNow(mode: LocalWorkerProbeMode.live);
    final tested = (await registry.find(worker.id))!;
    expect(tested.status, LocalWorkerStatus.disabled);
    expect(tested.readinessState, WorkerReadinessState.disabled);
    expect(tested.lastLiveTestAt, isNotNull);
    expect(tested.lastLiveTestPassed, isTrue);
    await monitor.dispose();
  });

  test('manual live test targets only the selected Worker Type', () async {
    final directory =
        await Directory.systemTemp.createTemp('worker-live-test-');
    addTearDown(() => directory.delete(recursive: true));
    var nextId = 0;
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-live-test',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-${nextId++}',
    );
    for (final type in const ['chatgpt', 'gemini']) {
      await registry.create(
        name: type,
        workerTypeId: type,
        authStrategy: 'browser_auth',
        status: LocalWorkerStatus.ready,
        readinessState: WorkerReadinessState.ready,
        credentialStatus: LocalWorkerCredentialStatus.ready,
      );
    }
    final testedTypes = <String>[];
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: V7AdapterPackageStore(
        root: Directory('${directory.path}/adapters'),
        trustPolicy: WorkerTrustPolicy(),
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
      assessWorker: (worker) async {
        testedTypes.add(worker.workerTypeId);
        return const WorkerReadinessAssessment(
          WorkerReadinessState.ready,
          toolVersion: '1.2.3',
          replaceToolVersion: true,
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
    expect(chatgpt.lastLiveTestAt, isNull);
    await monitor.dispose();
  });

  test('Gemini passive setup state is preserved separately from live result',
      () async {
    final directory = await Directory.systemTemp.createTemp('gemini-probe-');
    addTearDown(() => directory.delete(recursive: true));
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-gemini-probe',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-gemini',
    );
    final worker = await registry.create(
      name: 'Gemini',
      workerTypeId: 'gemini',
      authStrategy: 'browser_auth',
      credentialStatus: LocalWorkerCredentialStatus.ready,
    );
    var livePasses = false;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: V7AdapterPackageStore(
        root: Directory('${directory.path}/adapters'),
        trustPolicy: WorkerTrustPolicy(),
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
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
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-test-details',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-chatgpt',
    );
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
      status: LocalWorkerStatus.ready,
      readinessState: WorkerReadinessState.ready,
      credentialStatus: LocalWorkerCredentialStatus.ready,
    );
    var shouldFail = true;
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: V7AdapterPackageStore(
        root: Directory('${directory.path}/adapters'),
        trustPolicy: WorkerTrustPolicy(),
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
      assessWorker: (_) async => shouldFail
          ? const WorkerReadinessAssessment(
              WorkerReadinessState.adapterUnavailable)
          : const WorkerReadinessAssessment(WorkerReadinessState.ready),
    );

    await monitor.checkNow(
        mode: LocalWorkerProbeMode.live, workerTypeId: 'chatgpt');
    final failed = (await registry.find(worker.id))!;
    expect(failed.lastLiveTestPassed, isFalse);
    expect(failed.lastLiveTestDetails, contains('execution_test_failed'));
    expect(failed.lastLiveTestDetails, contains('Worker Package test failed'));

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
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-startup',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-chatgpt',
    );
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
      localPermissions: const ['workstream_filesystem', 'shell_execution'],
      credentialStatus: LocalWorkerCredentialStatus.ready,
      status: LocalWorkerStatus.ready,
    );
    final result = Completer<WorkerReadinessAssessment>();
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: V7AdapterPackageStore(
        root: Directory('${directory.path}/adapters'),
        trustPolicy: WorkerTrustPolicy(),
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
      interval: const Duration(hours: 1),
      assessWorker: (_) => result.future,
    );
    await monitor.start();
    final quarantined = await registry.find(worker.id);
    expect(quarantined!.status, LocalWorkerStatus.needsAttention);
    expect(quarantined.readinessState, WorkerReadinessState.ready);
    result
        .complete(const WorkerReadinessAssessment(WorkerReadinessState.ready));
    await monitor.checkNow();
    final checked = await registry.find(worker.id);
    expect(checked!.status, LocalWorkerStatus.ready);
    expect(checked.readinessState, WorkerReadinessState.ready);
    await monitor.dispose();
  });
}

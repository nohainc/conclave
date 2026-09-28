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

void main() {
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
          WorkerReadinessState.unsupportedCliVersion,
        );
      },
    );
    await monitor.checkNow();
    final updated = await registry.find(worker.id);
    expect(checks, 1);
    expect(updated!.readinessState, WorkerReadinessState.unsupportedCliVersion);
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
        WorkerReadinessState.unsupportedCliVersion);
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
    expect(quarantined.readinessState, WorkerReadinessState.testFailed);
    result
        .complete(const WorkerReadinessAssessment(WorkerReadinessState.ready));
    await monitor.checkNow();
    final checked = await registry.find(worker.id);
    expect(checked!.status, LocalWorkerStatus.ready);
    expect(checked.readinessState, WorkerReadinessState.ready);
    await monitor.dispose();
  });
}

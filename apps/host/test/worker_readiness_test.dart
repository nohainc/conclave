import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_host/adapter_prerequisite.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/first_party_worker_adapter_descriptor.dart';
import 'package:conclave_host/first_party_worker_cli_locator.dart';
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
    required super.cliLocator,
  }) : super(
          trustPolicy: WorkerTrustPolicy(),
          allowedPermissions: WorkerPermission.values.toSet(),
        );

  final ensuredPackageIds = <String>[];
  final ensuredSearchDirectories = <List<String>>[];

  @override
  Future<bool> hasVerifiedActivePackage(String workerTypeId,
          [List<String>? localPermissions,
          List<String> additionalPathDirectories = const []]) async =>
      false;

  @override
  Future<bool> ensureFirstPartyAdapterAvailable(
    String workerTypeId, {
    List<String> additionalPathDirectories = const [],
  }) async {
    ensuredPackageIds.add(workerTypeId);
    ensuredSearchDirectories.add(additionalPathDirectories);
    return false;
  }
}

void main() {
  var workerId = 0;

  test('readiness assessments expose stable reason codes', () {
    expect(
      const WorkerReadinessAssessment(WorkerReadinessState.notInstalled)
          .reasonCode
          .wireValue,
      'cli_not_found',
    );
    expect(
      const WorkerReadinessAssessment(
        WorkerReadinessState.unsupportedCliVersion,
      ).reasonCode.wireValue,
      'unsupported_cli_version',
    );
    expect(
      const WorkerReadinessAssessment(WorkerReadinessState.signInRequired)
          .reasonCode
          .wireValue,
      'authentication_required',
    );
    expect(
      const WorkerReadinessAssessment(WorkerReadinessState.testFailed)
          .reasonCode
          .wireValue,
      'execution_test_failed',
    );
    expect(
      const WorkerReadinessAssessment(WorkerReadinessState.ready)
          .reasonCode
          .wireValue,
      'ready',
    );
  });

  test('readiness restores the first-party fallback before adapter probing',
      () async {
    final directory = await Directory.systemTemp.createTemp('worker-fallback-');
    addTearDown(() => directory.delete(recursive: true));
    final cliDirectory = Directory('${directory.path}/bin');
    await cliDirectory.create(recursive: true);
    final cli = File('${cliDirectory.path}/codex');
    await cli.writeAsString('fake codex CLI');
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
      executablePath: cli.path,
      cliVersion: '0.158.0',
    );
    final adapterStore = _MissingFirstPartyAdapterStore(
      root: Directory('${directory.path}/adapters'),
      cliLocator: FirstPartyWorkerCliExecutableLocator(
        environment: const {'PATH': ''},
        knownDirectories: const [],
        probeExecutable: (_, {searchPath}) async =>
            const AdapterPrerequisiteResult(
          satisfied: true,
          detectedVersion: '0.158.0',
          message: 'CLI is available.',
        ),
      ),
    );
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: adapterStore,
    );

    await monitor.checkNow();

    expect(adapterStore.ensuredPackageIds, ['codex']);
    expect(adapterStore.ensuredSearchDirectories, [
      [cliDirectory.path],
    ]);
    final worker = (await registry.list()).single;
    expect(worker.readinessState, WorkerReadinessState.adapterUnavailable);
    expect(worker.executablePath, cli.path);
    expect(worker.cliVersion, '0.158.0');
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
          WorkerReadinessState.unsupportedCliVersion,
          executablePath: '/opt/homebrew/bin/codex',
          cliVersion: '1.2.3',
        );
      },
    );
    await monitor.checkNow();
    final updated = await registry.find(worker.id);
    expect(checks, 1);
    expect(updated!.readinessState, WorkerReadinessState.unsupportedCliVersion);
    expect(updated.status, LocalWorkerStatus.needsAttention);
    expect(updated.executablePath, '/opt/homebrew/bin/codex');
    expect(updated.cliVersion, '1.2.3');
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
    await monitor.checkNow(executionTest: true);
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
        return const WorkerReadinessAssessment(WorkerReadinessState.ready);
      },
    );

    await monitor.checkNow(executionTest: true, workerTypeId: 'gemini');

    expect(testedTypes, ['gemini']);
    final gemini = (await registry.list())
        .singleWhere((worker) => worker.workerTypeId == 'gemini');
    final chatgpt = (await registry.list())
        .singleWhere((worker) => worker.workerTypeId == 'chatgpt');
    expect(gemini.lastLiveTestPassed, isTrue);
    expect(gemini.lastLiveTestAt, isNotNull);
    expect(chatgpt.lastLiveTestAt, isNull);
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

    await monitor.checkNow(executionTest: true, workerTypeId: 'chatgpt');
    final failed = (await registry.find(worker.id))!;
    expect(failed.lastLiveTestPassed, isFalse);
    expect(failed.lastLiveTestDetails, contains('execution_test_failed'));
    expect(failed.lastLiveTestDetails, contains('local integration'));

    shouldFail = false;
    await monitor.checkNow(executionTest: true, workerTypeId: 'chatgpt');
    final passed = (await registry.find(worker.id))!;
    expect(passed.lastLiveTestPassed, isTrue);
    expect(passed.lastLiveTestDetails, isNull);
    await monitor.dispose();
  });

  test('login-item startup locates and persists both CLIs with minimal PATH',
      () async {
    if (Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('worker-login-');
    addTearDown(() => directory.delete(recursive: true));
    final cliDirectory = Directory('${directory.path}/home/.local/bin');
    await cliDirectory.create(recursive: true);
    for (final descriptor in FirstPartyWorkerAdapterDescriptor.all) {
      final name = descriptor.executableCandidates.single;
      final executable = File('${cliDirectory.path}/$name');
      await executable.writeAsString(
        '#!/bin/sh\nif [ "\$1" = "--version" ]; then '
        'echo "$name 1.2.3"; fi\nexit 0\n',
      );
      final chmod = await Process.run('chmod', ['755', executable.path]);
      expect(chmod.exitCode, 0);
    }
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-login',
      platform: _ReadinessPlatform(),
      idGenerator: () => 'worker-${++workerId}',
    );
    for (final descriptor in FirstPartyWorkerAdapterDescriptor.all) {
      await registry.create(
        name: descriptor.productName,
        workerTypeId: descriptor.productWorkerTypeId,
        authStrategy: descriptor.authStrategy,
        localPermissions: descriptor.requiredLocalPermissions,
      );
    }
    final monitor = WorkerReadinessMonitor(
      registry: registry,
      adapterStore: V7AdapterPackageStore(
        root: Directory('${directory.path}/adapters'),
        trustPolicy: WorkerTrustPolicy(),
        allowedPermissions: WorkerPermission.values.toSet(),
        cliLocator: FirstPartyWorkerCliExecutableLocator(
          environment: {
            'PATH': '/usr/bin:/bin',
            'HOME': '${directory.path}/home',
          },
        ),
      ),
      interval: const Duration(hours: 1),
    );
    await monitor.start();
    await monitor.checkNow();
    await monitor.dispose();
    final saved = await registry.list();
    for (final descriptor in FirstPartyWorkerAdapterDescriptor.all) {
      final worker = saved.singleWhere(
        (item) => item.workerTypeId == descriptor.productWorkerTypeId,
      );
      expect(
        worker.executablePath,
        '${cliDirectory.path}/${descriptor.executableCandidates.single}',
      );
      expect(worker.cliVersion, '1.2.3');
    }
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

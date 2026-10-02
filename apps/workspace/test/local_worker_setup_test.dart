import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/local_worker_permissions.dart';
import 'package:conclave_workspace/local_worker_setup.dart';
import 'package:conclave_workspace/platform_runtime.dart';

import 'support/logical_worker_catalog_fixture.dart';

class _TestPlatformRuntime implements PlatformRuntime {
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
      bool includeParentEnvironment = true}) {
    throw UnsupportedError('not used by local Worker setup tests');
  }

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {}
}

void main() {
  late Directory directory;
  late LocalWorkerRegistry registry;
  var workerSequence = 0;

  setUp(() async {
    workerSequence = 0;
    directory = await Directory.systemTemp.createTemp('conclave-worker-setup-');
    registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      platform: _TestPlatformRuntime(),
      idGenerator: () => 'worker-${++workerSequence}',
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('setup uses a logical Worker supplied by the cached catalog', () async {
    final worker =
        await LocalWorkerSetupService(registry: registry).createCatalogWorker(
      entry: logicalWorkerCatalogFixture('chatgpt'),
      permissions: firstPartyWorkerLocalPermissions,
    );
    expect(worker.workerTypeId, 'chatgpt');
    expect(worker.localConcurrencyLimit, defaultLocalWorkerConcurrency);
    expect(worker.status, LocalWorkerStatus.needsAttention);
    expect(worker.localPermissions, firstPartyWorkerLocalPermissions);
    final file = File(
        '${directory.path}${Platform.pathSeparator}configured-workers.json');
    expect(jsonDecode(await file.readAsString())['workers'], hasLength(1));
  });

  test('new catalog Worker starts unprobed until its first readiness check',
      () async {
    final worker =
        await LocalWorkerSetupService(registry: registry).createCatalogWorker(
      entry: logicalWorkerCatalogFixture('gemini'),
      permissions: firstPartyWorkerLocalPermissions,
    );

    expect(worker.status, LocalWorkerStatus.needsAttention);
    expect(worker.readinessState, WorkerReadinessState.notProbed);
    expect(worker.readinessIssueCode, isNull);
    expect(worker.lastPassiveProbeAt, isNull);
    expect(worker.lastLiveTestAt, isNull);
  });
}

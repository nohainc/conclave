import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/first_party_worker_registry.dart';
import 'package:conclave_host/local_worker_permissions.dart';
import 'package:conclave_host/local_worker_setup.dart';
import 'package:conclave_host/platform_runtime.dart';

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
  late LocalConfiguredWorkerRegistry registry;
  var workerSequence = 0;

  setUp(() async {
    workerSequence = 0;
    directory = await Directory.systemTemp.createTemp('conclave-worker-setup-');
    registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      platform: _TestPlatformRuntime(),
      idGenerator: () => 'worker-${++workerSequence}',
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('v1 registry contains only the product to package mapping', () {
    expect(
      FirstPartyWorkerPackage.all
          .map((type) => type.productWorkerTypeId)
          .toList(),
      ['chatgpt', 'gemini'],
    );
    expect(
      FirstPartyWorkerPackage.all.map((type) => type.productName).toList(),
      ['ChatGPT', 'Gemini'],
    );
    expect(
      FirstPartyWorkerPackage.all.map((type) => type.packageId).toList(),
      ['codex', 'antigravity'],
    );
    final chatgpt = FirstPartyWorkerPackage.all.first;
    expect(chatgpt.productWorkerTypeId, 'chatgpt');
    expect(chatgpt.productName, 'ChatGPT');
    expect(chatgpt.packageId, 'codex');
    final gemini = FirstPartyWorkerPackage.all.last;
    expect(gemini.productWorkerTypeId, 'gemini');
    expect(gemini.productName, 'Gemini');
    expect(gemini.packageId, 'antigravity');
    expect(
      FirstPartyWorkerPackage.canonicalProductWorkerTypeId('codex'),
      'chatgpt',
    );
    expect(
      FirstPartyWorkerPackage.canonicalProductWorkerTypeId('antigravity'),
      'gemini',
    );
    expect(
      FirstPartyWorkerPackage.packageIdFor('chatgpt'),
      'codex',
    );
    expect(
      FirstPartyWorkerPackage.packageIdFor('gemini'),
      'antigravity',
    );
  });

  test('setup creates a pending package worker without provider metadata',
      () async {
    final type = FirstPartyWorkerPackage.all.first;
    final worker = await LocalWorkerSetupService(registry: registry).create(
      type: type,
      permissions: firstPartyWorkerLocalPermissions,
    );
    expect(worker.workerTypeId, 'chatgpt');
    expect(worker.localConcurrencyLimit, defaultLocalWorkerConcurrency);
    expect(worker.status, LocalWorkerStatus.needsAttention);
    expect(worker.credentialStatus, LocalWorkerCredentialStatus.notRequired);
    expect(worker.credentialRef, isNull);
    final file = File(
        '${directory.path}${Platform.pathSeparator}configured-workers.json');
    expect(jsonDecode(await file.readAsString())['workers'], hasLength(1));
  });

  test('never-tested Gemini starts in setup-required state', () async {
    final gemini = FirstPartyWorkerPackage.forProductWorkerTypeId('gemini')!;
    final worker = await LocalWorkerSetupService(registry: registry).create(
      type: gemini,
      permissions: firstPartyWorkerLocalPermissions,
    );

    expect(worker.status, LocalWorkerStatus.needsAttention);
    expect(worker.readinessState, WorkerReadinessState.setupRequired);
    expect(worker.readinessIssueCode, 'setup_required');
    expect(worker.lastPassiveProbeAt, isNull);
    expect(worker.lastLiveTestAt, isNull);
  });

  test('registry excludes non-v1 product Worker Types', () {
    expect(
      FirstPartyWorkerPackage.forProductWorkerTypeId('claude-code'),
      isNull,
    );
    expect(
      FirstPartyWorkerPackage.forPackageId('claude-code'),
      isNull,
    );
  });
}

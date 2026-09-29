import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/first_party_worker_adapter_descriptor.dart';
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

  test('v1 local catalog contains only ChatGPT and Gemini CLI integrations',
      () {
    expect(
      FirstPartyWorkerAdapterDescriptor.all
          .map((type) => type.productWorkerTypeId)
          .toList(),
      ['chatgpt', 'gemini'],
    );
    expect(
      FirstPartyWorkerAdapterDescriptor.all
          .map((type) => type.productName)
          .toList(),
      ['ChatGPT', 'Gemini'],
    );
    expect(
      FirstPartyWorkerAdapterDescriptor.all
          .map((type) => type.executableCandidates.single)
          .toList(),
      ['codex', 'agy'],
    );
    final chatgpt = FirstPartyWorkerAdapterDescriptor.all.first;
    expect(chatgpt.productWorkerTypeId, 'chatgpt');
    expect(chatgpt.productName, 'ChatGPT');
    expect(chatgpt.adapterPackageId, 'codex');
    expect(chatgpt.probeStrategy.id, 'codex_login_status');
    expect(chatgpt.probeStrategy.authenticationArguments, ['login', 'status']);
    expect(chatgpt.supportedCliVersionRange.minimum, isNull);
    expect(chatgpt.supportedCliVersionRange.maximum, isNull);
    expect(chatgpt.defaultLocalConcurrency, 1);
    expect(chatgpt.requiredLocalPermissions,
        ['workstream_filesystem', 'shell_execution']);
    final gemini = FirstPartyWorkerAdapterDescriptor.all.last;
    expect(gemini.productWorkerTypeId, 'gemini');
    expect(gemini.productName, 'Gemini');
    expect(gemini.supportedCliVersionRange.minimum, isNull);
    expect(gemini.supportedCliVersionRange.maximum, isNull);
    expect(gemini.adapterPackageId, 'antigravity');
    expect(gemini.defaultLocalConcurrency, 1);
    expect(gemini.requiredLocalPermissions,
        ['workstream_filesystem', 'shell_execution']);
    expect(gemini.probeStrategy.id, 'antigravity_headless_execution');
    expect(gemini.probeStrategy.authenticationArguments, isEmpty);
    expect(gemini.probeStrategy.setupExecutionTestPrompt,
        'Reply with exactly the word OK. Do not use tools.');
    expect(
      FirstPartyWorkerAdapterDescriptor.canonicalProductWorkerTypeId('codex'),
      'chatgpt',
    );
    expect(
      FirstPartyWorkerAdapterDescriptor.canonicalProductWorkerTypeId(
          'antigravity'),
      'gemini',
    );
    expect(
      FirstPartyWorkerAdapterDescriptor.adapterPackageIdFor('chatgpt'),
      'codex',
    );
    expect(
      FirstPartyWorkerAdapterDescriptor.adapterPackageIdFor('gemini'),
      'antigravity',
    );
  });

  test('CLI authentication is reflected without storing provider credentials',
      () async {
    final type = FirstPartyWorkerAdapterDescriptor.all.first;
    final worker = await LocalWorkerSetupService(registry: registry).create(
      type: type,
      permissions: type.requiredLocalPermissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: false,
    );
    expect(worker.workerTypeId, 'chatgpt');
    expect(worker.localConcurrencyLimit, type.defaultLocalConcurrency);
    expect(worker.status, LocalWorkerStatus.needsAttention);
    expect(worker.credentialStatus,
        LocalWorkerCredentialStatus.needsAuthentication);
    expect(worker.credentialRef, isNull);
    final file = File(
        '${directory.path}${Platform.pathSeparator}configured-workers.json');
    expect(jsonDecode(await file.readAsString())['workers'], hasLength(1));
  });

  test('ready CLI worker can be updated and local permissions require step-up',
      () async {
    final type = FirstPartyWorkerAdapterDescriptor.all.first;
    final service = LocalWorkerSetupService(
      registry: registry,
      requireStepUp: (_) async => true,
    );
    final created = await service.create(
      type: type,
      permissions: type.requiredLocalPermissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    expect(created.status, LocalWorkerStatus.ready);
    final updated = await service.update(
      current: created,
      type: type,
      permissions: const ['workstream_filesystem'],
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    expect(updated.name, 'ChatGPT');
    expect(updated.defaultModel, isNull);
    expect(updated.allowedModels, isEmpty);
    expect(updated.status, LocalWorkerStatus.needsAttention);
  });

  test('descriptor registry excludes non-v1 product Worker Types', () {
    expect(
      FirstPartyWorkerAdapterDescriptor.forProductWorkerTypeId('claude-code'),
      isNull,
    );
    expect(
      FirstPartyWorkerAdapterDescriptor.forAdapterPackageId('claude-code'),
      isNull,
    );
  });
}

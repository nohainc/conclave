import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/configured_worker_registry.dart';
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
      LocalWorkerTypeOption.supported.map((type) => type.id).toList(),
      ['chatgpt', 'gemini'],
    );
    expect(
      LocalWorkerTypeOption.supported.map((type) => type.name).toList(),
      ['ChatGPT', 'Gemini'],
    );
    expect(
      LocalWorkerTypeOption.supported
          .map((type) => type.executablePrerequisite!.executable)
          .toList(),
      ['codex', 'agy'],
    );
    final gemini = LocalWorkerTypeOption.supported.last;
    expect(gemini.executablePrerequisite!.minimumVersion, isNull);
    expect(gemini.executablePrerequisite!.maximumVersion, isNull);
  });

  test('CLI authentication is reflected without storing provider credentials',
      () async {
    final type = LocalWorkerTypeOption.supported.first;
    final worker = await LocalWorkerSetupService(registry: registry).create(
      type: type,
      permissions: type.permissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: false,
    );
    expect(worker.workerTypeId, 'chatgpt');
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
    final type = LocalWorkerTypeOption.supported.first;
    final service = LocalWorkerSetupService(
      registry: registry,
      requireStepUp: (_) async => true,
    );
    final created = await service.create(
      type: type,
      permissions: type.permissions,
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

  test('legacy Worker types cannot be configured through the v1 setup service',
      () async {
    const retiredType = LocalWorkerTypeOption(
      id: 'claude-code',
      adapterId: 'claude-code',
      name: 'Claude Code',
      description: 'legacy test type',
      authStrategy: 'browser_auth',
      prerequisite: 'legacy',
      permissions: ['workstream_filesystem'],
    );
    await expectLater(
      LocalWorkerSetupService(registry: registry).create(
        type: retiredType,
        permissions: retiredType.permissions,
        adapterReady: true,
        prerequisiteReady: true,
        authenticationReady: true,
      ),
      throwsArgumentError,
    );
    expect(await registry.list(), isEmpty);
  });
}

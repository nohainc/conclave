import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/adapter_prerequisite.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/local_worker_setup.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/secure_credentials.dart';

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

class _MemoryCredentialStore implements SecureCredentialStore {
  final values = <String, String>{};

  @override
  String? readSync(String key) => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late Directory directory;
  late LocalConfiguredWorkerRegistry registry;
  late _MemoryCredentialStore credentials;
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
    credentials = _MemoryCredentialStore();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
      'stores API credentials securely and keeps unvalidated Workers in Needs attention',
      () async {
    final worker = await LocalWorkerSetupService(
      registry: registry,
      credentialStore: credentials,
    ).create(
      type: LocalWorkerTypeOption.supported[3],
      name: 'API Work',
      apiKey: 'private-key-value',
      defaultModel: 'model-a',
      endpointUrl: '',
      allowedModels: const ['model-a'],
      permissions: const ['network_openai'],
      adapterReady: false,
      prerequisiteReady: false,
    );
    expect(worker.workerTypeId, 'openai-api');
    expect(worker.status, LocalWorkerStatus.needsAttention);
    expect(worker.credentialStatus,
        LocalWorkerCredentialStatus.needsAuthentication);
    expect(worker.credentialRef, 'worker-credential/worker-1');
    expect(credentials.values[worker.credentialRef], 'private-key-value');
    final file = File(
        '${directory.path}${Platform.pathSeparator}configured-workers.json');
    expect(await file.readAsString(), isNot(contains('private-key-value')));
    expect(jsonDecode(await file.readAsString())['workers'], hasLength(1));
  });

  test('API Worker rejects an insecure remote endpoint', () async {
    await expectLater(
      LocalWorkerSetupService(
        registry: registry,
        credentialStore: credentials,
      ).create(
        type: LocalWorkerTypeOption.supported[3],
        name: 'Insecure API Worker',
        apiKey: 'private-key-value',
        defaultModel: 'model-a',
        endpointUrl: 'http://api.example.test/v1',
        allowedModels: const ['model-a'],
        permissions: const ['network_openai'],
        adapterReady: true,
        prerequisiteReady: true,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await registry.list(), isEmpty);
    expect(credentials.values, isEmpty);
  });

  test('API Worker requires a default or allow-listed model', () async {
    await expectLater(
      LocalWorkerSetupService(
        registry: registry,
        credentialStore: credentials,
      ).create(
        type: LocalWorkerTypeOption.supported[3],
        name: 'No Model API Worker',
        apiKey: 'private-key-value',
        defaultModel: '',
        endpointUrl: '',
        allowedModels: const [],
        permissions: const ['network_openai'],
        adapterReady: true,
        prerequisiteReady: true,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(await registry.list(), isEmpty);
    expect(credentials.values, isEmpty);
  });

  test('Ollama requires a validated local endpoint before it can be Ready',
      () async {
    final worker = await LocalWorkerSetupService(
      registry: registry,
      credentialStore: credentials,
    ).create(
      type: LocalWorkerTypeOption.supported[6],
      name: 'Local Ollama',
      apiKey: '',
      defaultModel: 'qwen-local',
      endpointUrl: 'http://localhost:11434',
      allowedModels: const ['qwen-local'],
      permissions: LocalWorkerTypeOption.supported[6].permissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    expect(worker.status, LocalWorkerStatus.ready);
    expect(worker.credentialStatus, LocalWorkerCredentialStatus.notRequired);
    expect(worker.adapterConfig['endpointUrl'], 'http://localhost:11434');
  });

  test('Codex readiness uses local CLI authentication and retains it on edit',
      () async {
    final service = LocalWorkerSetupService(
      registry: registry,
      credentialStore: credentials,
    );
    final created = await service.create(
      type: LocalWorkerTypeOption.supported.first,
      name: 'Codex Personal',
      apiKey: '',
      defaultModel: 'gpt-5-codex',
      endpointUrl: '',
      allowedModels: const [],
      permissions: LocalWorkerTypeOption.supported.first.permissions,
      adapterReady: false,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    expect(created.status, LocalWorkerStatus.needsAttention);
    expect(created.credentialStatus, LocalWorkerCredentialStatus.ready);
    final completed = await service.update(
      current: created,
      type: LocalWorkerTypeOption.supported.first,
      name: created.name,
      apiKey: '',
      defaultModel: created.defaultModel ?? '',
      endpointUrl: '',
      allowedModels: const [],
      permissions: LocalWorkerTypeOption.supported.first.permissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    expect(completed.status, LocalWorkerStatus.ready);
    expect(completed.credentialStatus, LocalWorkerCredentialStatus.ready);
  });

  test('edits configuration while retaining or rotating secure credentials',
      () async {
    final service = LocalWorkerSetupService(
      registry: registry,
      credentialStore: credentials,
    );
    final created = await service.create(
      type: LocalWorkerTypeOption.supported[3],
      name: 'API Work',
      apiKey: 'old-secret',
      defaultModel: 'model-a',
      endpointUrl: '',
      allowedModels: const ['model-a'],
      permissions: LocalWorkerTypeOption.supported[3].permissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    final retained = await service.update(
      current: created,
      type: LocalWorkerTypeOption.supported[3],
      name: 'API Work Updated',
      apiKey: '',
      defaultModel: 'model-b',
      endpointUrl: '',
      allowedModels: const ['model-b'],
      permissions: LocalWorkerTypeOption.supported[3].permissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    expect(retained.defaultModel, 'model-b');
    expect(retained.credentialRef, created.credentialRef);
    expect(credentials.values[created.credentialRef], 'old-secret');

    final rotated = await service.update(
      current: retained,
      type: LocalWorkerTypeOption.supported[3],
      name: 'API Work Updated',
      apiKey: 'new-secret',
      defaultModel: 'model-b',
      endpointUrl: '',
      allowedModels: const ['model-b'],
      permissions: LocalWorkerTypeOption.supported[3].permissions,
      adapterReady: true,
      prerequisiteReady: true,
      authenticationReady: true,
    );
    expect(rotated.credentialRef, created.credentialRef);
    expect(credentials.values[rotated.credentialRef], 'new-secret');
    expect(credentials.values.containsKey(created.credentialRef), isTrue);
    expect(rotated.status, LocalWorkerStatus.ready);

    final duplicate = await service.create(
      type: LocalWorkerTypeOption.supported[6],
      name: 'Taken Name',
      apiKey: '',
      defaultModel: 'local-model',
      endpointUrl: 'http://localhost:11434',
      allowedModels: const [],
      permissions: LocalWorkerTypeOption.supported[6].permissions,
      adapterReady: true,
      prerequisiteReady: true,
    );
    await expectLater(
      service.update(
        current: rotated,
        type: LocalWorkerTypeOption.supported[3],
        name: duplicate.name,
        apiKey: 'failed-rotation',
        defaultModel: 'model-b',
        endpointUrl: '',
        allowedModels: const ['model-b'],
        permissions: LocalWorkerTypeOption.supported[3].permissions,
        adapterReady: true,
        prerequisiteReady: true,
      ),
      throwsArgumentError,
    );
    expect(credentials.values[rotated.credentialRef], 'new-secret');
    expect((await registry.list()).first.name, 'API Work Updated');
  });

  testWidgets('offers the v7 integration types in the local Add Worker dialog',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AddLocalWorkerDialog(
                      registry: registry,
                      credentialStore: credentials,
                      adapterAvailable: (_, __) => false,
                      probePrerequisite: (_) async =>
                          const AdapterPrerequisiteResult(
                        satisfied: false,
                        message: 'not installed',
                      ),
                    ),
                  ),
                  child: const Text('Start'),
                ),
              )),
    ));
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('worker-type-selector')));
    await tester.pumpAndSettle();
    for (final type in LocalWorkerTypeOption.supported) {
      expect(find.text(type.name), findsWidgets);
    }
  });
}

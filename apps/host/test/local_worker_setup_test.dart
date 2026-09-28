import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/adapter_prerequisite.dart';
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
    expect(gemini.executablePrerequisite!.minimumVersion, '1.1.8');
    expect(gemini.executablePrerequisite!.maximumVersion, '1.2.11');
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
      authLabel: 'legacy',
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

  testWidgets('Worker setup dialog is fixed to its v1 catalog entry',
      (tester) async {
    var prerequisiteChecks = 0;
    var codexLoginOpens = 0;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AddLocalWorkerDialog(
                registry: registry,
                type: LocalWorkerTypeOption.supported.first,
                adapterAvailable: (_, __) => false,
                probePrerequisites: (_) async {
                  prerequisiteChecks++;
                  return const [
                    AdapterPrerequisiteResult(
                      satisfied: true,
                      message: 'installed',
                      detectedVersion: '0.158.0',
                    ),
                    AdapterPrerequisiteResult(
                      satisfied: true,
                      message: 'installed',
                      detectedVersion: '22.0.0',
                    ),
                  ];
                },
                validateAuthentication: (_) async => false,
                launchAuthentication: (_) async {
                  codexLoginOpens++;
                },
              ),
            ),
            child: const Text('Start'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Set up ChatGPT'), findsOneWidget);
    expect(find.byKey(const Key('worker-type-selector')), findsNothing);
    expect(find.text('Open Codex Login'), findsOneWidget);
    expect(find.text('Codex CLI'), findsNWidgets(2));
    expect(find.text('Codex authentication'), findsOneWidget);
    expect(find.text('Login required'), findsOneWidget);
    expect(find.text('Verified adapter'), findsOneWidget);
    expect(find.text('Not installed or unverified'), findsOneWidget);
    expect(prerequisiteChecks, 1);
    await tester.ensureVisible(find.text('Check again'));
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(prerequisiteChecks, 2);
    await tester.ensureVisible(find.text('Open Codex Login'));
    await tester.tap(find.text('Open Codex Login'));
    await tester.pumpAndSettle();
    expect(codexLoginOpens, 1);
    expect(find.textContaining('Complete sign-in in Codex'), findsOneWidget);
    for (final retired in [
      'Claude Code',
      'OpenAI API',
      'Gemini API',
      'Anthropic API',
      'Ollama',
    ]) {
      expect(find.text(retired), findsNothing);
    }
    expect(find.byKey(const Key('worker-api-key')), findsNothing);
    expect(find.byKey(const Key('worker-name')), findsNothing);
    expect(find.byKey(const Key('worker-default-model')), findsNothing);
    expect(find.byKey(const Key('worker-allowed-models')), findsNothing);
    expect(find.text('Discover available models'), findsNothing);
  });

  testWidgets('Gemini setup launches Antigravity and exposes rechecks',
      (tester) async {
    var checks = 0;
    var opens = 0;
    final gemini = LocalWorkerTypeOption.supported.last;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AddLocalWorkerDialog(
                registry: registry,
                type: gemini,
                adapterAvailable: (_, __) async => true,
                probePrerequisites: (_) async {
                  checks++;
                  return const [
                    AdapterPrerequisiteResult(
                      satisfied: true,
                      message: 'Antigravity CLI is within the supported range.',
                      detectedVersion: '1.2.11',
                    ),
                    AdapterPrerequisiteResult(
                      satisfied: true,
                      message: 'Node.js is installed.',
                      detectedVersion: '22.0.0',
                    ),
                  ];
                },
                validateAuthentication: (_) async => true,
                launchAuthentication: (_) async {
                  opens++;
                },
              ),
            ),
            child: const Text('Start Gemini setup'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Start Gemini setup'));
    await tester.pumpAndSettle();
    expect(find.text('Set up Gemini'), findsOneWidget);
    expect(find.text('Antigravity authentication'), findsOneWidget);
    expect(find.textContaining('1.2.11'), findsOneWidget);
    expect(find.text('Open Antigravity'), findsOneWidget);
    expect(checks, 1);
    await tester.ensureVisible(find.text('Check again'));
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(checks, 2);
    await tester.ensureVisible(find.text('Open Antigravity'));
    await tester.tap(find.text('Open Antigravity'));
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(find.textContaining('Antigravity opened'), findsOneWidget);
    expect(find.byKey(const Key('worker-api-key')), findsNothing);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_trust_policy.dart';

void main() {
  test('packages and installs the first-party Codex manifest template',
      () async {
    final output = await Directory.systemTemp.createTemp('codex-release-test-');
    addTearDown(() => output.delete(recursive: true));
    final archive = File('${output.path}/codex.tgz');
    const publisher = 'conclave';
    const signingSecret = 'test-only-v7-release-key';

    final packaged = await Process.run(
      'dart',
      [
        'run',
        'bin/package_v7_adapter.dart',
        '--source',
        '../../packages/worker-manifest/adapters/codex',
        '--output',
        archive.path,
      ],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'CONCLAVE_WORKER_TRUST_PUBLISHER': publisher,
        'CONCLAVE_WORKER_TRUST_SECRET': signingSecret,
      },
    );
    expect(packaged.exitCode, 0, reason: packaged.stderr.toString());
    expect(await archive.exists(), isTrue);

    final manifestFile = File('${archive.path}.manifest.json');
    final manifest = Map<String, Object?>.from(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    expect(manifest['workerTypeId'], 'codex');
    expect(manifest['packageDigest'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(manifest['signature'], isNotEmpty);

    final store = V7AdapterPackageStore(
      root: Directory('${output.path}/store'),
      trustPolicy: WorkerTrustPolicy(
        trustedSecrets: {publisher: signingSecret},
      ),
      allowedPermissions: WorkerPermission.values.toSet(),
      platform: '${Platform.isMacOS ? 'macos' : 'linux'}-'
          '${Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64'}',
    );
    final installed = await store.installArchive(
      archiveBytes: await archive.readAsBytes(),
      expectedManifest: manifest,
    );
    expect(await File('${installed.path}/manifest.json').exists(), isTrue);
    final active = jsonDecode(
        await File('${output.path}/store/codex/active.json').readAsString());
    expect((active as Map)['version'], '1.0.0');
  });

  test('packages and installs the first-party Antigravity manifest template',
      () async {
    final output =
        await Directory.systemTemp.createTemp('antigravity-release-test-');
    addTearDown(() => output.delete(recursive: true));
    final archive = File('${output.path}/antigravity.tgz');
    const publisher = 'conclave';
    const signingSecret = 'test-only-v7-release-key';

    final packaged = await Process.run(
      'dart',
      [
        'run',
        'bin/package_v7_adapter.dart',
        '--source',
        '../../packages/worker-manifest/adapters/antigravity',
        '--output',
        archive.path,
      ],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'CONCLAVE_WORKER_TRUST_PUBLISHER': publisher,
        'CONCLAVE_WORKER_TRUST_SECRET': signingSecret,
      },
    );
    expect(packaged.exitCode, 0, reason: packaged.stderr.toString());
    expect(await archive.exists(), isTrue);

    final manifestFile = File('${archive.path}.manifest.json');
    final manifest = Map<String, Object?>.from(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    expect(manifest['workerTypeId'], 'antigravity');
    expect(manifest['packageDigest'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(manifest['signature'], isNotEmpty);

    final store = V7AdapterPackageStore(
      root: Directory('${output.path}/store'),
      trustPolicy: WorkerTrustPolicy(
        trustedSecrets: {publisher: signingSecret},
      ),
      allowedPermissions: WorkerPermission.values.toSet(),
      platform: '${Platform.isMacOS ? 'macos' : 'linux'}-'
          '${Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64'}',
    );
    final installed = await store.installArchive(
      archiveBytes: await archive.readAsBytes(),
      expectedManifest: manifest,
    );
    expect(await File('${installed.path}/manifest.json').exists(), isTrue);
    final active = jsonDecode(await File(
            '${output.path}/store/antigravity/active.json')
        .readAsString());
    expect((active as Map)['version'], '1.0.0');
  });

  test('packages and installs the three V7 API adapters', () async {
    final output = await Directory.systemTemp.createTemp('api-releases-test-');
    addTearDown(() => output.delete(recursive: true));
    const publisher = 'conclave';
    const signingSecret = 'test-only-v7-api-release-key';
    final platform = '${Platform.isMacOS ? 'macos' : 'linux'}-'
        '${Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64'}';
    final store = V7AdapterPackageStore(
      root: Directory('${output.path}/store'),
      trustPolicy: WorkerTrustPolicy(
        trustedSecrets: {publisher: signingSecret},
      ),
      allowedPermissions: WorkerPermission.values.toSet(),
      platform: platform,
    );

    for (final workerTypeId in [
      'openai-api',
      'gemini-api',
      'anthropic-api',
    ]) {
      final archive = File('${output.path}/$workerTypeId.tgz');
      final packaged = await Process.run(
        'dart',
        [
          'run',
          'bin/package_v7_adapter.dart',
          '--source',
          '../../packages/worker-manifest/adapters/$workerTypeId',
          '--output',
          archive.path,
        ],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'CONCLAVE_WORKER_TRUST_PUBLISHER': publisher,
          'CONCLAVE_WORKER_TRUST_SECRET': signingSecret,
        },
      );
      expect(packaged.exitCode, 0, reason: packaged.stderr.toString());
      final manifest = Map<String, Object?>.from(
        jsonDecode(await File('${archive.path}.manifest.json').readAsString())
            as Map,
      );
      expect(manifest['workerTypeId'], workerTypeId);
      expect(manifest['permissions'], hasLength(1));
      expect(manifest['secretRequirements'], hasLength(1));
      final installed = await store.installArchive(
        archiveBytes: await archive.readAsBytes(),
        expectedManifest: manifest,
      );
      expect(await File('${installed.path}/lib/api_protocol.mjs').exists(),
          isTrue);
      final now = DateTime.now().toUtc().toIso8601String();
      final worker = LocalConfiguredWorker(
        id: 'worker-$workerTypeId',
        workspaceId: 'workspace-1',
        name: workerTypeId,
        workerTypeId: workerTypeId,
        authStrategy: 'api_key',
        credentialRef: 'worker-credential/$workerTypeId',
        defaultModel: 'model-test',
        adapterConfig: const {},
        allowedModels: const [],
        localPermissions: [
          switch (workerTypeId) {
            'openai-api' => 'network_openai',
            'gemini-api' => 'network_google',
            _ => 'network_anthropic',
          },
        ],
        localConcurrencyLimit: 1,
        adapterVersionPolicy: 'stable',
        status: LocalWorkerStatus.ready,
        credentialStatus: LocalWorkerCredentialStatus.ready,
        revision: 1,
        createdAt: now,
        updatedAt: now,
      );
      final summary = await store.activeManifestSummary(worker);
      expect(summary?['adapterVersion'], '1.0.0');
      expect(summary?['capabilities'], ['text_generation']);
      final active = jsonDecode(
          await File('${output.path}/store/$workerTypeId/active.json')
              .readAsString());
      expect((active as Map)['version'], '1.0.0');
    }
  });
}

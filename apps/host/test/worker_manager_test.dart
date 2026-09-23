import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/worker_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:test/test.dart';

void main() {
  test('verifies, installs, and rolls back side-by-side worker versions',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final bytes = [1, 2, 3];
    final manager = WorkerManager(directory);
    await manager.install(WorkerPackage(
      id: 'echo',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));
    await manager.install(WorkerPackage(
      id: 'echo',
      version: '2.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));
    expect(await manager.activeVersion('echo'), '2.0.0');
    expect((await manager.activeProcessSpec('echo'))!.workingDirectory,
        endsWith('/echo/2.0.0'));
    await manager.rollback('echo', '1.0.0');
    expect(await manager.activeVersion('echo'), '1.0.0');
    await manager.rollback('echo', '2.0.0');
    final inventory = await manager.inventory();
    expect(inventory, hasLength(2));
    expect(inventory.singleWhere((worker) => worker.active).version, '2.0.0');
    await manager.remove('echo', '1.0.0');
    expect((await manager.inventory()).map((worker) => worker.version),
        contains('2.0.0'));
    await expectLater(
        manager.remove('echo', '2.0.0'), throwsA(isA<StateError>()));
    await directory.delete(recursive: true);
  });

  test('rejects a package with a bad digest', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory);
    expect(
      () => manager.install(const WorkerPackage(
        id: 'bad',
        version: '1.0.0',
        bytes: [1],
        digest: 'nope',
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('secure managers reject unsigned packages', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-secure-');
    final bytes = [5, 6, 7];
    await expectLater(
      WorkerManager(directory, requireSignature: true).install(WorkerPackage(
        id: 'unsigned',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
      )),
      throwsA(predicate((error) => error
          .toString()
          .contains('signature verification is not configured'))),
    );
    await directory.delete(recursive: true);
  });

  test('does not overwrite an installed version with a different payload',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory);
    final firstBytes = [31, 32, 33];
    final secondBytes = [34, 35, 36];
    await manager.install(WorkerPackage(
      id: 'immutable',
      version: '1.0.0',
      bytes: firstBytes,
      digest: sha256.convert(firstBytes).toString(),
    ));

    await expectLater(
      manager.install(WorkerPackage(
        id: 'immutable',
        version: '1.0.0',
        bytes: secondBytes,
        digest: sha256.convert(secondBytes).toString(),
      )),
      throwsA(isA<StateError>()),
    );
    expect(
      await File('${directory.path}/immutable/1.0.0/package.bin').readAsBytes(),
      firstBytes,
    );
    expect(
      (await directory
              .list(recursive: true, followLinks: false)
              .where((entity) => entity.path.contains('.staging-'))
              .toList())
          .isEmpty,
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  test('accepts a repeated install of the same immutable payload', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory);
    final bytes = [37, 38, 39];
    final package = WorkerPackage(
      id: 'repeatable',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    );
    final first = await manager.install(package);
    final second = await manager.install(package);
    expect(second.path, first.path);
    expect(await manager.activeVersion('repeatable'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('rejects worker path traversal identifiers', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory);
    final bytes = [40];
    await expectLater(
      manager.install(WorkerPackage(
        id: '../outside',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('enforces permissions even without a signing policy', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory);
    final bytes = [7, 8, 9];
    final digest = sha256.convert(bytes).toString();

    await expectLater(
      manager.install(WorkerPackage(
        id: 'shell-worker',
        version: '1.0.0',
        bytes: bytes,
        digest: digest,
        permissions: const [WorkerPermission.shell],
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('requires a trust policy when revalidating an active worker', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final bytes = [12, 13, 14];
    final digest = sha256.convert(bytes).toString();
    await WorkerManager(directory).install(WorkerPackage(
      id: 'unsigned-active',
      version: '1.0.0',
      bytes: bytes,
      digest: digest,
    ));

    final strictManager = WorkerManager(
      directory,
      requireSignature: true,
    );
    await expectLater(
      strictManager.activeProcessSpec('unsigned-active'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('enforces signature and permissions when trust policy is enabled',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final bytes = [4, 5, 6];
    final digest = sha256.convert(bytes).toString();
    const policy = WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = WorkerManager(directory,
        trustPolicy: policy,
        allowedPermissions: {WorkerPermission.readWorkspace});
    await manager.install(WorkerPackage(
      id: 'trusted',
      version: '1.0.0',
      bytes: bytes,
      digest: digest,
      publisher: 'publisher',
      signature: policy.sign('publisher', digest),
      permissions: [WorkerPermission.readWorkspace],
    ));
    expect(await manager.activeVersion('trusted'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('accepts the Cloud sha256-prefixed digest contract', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-prefixed-');
    final bytes = [7, 8, 9];
    final digest = sha256.convert(bytes).toString();
    final cloudDigest = 'sha256:$digest';
    const policy = WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = WorkerManager(
      directory,
      trustPolicy: policy,
      allowedPermissions: {WorkerPermission.readWorkspace},
    );

    await manager.install(WorkerPackage(
      id: 'cloud-published',
      version: '1.0.0',
      bytes: bytes,
      digest: cloudDigest,
      publisher: 'publisher',
      signature: policy.sign('publisher', cloudDigest),
      permissions: [WorkerPermission.readWorkspace],
    ));

    expect(await manager.activeVersion('cloud-published'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('does not activate a revoked version during rollback', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-worker-rollback-');
    final bytesV1 = [10, 11, 12];
    final bytesV2 = [13, 14, 15];
    final digestV1 = sha256.convert(bytesV1).toString();
    final digestV2 = sha256.convert(bytesV2).toString();
    const trusted = WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = WorkerManager(
      directory,
      trustPolicy: trusted,
      allowedPermissions: {WorkerPermission.readWorkspace},
    );
    await manager.install(WorkerPackage(
      id: 'rollback-safe',
      version: '1.0.0',
      bytes: bytesV1,
      digest: digestV1,
      publisher: 'publisher',
      signature: trusted.sign('publisher', digestV1),
      permissions: const [WorkerPermission.readWorkspace],
    ));
    await manager.install(WorkerPackage(
      id: 'rollback-safe',
      version: '2.0.0',
      bytes: bytesV2,
      digest: digestV2,
      publisher: 'publisher',
      signature: trusted.sign('publisher', digestV2),
      permissions: const [WorkerPermission.readWorkspace],
    ));

    final revoked = WorkerManager(
      directory,
      trustPolicy: WorkerTrustPolicy(
        trustedSecrets: const {'publisher': 'root'},
        revokedDigests: {digestV1},
      ),
      allowedPermissions: {WorkerPermission.readWorkspace},
    );
    await expectLater(
      revoked.rollback('rollback-safe', '1.0.0'),
      throwsA(isA<StateError>()),
    );
    expect(await revoked.activeVersion('rollback-safe'), '2.0.0');

    await directory.delete(recursive: true);
  });

  test('reconciles signed desired workers from Cloud', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final bytes = [30, 31, 32];
    final digest = sha256.convert(bytes).toString();
    const policy = WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = WorkerManager(
      directory,
      trustPolicy: policy,
      allowedPermissions: {WorkerPermission.readWorkspace},
    );
    final states = <String>[];
    await manager.reconcile(
      [
        {
          'workerId': 'cloud-worker',
          'version': '1.0.0',
          'publisher': 'publisher',
          'packageR2Key': 'workers/cloud-worker/1.0.0/package.bin',
          'packageDigest': digest,
          'signature': policy.sign('publisher', digest),
          'permissions': ['workspace:read'],
        },
      ],
      download: (workerId, version, packageR2Key) async {
        expect(workerId, 'cloud-worker');
        expect(version, '1.0.0');
        expect(packageR2Key, contains('cloud-worker'));
        return bytes;
      },
      onStatus: (status) async {
        states.add(status['status']! as String);
      },
    );
    expect(await manager.activeVersion('cloud-worker'), '1.0.0');
    expect(
      states,
      containsAll(<String>[
        'requested',
        'downloading',
        'verifying',
        'installing',
        'ready',
      ]),
    );
    await directory.delete(recursive: true);
  });

  test('deduplicates one Worker installation shared by two users', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-shared-');
    final bytes = [71, 72, 73];
    final digest = sha256.convert(bytes).toString();
    const policy = WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = WorkerManager(
      directory,
      trustPolicy: policy,
      allowedPermissions: {WorkerPermission.readWorkspace},
    );
    var downloads = 0;
    final desired = [
      {
        'workerId': 'shared-worker',
        'version': '1.0.0',
        'publisher': 'publisher',
        'packageR2Key': 'workers/shared-worker/1.0.0/package.bin',
        'packageDigest': digest,
        'signature': policy.sign('publisher', digest),
        'permissions': ['workspace:read'],
      },
      {
        'workerId': 'shared-worker',
        'version': '1.0.0',
        'publisher': 'publisher',
        'packageR2Key': 'workers/shared-worker/1.0.0/package.bin',
        'packageDigest': digest,
        'signature': policy.sign('publisher', digest),
        'permissions': ['workspace:read'],
      },
    ];
    await manager.reconcile(
      desired,
      download: (_, __, ___) async {
        downloads++;
        return bytes;
      },
    );
    expect(downloads, 1);
    expect((await manager.inventory()).where((worker) => worker.active),
        hasLength(1));
    await directory.delete(recursive: true);
  });

  test('cleans an interrupted or unhealthy installation staging target',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-interrupted-');
    final manager = WorkerManager(directory);
    final digest = sha256.convert(const <int>[]).toString();
    await expectLater(
      manager.install(WorkerPackage(
        id: 'empty-worker',
        version: '1.0.0',
        bytes: const [],
        digest: digest,
      )),
      throwsA(isA<StateError>()),
    );
    expect(await Directory('${directory.path}/empty-worker/1.0.0').exists(),
        isFalse);
    expect(
      (await directory
              .list(recursive: true, followLinks: false)
              .where((entity) => entity.path.contains('.staging-'))
              .toList())
          .isEmpty,
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  test('rejects an invalid Worker signature', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-signature-');
    final bytes = [81, 82, 83];
    final digest = sha256.convert(bytes).toString();
    const policy = WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    await expectLater(
      WorkerManager(
        directory,
        trustPolicy: policy,
        allowedPermissions: {WorkerPermission.readWorkspace},
      ).install(WorkerPackage(
        id: 'invalid-signature',
        version: '1.0.0',
        bytes: bytes,
        digest: digest,
        publisher: 'publisher',
        signature: 'not-a-valid-signature',
        permissions: [WorkerPermission.readWorkspace],
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('deactivates workers removed from Cloud desired state', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-worker-revoke-');
    final manager = WorkerManager(directory);
    final bytes = [51, 52, 53];
    await manager.install(WorkerPackage(
      id: 'removed-worker',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));

    final states = <String>[];
    await manager.reconcile(
      const [],
      download: (_, __, ___) async => const [],
      onStatus: (status) async {
        states.add(status['status']! as String);
      },
    );

    expect(await manager.activeVersion('removed-worker'), isNull);
    expect(await manager.activeProcessSpec('removed-worker'), isNull);
    expect(states, containsAll(<String>['removing', 'absent']));
    await directory.delete(recursive: true);
  });

  test('accepts canonical cross-language permission names', () {
    expect(parseWorkerPermission('workspace:read'),
        WorkerPermission.readWorkspace);
    expect(parseWorkerPermission('network:outbound'), WorkerPermission.network);
    expect(WorkerPermission.writeWorkspace.wireName, 'workspace:write');
    expect(parseWorkerPermission('network:openai'),
        WorkerPermission.networkOpenAi);
    expect(parseWorkerPermission('network:anthropic'),
        WorkerPermission.networkAnthropic);
    expect(WorkerPermission.networkOpenAi.wireName, 'network:openai');
  });

  test('injects only manifest-declared secrets into a verified worker',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-worker-secrets-');
    final bytes = [61, 62, 63];
    const manifest = WorkerManifest(
      workerId: 'secret-worker',
      version: '1.0.0',
      protocolVersion: '4.0',
      engineVersion: '>=0.1.0',
      executable: 'package.bin',
      permissions: [WorkerPermission.credentials],
      secretEnvironmentVariables: ['OPENAI_API_KEY'],
    );
    final manager = WorkerManager(
      directory,
      allowedPermissions: {WorkerPermission.credentials},
      secretEnvironment: const {
        'OPENAI_API_KEY': 'key-value',
        'UNDECLARED_SECRET': 'must-not-appear',
      },
    );
    await manager.install(WorkerPackage(
      id: 'secret-worker',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
      manifest: manifest,
    ));
    final spec = await manager.activeProcessSpec('secret-worker');
    expect(spec?.environment, {'OPENAI_API_KEY': 'key-value'});
    expect(spec?.allowedEnvironmentVariables, {'OPENAI_API_KEY'});
    await directory.delete(recursive: true);
  });

  test('rejects secret declarations without credential permission', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-worker-secrets-');
    final bytes = [64, 65, 66];
    await expectLater(
      WorkerManager(directory).install(WorkerPackage(
        id: 'unapproved-secret-worker',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
        manifest: const WorkerManifest(
          workerId: 'unapproved-secret-worker',
          version: '1.0.0',
          protocolVersion: '4.0',
          engineVersion: '>=0.1.0',
          executable: 'package.bin',
          secretEnvironmentVariables: ['OPENAI_API_KEY'],
        ),
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('reconciles a scoped API network permission', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-network-');
    final bytes = [41, 42, 43];
    final digest = sha256.convert(bytes).toString();
    const policy = WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = WorkerManager(
      directory,
      trustPolicy: policy,
      allowedPermissions: {WorkerPermission.networkOpenAi},
    );
    await manager.reconcile(
      [
        {
          'workerId': 'openai-worker',
          'version': '1.0.0',
          'publisher': 'publisher',
          'packageR2Key': 'workers/openai/1.0.0/package.bin',
          'packageDigest': digest,
          'signature': policy.sign('publisher', digest),
          'permissions': ['network:openai'],
        },
      ],
      download: (_, __, ___) async => bytes,
    );
    expect(await manager.activeVersion('openai-worker'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('rejects traversal identifiers before checking the active version',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory);
    var downloaded = false;
    await expectLater(
      manager.reconcile(
        [
          {
            'workerId': '../outside',
            'version': '1.0.0',
            'publisher': 'publisher',
            'packageR2Key': 'workers/outside/1.0.0/package.bin',
            'packageDigest': 'digest',
            'signature': 'signature',
            'permissions': <String>[],
          },
        ],
        download: (_, __, ___) async {
          downloaded = true;
          return const [1];
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(downloaded, isFalse);
    await directory.delete(recursive: true);
  });

  test('rechecks signing revocation before launching an installed worker',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final bytes = [19, 20, 21];
    final digest = sha256.convert(bytes).toString();
    const installPolicy =
        WorkerTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = WorkerManager(
      directory,
      trustPolicy: installPolicy,
      allowedPermissions: {WorkerPermission.readWorkspace},
    );
    await manager.install(WorkerPackage(
      id: 'revocable',
      version: '1.0.0',
      bytes: bytes,
      digest: digest,
      publisher: 'publisher',
      signature: installPolicy.sign('publisher', digest),
      permissions: [WorkerPermission.readWorkspace],
    ));

    final revokedManager = WorkerManager(
      directory,
      trustPolicy: WorkerTrustPolicy(
        trustedSecrets: const {'publisher': 'root'},
        revokedDigests: {digest},
      ),
      allowedPermissions: {WorkerPermission.readWorkspace},
    );
    await expectLater(
      revokedManager.activeProcessSpec('revocable'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects a worker that does not support the Host platform', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory, platformKey: 'linux-x64');
    final bytes = [7, 8, 9];
    await expectLater(
      manager.install(WorkerPackage(
        id: 'mac-only',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
        manifest: const WorkerManifest(
          workerId: 'mac-only',
          version: '1.0.0',
          protocolVersion: '4.0',
          engineVersion: '>=0.1.0',
          executable: 'package.bin',
          supportedPlatforms: ['macos-arm64'],
        ),
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects incompatible protocol and engine versions', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory, engineVersion: '0.1.0');
    final bytes = [10, 11, 12];
    expect(
      () => manager.install(WorkerPackage(
        id: 'future',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
        manifest: const WorkerManifest(
          workerId: 'future',
          version: '1.0.0',
          protocolVersion: '9.0',
          engineVersion: '>=9.0.0',
          executable: 'package.bin',
        ),
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects a package modified after installation', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final bytes = [13, 14, 15];
    final manager = WorkerManager(directory);
    await manager.install(WorkerPackage(
      id: 'tampered',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));

    await File('${directory.path}/tampered/1.0.0/package.bin')
        .writeAsBytes([99], flush: true);
    await expectLater(
      manager.activeProcessSpec('tampered'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects a manifest whose identity was modified', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final bytes = [16, 17, 18];
    final manager = WorkerManager(directory);
    await manager.install(WorkerPackage(
      id: 'identity',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));

    final manifestFile = File(
      '${directory.path}/identity/1.0.0/manifest.json',
    );
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    manifest['workerId'] = 'other-worker';
    await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
    await expectLater(
      manager.activeProcessSpec('identity'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rechecks manifest compatibility before launching', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory, platformKey: 'macos-arm64');
    final bytes = [20, 21, 22];
    await manager.install(WorkerPackage(
      id: 'compatibility',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));

    final manifestFile = File(
      '${directory.path}/compatibility/1.0.0/manifest.json',
    );
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    manifest['protocolVersion'] = 'future';
    await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
    await expectLater(
      manager.activeProcessSpec('compatibility'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects a manifest that redirects execution outside the package',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workers-');
    final manager = WorkerManager(directory);
    final bytes = [17, 18, 19];
    await manager.install(WorkerPackage(
      id: 'redirected',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));
    final manifestFile = File(
      '${directory.path}/redirected/1.0.0/manifest.json',
    );
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    manifest['executable'] = '../../outside';
    await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
    await expectLater(
      manager.activeProcessSpec('redirected'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });
}

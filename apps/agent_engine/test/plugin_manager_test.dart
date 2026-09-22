import 'dart:convert';
import 'dart:io';

import 'package:conclave_agent_engine/plugin_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:conclave_agent_engine/trust_policy.dart';
import 'package:test/test.dart';

void main() {
  test('verifies, installs, and rolls back side-by-side plugin versions',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final bytes = [1, 2, 3];
    final manager = PluginManager(directory);
    await manager.install(PluginPackage(
      id: 'echo',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));
    await manager.install(PluginPackage(
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
    expect(inventory.singleWhere((plugin) => plugin.active).version, '2.0.0');
    await manager.remove('echo', '1.0.0');
    expect((await manager.inventory()).map((plugin) => plugin.version),
        contains('2.0.0'));
    await expectLater(
        manager.remove('echo', '2.0.0'), throwsA(isA<StateError>()));
    await directory.delete(recursive: true);
  });

  test('rejects a package with a bad digest', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory);
    expect(
      () => manager.install(const PluginPackage(
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
        await Directory.systemTemp.createTemp('conclave-plugins-secure-');
    final bytes = [5, 6, 7];
    await expectLater(
      PluginManager(directory, requireSignature: true).install(PluginPackage(
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory);
    final firstBytes = [31, 32, 33];
    final secondBytes = [34, 35, 36];
    await manager.install(PluginPackage(
      id: 'immutable',
      version: '1.0.0',
      bytes: firstBytes,
      digest: sha256.convert(firstBytes).toString(),
    ));

    await expectLater(
      manager.install(PluginPackage(
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory);
    final bytes = [37, 38, 39];
    final package = PluginPackage(
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

  test('rejects plugin path traversal identifiers', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory);
    final bytes = [40];
    await expectLater(
      manager.install(PluginPackage(
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory);
    final bytes = [7, 8, 9];
    final digest = sha256.convert(bytes).toString();

    await expectLater(
      manager.install(PluginPackage(
        id: 'shell-plugin',
        version: '1.0.0',
        bytes: bytes,
        digest: digest,
        permissions: const [PluginPermission.shell],
      )),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('requires a trust policy when revalidating an active plugin', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final bytes = [12, 13, 14];
    final digest = sha256.convert(bytes).toString();
    await PluginManager(directory).install(PluginPackage(
      id: 'unsigned-active',
      version: '1.0.0',
      bytes: bytes,
      digest: digest,
    ));

    final strictManager = PluginManager(
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final bytes = [4, 5, 6];
    final digest = sha256.convert(bytes).toString();
    const policy = PluginTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = PluginManager(directory,
        trustPolicy: policy,
        allowedPermissions: {PluginPermission.readWorkspace});
    await manager.install(PluginPackage(
      id: 'trusted',
      version: '1.0.0',
      bytes: bytes,
      digest: digest,
      publisher: 'publisher',
      signature: policy.sign('publisher', digest),
      permissions: [PluginPermission.readWorkspace],
    ));
    expect(await manager.activeVersion('trusted'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('accepts the Cloud sha256-prefixed digest contract', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-prefixed-');
    final bytes = [7, 8, 9];
    final digest = sha256.convert(bytes).toString();
    final cloudDigest = 'sha256:$digest';
    const policy = PluginTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = PluginManager(
      directory,
      trustPolicy: policy,
      allowedPermissions: {PluginPermission.readWorkspace},
    );

    await manager.install(PluginPackage(
      id: 'cloud-published',
      version: '1.0.0',
      bytes: bytes,
      digest: cloudDigest,
      publisher: 'publisher',
      signature: policy.sign('publisher', cloudDigest),
      permissions: [PluginPermission.readWorkspace],
    ));

    expect(await manager.activeVersion('cloud-published'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('does not activate a revoked version during rollback', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugin-rollback-');
    final bytesV1 = [10, 11, 12];
    final bytesV2 = [13, 14, 15];
    final digestV1 = sha256.convert(bytesV1).toString();
    final digestV2 = sha256.convert(bytesV2).toString();
    const trusted = PluginTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = PluginManager(
      directory,
      trustPolicy: trusted,
      allowedPermissions: {PluginPermission.readWorkspace},
    );
    await manager.install(PluginPackage(
      id: 'rollback-safe',
      version: '1.0.0',
      bytes: bytesV1,
      digest: digestV1,
      publisher: 'publisher',
      signature: trusted.sign('publisher', digestV1),
      permissions: const [PluginPermission.readWorkspace],
    ));
    await manager.install(PluginPackage(
      id: 'rollback-safe',
      version: '2.0.0',
      bytes: bytesV2,
      digest: digestV2,
      publisher: 'publisher',
      signature: trusted.sign('publisher', digestV2),
      permissions: const [PluginPermission.readWorkspace],
    ));

    final revoked = PluginManager(
      directory,
      trustPolicy: PluginTrustPolicy(
        trustedSecrets: const {'publisher': 'root'},
        revokedDigests: {digestV1},
      ),
      allowedPermissions: {PluginPermission.readWorkspace},
    );
    await expectLater(
      revoked.rollback('rollback-safe', '1.0.0'),
      throwsA(isA<StateError>()),
    );
    expect(await revoked.activeVersion('rollback-safe'), '2.0.0');

    await directory.delete(recursive: true);
  });

  test('reconciles signed desired plugins from Cloud', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final bytes = [30, 31, 32];
    final digest = sha256.convert(bytes).toString();
    const policy = PluginTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = PluginManager(
      directory,
      trustPolicy: policy,
      allowedPermissions: {PluginPermission.readWorkspace},
    );
    await manager.reconcile(
      [
        {
          'pluginId': 'cloud-plugin',
          'version': '1.0.0',
          'publisher': 'publisher',
          'packageR2Key': 'plugins/cloud-plugin/1.0.0/package.bin',
          'packageDigest': digest,
          'signature': policy.sign('publisher', digest),
          'permissions': ['workspace:read'],
        },
      ],
      download: (pluginId, version, packageR2Key) async {
        expect(pluginId, 'cloud-plugin');
        expect(version, '1.0.0');
        expect(packageR2Key, contains('cloud-plugin'));
        return bytes;
      },
    );
    expect(await manager.activeVersion('cloud-plugin'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('deactivates plugins removed from Cloud desired state', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugin-revoke-');
    final manager = PluginManager(directory);
    final bytes = [51, 52, 53];
    await manager.install(PluginPackage(
      id: 'removed-plugin',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
    ));

    await manager.reconcile(const [], download: (_, __, ___) async => const []);

    expect(await manager.activeVersion('removed-plugin'), isNull);
    expect(await manager.activeProcessSpec('removed-plugin'), isNull);
    await directory.delete(recursive: true);
  });

  test('accepts canonical cross-language permission names', () {
    expect(parsePluginPermission('workspace:read'),
        PluginPermission.readWorkspace);
    expect(parsePluginPermission('network:outbound'), PluginPermission.network);
    expect(PluginPermission.writeWorkspace.wireName, 'workspace:write');
    expect(parsePluginPermission('network:openai'),
        PluginPermission.networkOpenAi);
    expect(parsePluginPermission('network:anthropic'),
        PluginPermission.networkAnthropic);
    expect(PluginPermission.networkOpenAi.wireName, 'network:openai');
  });

  test('injects only manifest-declared secrets into a verified plugin',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugin-secrets-');
    final bytes = [61, 62, 63];
    const manifest = PluginManifest(
      pluginId: 'secret-plugin',
      version: '1.0.0',
      protocolVersion: '2.0',
      engineVersion: '>=0.1.0',
      executable: 'package.bin',
      permissions: [PluginPermission.credentials],
      secretEnvironmentVariables: ['OPENAI_API_KEY'],
    );
    final manager = PluginManager(
      directory,
      allowedPermissions: {PluginPermission.credentials},
      secretEnvironment: const {
        'OPENAI_API_KEY': 'key-value',
        'UNDECLARED_SECRET': 'must-not-appear',
      },
    );
    await manager.install(PluginPackage(
      id: 'secret-plugin',
      version: '1.0.0',
      bytes: bytes,
      digest: sha256.convert(bytes).toString(),
      manifest: manifest,
    ));
    final spec = await manager.activeProcessSpec('secret-plugin');
    expect(spec?.environment, {'OPENAI_API_KEY': 'key-value'});
    expect(spec?.allowedEnvironmentVariables, {'OPENAI_API_KEY'});
    await directory.delete(recursive: true);
  });

  test('rejects secret declarations without credential permission', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugin-secrets-');
    final bytes = [64, 65, 66];
    await expectLater(
      PluginManager(directory).install(PluginPackage(
        id: 'unapproved-secret-plugin',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
        manifest: const PluginManifest(
          pluginId: 'unapproved-secret-plugin',
          version: '1.0.0',
          protocolVersion: '2.0',
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
        await Directory.systemTemp.createTemp('conclave-plugins-network-');
    final bytes = [41, 42, 43];
    final digest = sha256.convert(bytes).toString();
    const policy = PluginTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = PluginManager(
      directory,
      trustPolicy: policy,
      allowedPermissions: {PluginPermission.networkOpenAi},
    );
    await manager.reconcile(
      [
        {
          'pluginId': 'openai-plugin',
          'version': '1.0.0',
          'publisher': 'publisher',
          'packageR2Key': 'plugins/openai/1.0.0/package.bin',
          'packageDigest': digest,
          'signature': policy.sign('publisher', digest),
          'permissions': ['network:openai'],
        },
      ],
      download: (_, __, ___) async => bytes,
    );
    expect(await manager.activeVersion('openai-plugin'), '1.0.0');
    await directory.delete(recursive: true);
  });

  test('rejects traversal identifiers before checking the active version',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory);
    var downloaded = false;
    await expectLater(
      manager.reconcile(
        [
          {
            'pluginId': '../outside',
            'version': '1.0.0',
            'publisher': 'publisher',
            'packageR2Key': 'plugins/outside/1.0.0/package.bin',
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

  test('rechecks signing revocation before launching an installed plugin',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final bytes = [19, 20, 21];
    final digest = sha256.convert(bytes).toString();
    const installPolicy =
        PluginTrustPolicy(trustedSecrets: {'publisher': 'root'});
    final manager = PluginManager(
      directory,
      trustPolicy: installPolicy,
      allowedPermissions: {PluginPermission.readWorkspace},
    );
    await manager.install(PluginPackage(
      id: 'revocable',
      version: '1.0.0',
      bytes: bytes,
      digest: digest,
      publisher: 'publisher',
      signature: installPolicy.sign('publisher', digest),
      permissions: [PluginPermission.readWorkspace],
    ));

    final revokedManager = PluginManager(
      directory,
      trustPolicy: PluginTrustPolicy(
        trustedSecrets: const {'publisher': 'root'},
        revokedDigests: {digest},
      ),
      allowedPermissions: {PluginPermission.readWorkspace},
    );
    await expectLater(
      revokedManager.activeProcessSpec('revocable'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects a plugin that does not support the Agent platform', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory, platformKey: 'linux-x64');
    final bytes = [7, 8, 9];
    await expectLater(
      manager.install(PluginPackage(
        id: 'mac-only',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
        manifest: const PluginManifest(
          pluginId: 'mac-only',
          version: '1.0.0',
          protocolVersion: '2.0',
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory, engineVersion: '0.1.0');
    final bytes = [10, 11, 12];
    expect(
      () => manager.install(PluginPackage(
        id: 'future',
        version: '1.0.0',
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
        manifest: const PluginManifest(
          pluginId: 'future',
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final bytes = [13, 14, 15];
    final manager = PluginManager(directory);
    await manager.install(PluginPackage(
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final bytes = [16, 17, 18];
    final manager = PluginManager(directory);
    await manager.install(PluginPackage(
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
    manifest['pluginId'] = 'other-plugin';
    await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
    await expectLater(
      manager.activeProcessSpec('identity'),
      throwsA(isA<StateError>()),
    );
    await directory.delete(recursive: true);
  });

  test('rechecks manifest compatibility before launching', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory, platformKey: 'macos-arm64');
    final bytes = [20, 21, 22];
    await manager.install(PluginPackage(
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
        await Directory.systemTemp.createTemp('conclave-plugins-');
    final manager = PluginManager(directory);
    final bytes = [17, 18, 19];
    await manager.install(PluginPackage(
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

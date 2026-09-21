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
}

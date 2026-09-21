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
    await manager.rollback('echo', '1.0.0');
    expect(await manager.activeVersion('echo'), '1.0.0');
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
}

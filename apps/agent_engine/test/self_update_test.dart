import 'dart:io';
import 'package:conclave_agent_engine/self_update.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('activates a verified release and records metadata', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [1, 2, 3];
    await AgentUpdater(root).apply(
      ReleasePackage(
          version: '1.1.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString()),
      healthCheck: (_) async => true,
    );
    expect(await File('${root.path}/agent.active').exists(), isTrue);
    expect(await File('${root.path}/release.json').readAsString(),
        contains('1.1.0'));
    await root.delete(recursive: true);
  });

  test('restores previous release after a failed health check', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    await root.create(recursive: true);
    final old = File('${root.path}/agent.active')..writeAsBytesSync([9]);
    final bytes = [1, 2, 3];
    await expectLater(
      AgentUpdater(root).apply(
        ReleasePackage(
            version: '2.0.0',
            channel: 'beta',
            bytes: bytes,
            digest: sha256.convert(bytes).toString()),
        healthCheck: (_) async => false,
      ),
      throwsStateError,
    );
    expect(await old.readAsBytes(), [9]);
    await root.delete(recursive: true);
  });
}

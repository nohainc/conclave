import 'dart:io';
import 'package:conclave_agent_engine/self_update.dart';
import 'package:crypto/crypto.dart';
import 'package:conclave_agent_engine/trust_policy.dart';
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

  test('rejects an invalid signed release', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [4, 5, 6];
    const policy = PluginTrustPolicy(trustedSecrets: {'release': 'root'});
    await expectLater(
      AgentUpdater(root, trustPolicy: policy).apply(
        ReleasePackage(
          version: '1.2.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
          publisher: 'release',
          signature: 'invalid',
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    await root.delete(recursive: true);
  });

  test('rejects a release requiring a newer protocol', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [7, 8, 9];
    await expectLater(
      AgentUpdater(root, currentProtocolVersion: '2.0').apply(
        ReleasePackage(
          version: '2.0.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
          minimumProtocolVersion: '3.0',
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    await root.delete(recursive: true);
  });

  test('rejects a signed or valid release downgrade', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final currentBytes = [1, 1, 1];
    final currentDigest = sha256.convert(currentBytes).toString();
    await AgentUpdater(root).apply(
      ReleasePackage(
        version: '2.0.0',
        channel: 'stable',
        bytes: currentBytes,
        digest: currentDigest,
      ),
      healthCheck: (_) async => true,
    );

    final olderBytes = [0, 0, 1];
    await expectLater(
      AgentUpdater(root).apply(
        ReleasePackage(
          version: '1.9.9',
          channel: 'stable',
          bytes: olderBytes,
          digest: sha256.convert(olderBytes).toString(),
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await File('${root.path}/agent.active').readAsBytes(), currentBytes);
    await root.delete(recursive: true);
  });
}

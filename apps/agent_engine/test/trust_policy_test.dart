import 'package:conclave_agent_engine/trust_policy.dart';
import 'package:test/test.dart';

void main() {
  test('verifies publisher signatures and rejects revoked digests', () {
    const policy = PluginTrustPolicy(trustedSecrets: {'conclave': 'root-key'});
    final signature = policy.sign('conclave', 'sha256:abc');
    expect(
        policy.verify(
            publisher: 'conclave', digest: 'sha256:abc', signature: signature),
        isTrue);
    final revoked = PluginTrustPolicy(
        trustedSecrets: {'conclave': 'root-key'},
        revokedDigests: {'sha256:abc'});
    expect(
        revoked.verify(
            publisher: 'conclave', digest: 'sha256:abc', signature: signature),
        isFalse);
  });

  test('enforces plugin permissions and redacts secrets', () {
    const policy = PluginTrustPolicy(trustedSecrets: {'conclave': 'root-key'});
    expect(
        () => policy.requirePermissions(
            [PluginPermission.shell], [PluginPermission.readWorkspace]),
        throwsStateError);
    expect(redactSecrets('Authorization: secret', ['secret']),
        'Authorization: [REDACTED]');
  });

  test('parses canonical and legacy configured permission names', () {
    expect(
      parseConfiguredPluginPermissions('workspace:read,network:outbound'),
      {PluginPermission.readWorkspace, PluginPermission.network},
    );
    expect(
      parseConfiguredPluginPermissions('readWorkspace'),
      {PluginPermission.readWorkspace},
    );
    expect(
      () => parseConfiguredPluginPermissions('unknown'),
      throwsStateError,
    );
  });

  test('supports signing-key rotation and key revocation', () {
    const policy = PluginTrustPolicy(
      trustedKeys: {
        'conclave': {'old': 'old-key', 'new': 'new-key'},
      },
    );
    final oldSignature = policy.sign('conclave', 'digest', keyId: 'old');
    final newSignature = policy.sign('conclave', 'digest', keyId: 'new');
    expect(
        policy.verify(
            publisher: 'conclave', digest: 'digest', signature: oldSignature),
        isTrue);
    expect(
        policy.verify(
            publisher: 'conclave', digest: 'digest', signature: newSignature),
        isTrue);

    const rotated = PluginTrustPolicy(
      trustedKeys: {
        'conclave': {'old': 'old-key', 'new': 'new-key'},
      },
      revokedKeyIds: {'old'},
    );
    expect(
        rotated.verify(
            publisher: 'conclave', digest: 'digest', signature: oldSignature),
        isFalse);
    expect(
        rotated.verify(
            publisher: 'conclave', digest: 'digest', signature: newSignature),
        isTrue);
  });
}

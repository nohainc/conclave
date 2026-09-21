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
}

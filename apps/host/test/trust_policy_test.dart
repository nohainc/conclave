import 'package:conclave_host/worker_trust_policy.dart';
import 'package:test/test.dart';

void main() {
  test('verifies publisher signatures and rejects revoked digests', () {
    const policy = WorkerTrustPolicy(trustedSecrets: {'conclave': 'root-key'});
    final signature = policy.sign('conclave', 'sha256:abc');
    expect(
        policy.verify(
            publisher: 'conclave', digest: 'sha256:abc', signature: signature),
        isTrue);
    expect(
        policy.verify(
          publisher: 'conclave',
          digest: 'sha256:abc',
          signature: 'sig_pkg_${signature.substring(4)}',
        ),
        isTrue);
    final revoked = WorkerTrustPolicy(
        trustedSecrets: {'conclave': 'root-key'},
        revokedDigests: {'sha256:abc'});
    expect(
        revoked.verify(
            publisher: 'conclave', digest: 'sha256:abc', signature: signature),
        isFalse);
  });

  test('enforces worker permissions and redacts secrets', () {
    const policy = WorkerTrustPolicy(trustedSecrets: {'conclave': 'root-key'});
    expect(
        () => policy.requirePermissions(
            [WorkerPermission.shell], [WorkerPermission.readWorkspace]),
        throwsStateError);
    expect(redactSecrets('Authorization: secret', ['secret']),
        'Authorization: [REDACTED]');
  });

  test('parses canonical and legacy configured permission names', () {
    expect(
      parseConfiguredWorkerPermissions('workspace:read,network:outbound'),
      {WorkerPermission.readWorkspace, WorkerPermission.network},
    );
    expect(
      parseConfiguredWorkerPermissions('readWorkspace'),
      {WorkerPermission.readWorkspace},
    );
    expect(
      () => parseConfiguredWorkerPermissions('unknown'),
      throwsStateError,
    );
    expect(
      parseConfiguredWorkerPermissions('network:openai,network:anthropic'),
      {WorkerPermission.networkOpenAi, WorkerPermission.networkAnthropic},
    );
  });

  test('supports signing-key rotation and key revocation', () {
    const policy = WorkerTrustPolicy(
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

    const rotated = WorkerTrustPolicy(
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

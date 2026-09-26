import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  test('verifies Ed25519 signatures and rejects revoked digests', () async {
    final fixture = await Ed25519ReleaseFixture.create();
    final message = 'conclave-workspace-release-v1\nsha256:abc';
    // The fixture signer signs with its private key. The production policy
    // receives only the corresponding public key.
    final signed =
        await Ed25519().sign(message.codeUnits, keyPair: fixture.pair);
    final encoded = base64.encode(signed.bytes);
    expect(
      await fixture.trustPolicy.verify(
        publisher: fixturePublisher,
        signingKeyId: fixtureKeyId,
        digest: 'sha256:abc',
        signature: encoded,
      ),
      isTrue,
    );
    final revoked = WorkerTrustPolicy(
      trustedPublicKeys: fixture.trustPolicy.trustedPublicKeys,
      revokedDigests: {'sha256:abc'},
    );
    expect(
      await revoked.verify(
        publisher: fixturePublisher,
        signingKeyId: fixtureKeyId,
        digest: 'sha256:abc',
        signature: encoded,
      ),
      isFalse,
    );
  });

  test('enforces worker permissions and redacts secrets', () {
    final policy = WorkerTrustPolicy();
    expect(
      () => policy.requirePermissions(
        [WorkerPermission.shell],
        [WorkerPermission.readWorkspace],
      ),
      throwsStateError,
    );
    expect(redactSecrets('Authorization: secret', ['secret']),
        'Authorization: [REDACTED]');
  });

  test('parses canonical and legacy configured permission names', () {
    expect(
      parseConfiguredWorkerPermissions('workspace:read,network:outbound'),
      {WorkerPermission.readWorkspace, WorkerPermission.network},
    );
    expect(parseConfiguredWorkerPermissions('readWorkspace'),
        {WorkerPermission.readWorkspace});
    expect(() => parseConfiguredWorkerPermissions('unknown'), throwsStateError);
    expect(
      parseConfiguredWorkerPermissions('network:openai,network:anthropic'),
      {WorkerPermission.networkOpenAi, WorkerPermission.networkAnthropic},
    );
  });

  test('supports overlapping key rotation and immediate key revocation',
      () async {
    final fixture = await Ed25519ReleaseFixture.create();
    final signed = await Ed25519().sign(
      'release'.codeUnits,
      keyPair: fixture.pair,
    );
    final signature = base64.encode(signed.bytes);
    fixture.trustPolicy.updateRevocations(keyIds: {fixtureKeyId});
    expect(
      await fixture.trustPolicy.verify(
        publisher: fixturePublisher,
        signingKeyId: fixtureKeyId,
        digest: 'digest',
        signature: signature,
      ),
      isFalse,
    );
    fixture.trustPolicy.updateRevocations();
    expect(fixture.trustPolicy.trustedPublicKeys[fixturePublisher],
        contains(fixtureKeyId));
  });
}

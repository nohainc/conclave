import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show canonicalJson;
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Ed25519ReleaseFixture signing;
  late Map<String, Object?> release;
  late String workerTypeId;

  setUp(() async {
    signing = await Ed25519ReleaseFixture.create();
    final fixture = jsonDecode(File(
      '../../packages/tool-profile/test/fixtures/fixture-cli.v1.json',
    ).readAsStringSync()) as Map<String, Object?>;
    final profile = Map<String, Object?>.from(fixture);
    workerTypeId = profile['logicalWorkerTypeId']! as String;
    final providerTool = profile['providerTool']! as Map<String, Object?>;
    release = {
      'profileDefinitionId': profile['profileDefinitionId'],
      'workerTypeId': workerTypeId,
      'releaseVersion': profile['releaseVersion'],
      'channel': 'stable',
      'providerToolName': providerTool['name'],
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
      'profile': profile,
    };
    await signing.signToolProfileRelease(release);
  });

  test('admits an intact signed Profile release', () async {
    final admitted = await ToolProfileReleaseVerifier.verify(
      input: release,
      trustPolicy: signing.trustPolicy,
      expectedWorkerTypeId: workerTypeId,
    );
    expect(admitted.payloadDigest, release['payloadDigest']);
    expect(admitted.providerToolName, release['providerToolName']);
    expect(
      () => (admitted.profile['providerTool']! as Map)['name'] = 'tampered',
      throwsUnsupportedError,
    );
  });

  test('rejects payload mutation even when database metadata is unchanged',
      () async {
    final altered = jsonDecode(jsonEncode(release)) as Map<String, Object?>;
    final profile = altered['profile']! as Map<String, Object?>;
    (profile['providerTool']! as Map<String, Object?>)['name'] = 'changed-cli';
    await expectLater(
      ToolProfileReleaseVerifier.verify(
        input: altered,
        trustPolicy: signing.trustPolicy,
        expectedWorkerTypeId: workerTypeId,
      ),
      throwsA(anything),
    );
  });

  test('rejects altered DB identity and compatibility metadata', () async {
    for (final field in [
      'profileDefinitionId',
      'workerTypeId',
      'releaseVersion',
      'providerToolName',
      'engineCompatibility',
      'publisher',
      'signingKeyId',
    ]) {
      final altered = jsonDecode(jsonEncode(release)) as Map<String, Object?>;
      altered[field] = switch (field) {
        'releaseVersion' => 9,
        'engineCompatibility' => {'min': '99.0.0', 'maxExclusive': '100.0.0'},
        _ => 'altered-value',
      };
      await expectLater(
        ToolProfileReleaseVerifier.verify(
          input: altered,
          trustPolicy: signing.trustPolicy,
          expectedWorkerTypeId: workerTypeId,
        ),
        throwsA(anything),
        reason: 'field $field must remain bound to the signed Profile',
      );
    }
  });

  test('rejects revoked signing keys and Profile releases', () async {
    signing.trustPolicy.updateRevocations(keyIds: {'test-ed25519-v1'});
    await expectLater(
      ToolProfileReleaseVerifier.verify(
          input: release,
          trustPolicy: signing.trustPolicy,
          expectedWorkerTypeId: workerTypeId),
      throwsStateError,
    );
    signing.trustPolicy.updateRevocations(releaseIds: {
      '${release['profileDefinitionId']}@${release['releaseVersion']}',
    });
    await expectLater(
      ToolProfileReleaseVerifier.verify(
          input: release,
          trustPolicy: signing.trustPolicy,
          expectedWorkerTypeId: workerTypeId),
      throwsStateError,
    );
  });

  test('key rotation admits the new key ID while the old key is revoked',
      () async {
    final rotated = await Ed25519ReleaseFixture.create(
      keyId: 'profile-key-v2',
      seed: Uint8List.fromList(List<int>.filled(32, 7)),
    );
    final releaseV2 = jsonDecode(jsonEncode(release)) as Map<String, Object?>;
    await rotated.signToolProfileRelease(releaseV2, keyId: 'profile-key-v2');
    rotated.trustPolicy.updateRevocations(keyIds: {'test-ed25519-v1'});
    final admitted = await ToolProfileReleaseVerifier.verify(
      input: releaseV2,
      trustPolicy: rotated.trustPolicy,
      expectedWorkerTypeId: workerTypeId,
    );
    expect(admitted.profileDefinitionId, release['profileDefinitionId']);
  });

  test('lifecycle channel changes do not alter signed Profile behavior',
      () async {
    final promoted = jsonDecode(jsonEncode(release)) as Map<String, Object?>;
    promoted['channel'] = 'beta';
    final admitted = await ToolProfileReleaseVerifier.verify(
      input: promoted,
      trustPolicy: signing.trustPolicy,
      expectedWorkerTypeId: workerTypeId,
    );
    expect(admitted.channel, 'beta');
  });

  test('admits an intact signed V9 current Worker Profile snapshot', () async {
    final profile = Map<String, Object?>.from(release['profile']! as Map);
    final digest =
        sha256.convert(utf8.encode(canonicalJson(profile))).toString();
    const revision = 7;
    final message = workerProfileSigningMessage(
      publisher: fixturePublisher,
      signingKeyId: fixtureKeyId,
      workerTypeId: workerTypeId,
      revision: revision,
      schemaVersion: profile['schemaVersion']! as int,
      payloadDigest: digest,
    );
    final signature = base64.encode(
      (await Ed25519().sign(utf8.encode(message), keyPair: signing.pair)).bytes,
    );
    final snapshot = <String, Object?>{
      'workerTypeId': workerTypeId,
      'schemaVersion': profile['schemaVersion'],
      'profile': profile,
      'revision': revision,
      'digest': digest,
      'signature': signature,
      'signingKeyId': fixtureKeyId,
      'publisher': fixturePublisher,
      'verified': true,
    };

    final admitted = await WorkerProfileSnapshotVerifier.verify(
      input: snapshot,
      trustPolicy: signing.trustPolicy,
      expectedWorkerTypeId: workerTypeId,
    );
    expect(admitted.revision, revision);
    expect(admitted.payloadDigest, digest);
    expect(admitted.profile, isNotEmpty);
  });

  test('rejects a V9 snapshot after payload mutation', () async {
    final profile = Map<String, Object?>.from(release['profile']! as Map);
    final digest =
        sha256.convert(utf8.encode(canonicalJson(profile))).toString();
    final message = workerProfileSigningMessage(
      publisher: fixturePublisher,
      signingKeyId: fixtureKeyId,
      workerTypeId: workerTypeId,
      revision: 1,
      schemaVersion: profile['schemaVersion']! as int,
      payloadDigest: digest,
    );
    final snapshot = <String, Object?>{
      'workerTypeId': workerTypeId,
      'schemaVersion': profile['schemaVersion'],
      'profile': profile,
      'revision': 1,
      'digest': digest,
      'signature': base64.encode(
        (await Ed25519().sign(utf8.encode(message), keyPair: signing.pair))
            .bytes,
      ),
      'signingKeyId': fixtureKeyId,
      'publisher': fixturePublisher,
      'verified': true,
    };
    (snapshot['profile']! as Map<String, Object?>)['releaseVersion'] = 99;
    await expectLater(
      WorkerProfileSnapshotVerifier.verify(
        input: snapshot,
        trustPolicy: signing.trustPolicy,
        expectedWorkerTypeId: workerTypeId,
      ),
      throwsA(anything),
    );
  });
}

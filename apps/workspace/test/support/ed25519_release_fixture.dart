import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:conclave_workspace/worker_trust_policy.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:crypto/crypto.dart';

const fixturePublisher = 'Conclave Test';
const fixtureKeyId = 'test-ed25519-v1';
final fixtureSeed =
    Uint8List.fromList(List<int>.generate(32, (index) => index));

class Ed25519ReleaseFixture {
  Ed25519ReleaseFixture._(this.pair, this.trustPolicy, this.seed);

  final SimpleKeyPair pair;
  final WorkerTrustPolicy trustPolicy;
  final Uint8List seed;

  static Future<Ed25519ReleaseFixture> create({
    String publisher = fixturePublisher,
    String keyId = fixtureKeyId,
    Uint8List? seed,
  }) async {
    final actualSeed = seed ?? fixtureSeed;
    final pair = await Ed25519().newKeyPairFromSeed(actualSeed);
    final publicKey = await pair.extractPublicKey();
    return Ed25519ReleaseFixture._(
      pair,
      WorkerTrustPolicy(trustedPublicKeys: {
        publisher: {keyId: base64.encode(publicKey.bytes)},
      }),
      actualSeed,
    );
  }

  String get seedBase64 => base64.encode(seed);

  Future<String> signWorkspaceRelease({
    required String publisher,
    required String keyId,
    required String digest,
    required Map<String, Object?> metadata,
  }) async {
    final payload = {
      ...metadata,
      'publisher': publisher,
      'signingKeyId': keyId,
      'packageDigest': digest,
    };
    final signature = await Ed25519().sign(
      utf8.encode(
          'conclave-workspace-release-metadata-v1\n${canonicalJson(payload)}'),
      keyPair: pair,
    );
    return base64.encode(signature.bytes);
  }

  Future<void> signToolProfileRelease(
    Map<String, Object?> release, {
    String publisher = fixturePublisher,
    String keyId = fixtureKeyId,
  }) async {
    final profile = Map<String, Object?>.from(release['profile']! as Map);
    final digest =
        sha256.convert(utf8.encode(canonicalJson(profile))).toString();
    release['payloadDigest'] = digest;
    release['publisher'] = publisher;
    release['signingKeyId'] = keyId;
    release['signature'] = base64.encode((await Ed25519().sign(
      utf8.encode(toolProfileReleaseSigningMessage(
        publisher: publisher,
        signingKeyId: keyId,
        payloadDigest: digest,
        profile: profile,
      )),
      keyPair: pair,
    ))
        .bytes);
  }
}

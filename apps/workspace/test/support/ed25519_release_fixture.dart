import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:conclave_workspace/worker_trust_policy.dart';

const fixturePublisher = 'Syntila Test';
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
}

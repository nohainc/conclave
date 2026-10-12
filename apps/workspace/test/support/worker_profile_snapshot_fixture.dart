import 'dart:convert';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'ed25519_release_fixture.dart';

Future<WorkerProfileSnapshotAdmission> workerProfileSnapshotFixture({
  required Ed25519ReleaseFixture signing,
  required Map<String, Object?> profile,
  required String workerTypeId,
  required int revision,
}) async {
  final payload = jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
  payload['logicalWorkerTypeId'] = workerTypeId;
  payload['releaseVersion'] = revision;
  final digest = sha256.convert(utf8.encode(canonicalJson(payload))).toString();
  final message = workerProfileSigningMessage(
    publisher: fixturePublisher,
    signingKeyId: fixtureKeyId,
    workerTypeId: workerTypeId,
    revision: revision,
    schemaVersion: payload['schemaVersion']! as int,
    payloadDigest: digest,
  );
  final signature = base64.encode(
    (await Ed25519().sign(utf8.encode(message), keyPair: signing.pair)).bytes,
  );
  return WorkerProfileSnapshotAdmission(
    profile: payload,
    workerTypeId: workerTypeId,
    revision: revision,
    payloadDigest: digest,
    signature: signature,
    signingKeyId: fixtureKeyId,
    publisher: fixturePublisher,
  );
}

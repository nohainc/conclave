import 'dart:convert';

import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:crypto/crypto.dart';

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
  return WorkerProfileSnapshotAdmission(
    profile: payload,
    workerTypeId: workerTypeId,
    revision: revision,
    payloadDigest: digest,
  );
}

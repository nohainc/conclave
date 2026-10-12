import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../tool_profile_v1.dart';
import 'worker_trust_policy.dart';

/// Verifies the single current V9 Profile snapshot before a component caches,
/// activates, or executes it. Cloud's `verified` flag is informational; the
/// digest, schema, identity, and signature are checked locally again.
abstract final class WorkerProfileSnapshotVerifier {
  static const maxSnapshotBytes = 512 * 1024;

  static Future<WorkerProfileSnapshotAdmission> verify({
    required Object? input,
    required WorkerTrustPolicy trustPolicy,
    required String expectedWorkerTypeId,
  }) async {
    if (input is! Map) {
      throw const FormatException('Worker Profile snapshot is invalid');
    }
    final snapshot = Map<String, Object?>.from(input);
    const allowedKeys = {
      'workerTypeId',
      'schemaVersion',
      'profile',
      'revision',
      'digest',
      'signature',
      'signingKeyId',
      'publisher',
      // Transitional metadata used only while a signed V8 stable snapshot is
      // migrated into the V9 current-profile cache. New Cloud snapshots do
      // not include these fields.
      'signatureDomain',
      'signatureReleaseId',
      'updatedByUserId',
      'updatedAt',
      'verified',
    };
    if (snapshot.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException(
          'Worker Profile snapshot metadata is invalid');
    }
    final workerTypeId = _string(snapshot, 'workerTypeId');
    final schemaVersion = _integer(snapshot, 'schemaVersion');
    final profileValue = snapshot['profile'];
    if (profileValue is! Map) {
      throw const FormatException('Worker Profile snapshot payload is invalid');
    }
    final profile = Map<String, Object?>.from(profileValue);
    final revision = _integer(snapshot, 'revision');
    if (revision < 1 ||
        schemaVersion < 1 ||
        workerTypeId != expectedWorkerTypeId) {
      throw const FormatException(
          'Worker Profile snapshot identity is invalid');
    }
    final digest = _string(snapshot, 'digest');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Worker Profile snapshot digest is invalid');
    }
    final signature = _string(snapshot, 'signature');
    final signingKeyId = _string(snapshot, 'signingKeyId');
    final publisher = _string(snapshot, 'publisher');
    final canonical = canonicalJson(profile);
    if (utf8.encode(canonical).length > maxSnapshotBytes) {
      throw const FormatException('Worker Profile snapshot is oversized');
    }
    final engineProfile = EngineProfile.parse(utf8.encode(canonical));
    if (engineProfile.workerTypeId != workerTypeId ||
        engineProfile.schemaVersion != schemaVersion ||
        sha256.convert(utf8.encode(canonical)).toString() != digest) {
      throw const FormatException(
          'Worker Profile snapshot digest or identity mismatch');
    }
    final signatureDomain = snapshot['signatureDomain'];
    final signatureReleaseId = snapshot['signatureReleaseId'];
    final legacySignature =
        signatureDomain == 'conclave-tool-profile-release-v1' &&
            signatureReleaseId is String &&
            signatureReleaseId.isNotEmpty;
    if (signatureDomain != null && !legacySignature) {
      throw const FormatException('Worker Profile signature domain is invalid');
    }
    final message = legacySignature
        ? toolProfileReleaseSigningMessage(
            publisher: publisher,
            signingKeyId: signingKeyId,
            payloadDigest: digest,
            profile: profile,
          )
        : workerProfileSigningMessage(
            publisher: publisher,
            signingKeyId: signingKeyId,
            workerTypeId: workerTypeId,
            revision: revision,
            schemaVersion: schemaVersion,
            payloadDigest: digest,
          );
    final valid = await trustPolicy.verifyToolProfileRelease(
      publisher: publisher,
      signingKeyId: signingKeyId,
      digest: digest,
      releaseId: legacySignature
          ? signatureReleaseId
          : 'worker:$workerTypeId@$revision',
      signature: signature,
      message: message,
    );
    if (!valid) {
      throw StateError('Worker Profile snapshot signature is not trusted');
    }
    return WorkerProfileSnapshotAdmission(
      profile: freezeJson(profile) as Map<String, Object?>,
      workerTypeId: workerTypeId,
      revision: revision,
      payloadDigest: digest,
      signature: signature,
      signingKeyId: signingKeyId,
      publisher: publisher,
    );
  }
}

String _string(Map<String, Object?> value, String key) {
  final item = value[key];
  if (item is! String || item.isEmpty || item.length > 4096) {
    throw FormatException('Worker Profile snapshot $key is invalid');
  }
  return item;
}

int _integer(Map<String, Object?> value, String key) {
  final item = value[key];
  if (item is! int || item < 0 || item > 0x7fffffff) {
    throw FormatException('Worker Profile snapshot $key is invalid');
  }
  return item;
}

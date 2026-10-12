import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../tool_profile_v1.dart';

/// Validates the current V9 Profile snapshot before it is cached, activated,
/// or executed. V9 uses authenticated Cloud publication and canonical digest
/// validation; Profile snapshots carry only canonical publication metadata.
abstract final class WorkerProfileSnapshotVerifier {
  static const maxSnapshotBytes = 512 * 1024;

  static Future<WorkerProfileSnapshotAdmission> verify({
    required Object? input,
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
      'updatedByUserId',
      'updatedAt',
    };
    if (snapshot.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('Worker Profile snapshot metadata is invalid');
    }
    final workerTypeId = _string(snapshot, 'workerTypeId');
    final schemaVersion = _integer(snapshot, 'schemaVersion');
    final profileValue = snapshot['profile'];
    if (profileValue is! Map) {
      throw const FormatException('Worker Profile snapshot payload is invalid');
    }
    final profile = Map<String, Object?>.from(profileValue);
    final revision = _integer(snapshot, 'revision');
    if (revision < 1 || schemaVersion < 1 || workerTypeId != expectedWorkerTypeId) {
      throw const FormatException('Worker Profile snapshot identity is invalid');
    }
    final digest = _string(snapshot, 'digest');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Worker Profile snapshot digest is invalid');
    }
    final canonical = canonicalJson(profile);
    if (utf8.encode(canonical).length > maxSnapshotBytes) {
      throw const FormatException('Worker Profile snapshot is oversized');
    }
    final engineProfile = EngineProfile.parse(utf8.encode(canonical));
    if (engineProfile.workerTypeId != workerTypeId ||
        engineProfile.schemaVersion != schemaVersion ||
        sha256.convert(utf8.encode(canonical)).toString() != digest) {
      throw const FormatException('Worker Profile snapshot digest or identity mismatch');
    }
    return WorkerProfileSnapshotAdmission(
      profile: freezeJson(profile) as Map<String, Object?>,
      workerTypeId: workerTypeId,
      revision: revision,
      payloadDigest: digest,
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

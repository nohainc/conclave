import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../tool_profile_v1.dart';

/// Common contract for any resolved Profile candidate.
///
/// [revision] is the immutable execution identity supplied by Workspace. The
/// legacy [releaseVersion] getter remains part of the Profile format adapter,
/// but the Engine must use [revision] for admission and session attribution.
abstract interface class ToolProfileCandidate {
  Map<String, Object?> get profile;
  String get profileDefinitionId;
  int get releaseVersion;
  int get revision;
  String get logicalWorkerTypeId;
  String get providerToolName;
  String get payloadDigest;
  bool get isSigned;
}

/// Cloud response for one immutable Profile release, with database lifecycle
/// metadata kept alongside (but outside) the signed behavior envelope.
class ToolProfileReleaseAdmission implements ToolProfileCandidate {
  const ToolProfileReleaseAdmission({
    required this.profile,
    required this.profileDefinitionId,
    required this.releaseVersion,
    required this.logicalWorkerTypeId,
    required this.providerToolName,
    required this.payloadDigest,
    required this.channel,
  });

  @override
  final Map<String, Object?> profile;
  @override
  final String profileDefinitionId;
  @override
  final int releaseVersion;
  @override
  int get revision => releaseVersion;
  @override
  final String logicalWorkerTypeId;
  @override
  final String providerToolName;
  @override
  final String payloadDigest;
  final String channel;

  @override
  bool get isSigned => true;
}

/// Cloud's V9 current Profile snapshot. Unlike a legacy release, this
/// identity has no channel; [revision] is the immutable publication revision.
class WorkerProfileSnapshotAdmission implements ToolProfileCandidate {
  const WorkerProfileSnapshotAdmission({
    required this.profile,
    required this.workerTypeId,
    required this.revision,
    required this.payloadDigest,
    required this.signature,
    required this.signingKeyId,
    required this.publisher,
  });

  @override
  final Map<String, Object?> profile;
  final String workerTypeId;
  @override
  final int revision;
  @override
  final String payloadDigest;
  final String signature;
  final String signingKeyId;
  final String publisher;

  @override
  String get profileDefinitionId => profile['profileDefinitionId'] as String;

  @override
  int get releaseVersion => revision;

  @override
  String get logicalWorkerTypeId => workerTypeId;

  @override
  String get providerToolName =>
      (profile['providerTool'] as Map)['name'] as String;

  @override
  bool get isSigned => true;
}

/// Unsigned local Draft Profile candidate used strictly within the
/// Profile Lab test sandbox. Never admitted to production Workspaces.
class LocalDraftProfileCandidate implements ToolProfileCandidate {
  const LocalDraftProfileCandidate({
    required this.profile,
    required this.profileDefinitionId,
    required this.releaseVersion,
    required this.logicalWorkerTypeId,
    required this.providerToolName,
    required this.payloadDigest,
  });

  @override
  final Map<String, Object?> profile;
  @override
  final String profileDefinitionId;
  @override
  final int releaseVersion;
  @override
  int get revision => releaseVersion;
  @override
  final String logicalWorkerTypeId;
  @override
  final String providerToolName;
  @override
  final String payloadDigest;

  @override
  bool get isSigned => false;

  /// Creates a draft candidate from raw JSON map after computing its canonical digest.
  factory LocalDraftProfileCandidate.fromProfileMap(Map<String, Object?> json) {
    final canonical = canonicalJson(json);
    EngineProfile.parse(utf8.encode(canonical));
    final digest = sha256.convert(utf8.encode(canonical)).toString();
    final tool = json['providerTool'] as Map<String, Object?>? ?? const {};
    return LocalDraftProfileCandidate(
      profile: freezeJson(json) as Map<String, Object?>,
      profileDefinitionId: json['profileDefinitionId'] as String? ?? '',
      releaseVersion: json['releaseVersion'] as int? ?? 1,
      logicalWorkerTypeId: json['logicalWorkerTypeId'] as String? ?? '',
      providerToolName: tool['name'] as String? ?? '',
      payloadDigest: digest,
    );
  }
}

/// Target identity for a Tool Profile release.
class ToolProfileReleaseIdentity {
  const ToolProfileReleaseIdentity({
    required this.profileDefinitionId,
    required this.releaseVersion,
  });

  final String profileDefinitionId;
  final int releaseVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolProfileReleaseIdentity &&
          runtimeType == other.runtimeType &&
          profileDefinitionId == other.profileDefinitionId &&
          releaseVersion == other.releaseVersion;

  @override
  int get hashCode => Object.hash(profileDefinitionId, releaseVersion);

  @override
  String toString() => '$profileDefinitionId@$releaseVersion';
}

/// Computes the canonical Ed25519 signing message for a Tool Profile Release v1.
String toolProfileReleaseSigningMessage({
  required String publisher,
  required String signingKeyId,
  required String payloadDigest,
  required Map<String, Object?> profile,
}) {
  final providerTool = profile['providerTool'] as Map;
  return 'conclave-tool-profile-release-v1\n${canonicalJson({
        'domain': 'conclave-tool-profile-release-v1',
        'publisher': publisher,
        'signingKeyId': signingKeyId,
        'payloadDigest': payloadDigest,
        'profileDefinitionId': profile['profileDefinitionId'],
        'releaseVersion': profile['releaseVersion'],
        'logicalWorkerTypeId': profile['logicalWorkerTypeId'],
        'engineFamily': profile['engineFamily'],
        'schemaVersion': profile['schemaVersion'],
        'engineCompatibility': profile['engineCompatibility'],
        'providerToolName': providerTool['name'],
        'providerCompatibility': providerTool['supportedVersions'],
      })}';
}

/// Computes the canonical Ed25519 signing message for a V9 current Profile.
String workerProfileSigningMessage({
  required String publisher,
  required String signingKeyId,
  required String workerTypeId,
  required int revision,
  required int schemaVersion,
  required String payloadDigest,
}) {
  return 'conclave-worker-profile-v9\n${canonicalJson({
        'domain': 'conclave-worker-profile-v9',
        'publisher': publisher,
        'signingKeyId': signingKeyId,
        'workerTypeId': workerTypeId,
        'revision': revision,
        'schemaVersion': schemaVersion,
        'payloadDigest': payloadDigest,
      })}';
}

/// Recursively freezes a JSON object or array into unmodifiable structures.
Object? freezeJson(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: freezeJson(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(freezeJson));
  }
  return value;
}

/// Canonical JSON serialization (keys sorted deterministically).
String canonicalJson(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort(
          (left, right) => left.key.toString().compareTo(right.key.toString()));
    return '{${entries.map((entry) => '${jsonEncode(entry.key.toString())}:${canonicalJson(entry.value)}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  return jsonEncode(value);
}

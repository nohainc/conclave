import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

import 'worker_trust_policy.dart';

/// Cloud response for one immutable Profile release, with database lifecycle
/// metadata kept alongside (but outside) the signed behavior envelope.
class ToolProfileReleaseAdmission {
  const ToolProfileReleaseAdmission({
    required this.profile,
    required this.profileDefinitionId,
    required this.releaseVersion,
    required this.logicalWorkerTypeId,
    required this.providerToolName,
    required this.payloadDigest,
    required this.channel,
  });

  final Map<String, Object?> profile;
  final String profileDefinitionId;
  final int releaseVersion;
  final String logicalWorkerTypeId;
  final String providerToolName;
  final String payloadDigest;
  final String channel;
}

/// Verifies Profile integrity and signed release identity before Workspace
/// admits a Profile to the generic CLI Worker Engine.
abstract final class ToolProfileReleaseVerifier {
  static const maxPayloadBytes = maxProfileBytes;

  static Future<ToolProfileReleaseAdmission> verify({
    required Object? input,
    required WorkerTrustPolicy trustPolicy,
    required String expectedWorkerTypeId,
  }) async {
    if (input is! Map) {
      throw const FormatException('Profile release is invalid');
    }
    final release = Map<String, Object?>.from(input);
    final profileValue = release['profile'];
    if (profileValue is! Map) {
      throw const FormatException('Profile payload is invalid');
    }
    final profile = Map<String, Object?>.from(profileValue);
    final profileJson = canonicalJson(profile);
    if (utf8.encode(profileJson).length > maxPayloadBytes) {
      throw const FormatException('Profile payload exceeds the size limit');
    }
    EngineProfile.parse(utf8.encode(profileJson));
    final digest = sha256.convert(utf8.encode(profileJson)).toString();
    final profileDefinitionId = _string(release, 'profileDefinitionId');
    final logicalWorkerTypeId = _string(release, 'workerTypeId');
    final releaseVersion = release['releaseVersion'];
    final channel = _string(release, 'channel');
    final providerToolName = _string(release, 'providerToolName');
    final publisher = _string(release, 'publisher');
    final signingKeyId = _string(release, 'signingKeyId');
    final signature = _string(release, 'signature');
    final declaredDigest = _string(release, 'payloadDigest');
    final engineCompatibility = release['engineCompatibility'];

    if (!_identifier.hasMatch(profileDefinitionId) ||
        !_identifier.hasMatch(logicalWorkerTypeId) ||
        releaseVersion is! int ||
        releaseVersion < 1 ||
        !const {'testing', 'beta', 'stable'}.contains(channel) ||
        !_identifier.hasMatch(expectedWorkerTypeId) ||
        logicalWorkerTypeId != expectedWorkerTypeId ||
        declaredDigest != digest ||
        profile['profileDefinitionId'] != profileDefinitionId ||
        profile['releaseVersion'] != releaseVersion ||
        profile['logicalWorkerTypeId'] != logicalWorkerTypeId ||
        profile['schemaVersion'] != release['schemaVersion'] ||
        profile['engineFamily'] != release['engineFamily'] ||
        profile['engineFamily'] != 'cli' ||
        profile['providerTool'] is! Map ||
        (profile['providerTool'] as Map)['name'] != providerToolName ||
        !_sameJson(profile['engineCompatibility'], engineCompatibility)) {
      throw const FormatException(
          'Profile release identity or metadata mismatch');
    }
    final providerCompatibility =
        (profile['providerTool'] as Map)['supportedVersions'];
    if (providerCompatibility is! List || providerCompatibility.isEmpty) {
      throw const FormatException('Profile provider compatibility is invalid');
    }
    final message = toolProfileReleaseSigningMessage(
      publisher: publisher,
      signingKeyId: signingKeyId,
      payloadDigest: digest,
      profile: profile,
    );
    final valid = await trustPolicy.verifyToolProfileRelease(
      publisher: publisher,
      signingKeyId: signingKeyId,
      digest: digest,
      releaseId: '$profileDefinitionId@$releaseVersion',
      signature: signature,
      message: message,
    );
    if (!valid) {
      throw StateError('Tool Profile release signature is not trusted');
    }
    return ToolProfileReleaseAdmission(
      profile: _freezeJson(profile) as Map<String, Object?>,
      profileDefinitionId: profileDefinitionId,
      releaseVersion: releaseVersion,
      logicalWorkerTypeId: logicalWorkerTypeId,
      providerToolName: providerToolName,
      payloadDigest: digest,
      channel: channel,
    );
  }
}

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

const _identifier = _IdentifierPattern();

class _IdentifierPattern {
  const _IdentifierPattern();
  bool hasMatch(String value) =>
      RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value) &&
      value.length <= 96;
}

String _string(Map<String, Object?> value, String key) {
  final item = value[key];
  if (item is! String || item.isEmpty || item.length > 4096) {
    throw FormatException('Profile release $key is invalid');
  }
  return item;
}

bool _sameJson(Object? left, Object? right) =>
    canonicalJson(left) == canonicalJson(right);

Object? _freezeJson(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeJson(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  return value;
}

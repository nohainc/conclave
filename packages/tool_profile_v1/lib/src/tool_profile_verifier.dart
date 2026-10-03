import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../tool_profile_v1.dart';

/// Verifies Profile integrity and signed release identity before Workspace
/// or Profile Lab admits a Profile to the generic CLI Worker Engine.
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
      profile: freezeJson(profile) as Map<String, Object?>,
      profileDefinitionId: profileDefinitionId,
      releaseVersion: releaseVersion,
      logicalWorkerTypeId: logicalWorkerTypeId,
      providerToolName: providerToolName,
      payloadDigest: digest,
      channel: channel,
    );
  }
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

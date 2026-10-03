import 'dart:convert';

import '../tool_profile_v1.dart';

enum ToolProfileResolutionSource {
  active,
  stable,
  lastKnownGood,
  draft,
  unavailable,
}

enum ToolProfileUnavailableReason {
  noEligibleRelease,
  unsupportedProviderVersion,
  incompatibleEngineVersion,
}

class ToolProfileResolution<T extends ToolProfileCandidate> {
  const ToolProfileResolution._({
    required this.source,
    this.release,
    this.reason,
  });

  const ToolProfileResolution.selected({
    required ToolProfileResolutionSource source,
    required T release,
  }) : this._(source: source, release: release);

  const ToolProfileResolution.unavailable(ToolProfileUnavailableReason reason)
      : this._(source: ToolProfileResolutionSource.unavailable, reason: reason);

  final ToolProfileResolutionSource source;
  final T? release;
  final ToolProfileUnavailableReason? reason;

  bool get isAvailable => release != null;
}

/// Common resolution and compatibility matcher used by Workspace and Profile Lab.
abstract final class ToolProfileCompatibility {
  /// Recommends a narrow minor-line range starting at the version actually
  /// discovered and tested. Older versions are never inferred as compatible.
  static Map<String, String>? recommendedProviderRange(String testedVersion) {
    if (!isSemanticVersion(testedVersion)) return null;
    final match = RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)')
        .firstMatch(testedVersion);
    if (match == null) return null;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    if (minor == 999999999) return null;
    return {
      'min': testedVersion,
      'maxExclusive': '$major.${minor + 1}.0',
    };
  }

  /// Identifies the legacy near-universal range used as a placeholder.
  static bool hasPlaceholderProviderRange(EngineProfile profile) {
    final ranges = profile.providerTool['supportedVersions'];
    if (ranges is! List) return false;
    return ranges.any((value) {
      if (value is! Map ||
          value['min'] is! String ||
          value['maxExclusive'] is! String) {
        return false;
      }
      try {
        return compareSemanticVersions(value['min'] as String, '1.0.0') <= 0 &&
            compareSemanticVersions(
                    value['maxExclusive'] as String, '50.0.0') >=
                0;
      } on FormatException {
        return false;
      }
    });
  }

  static bool isEngineCompatible(EngineProfile profile, String engineVersion) {
    try {
      return engineVersionCompatible(profile, engineVersion);
    } on Object {
      return false;
    }
  }

  static bool isProviderCompatible(
    EngineProfile profile,
    String? providerCliVersion,
  ) {
    if (providerCliVersion == null) return true;
    final ranges = profile.providerTool['supportedVersions'];
    if (ranges is! List) return false;
    for (final range in ranges) {
      if (range is! Map ||
          range['min'] is! String ||
          range['maxExclusive'] is! String) {
        continue;
      }
      try {
        if (semanticVersionInRange(
          providerCliVersion,
          range['min'] as String,
          range['maxExclusive'] as String,
        )) {
          return true;
        }
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  static bool isCandidateCompatible({
    required ToolProfileCandidate candidate,
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    String? providerCliVersion,
  }) {
    if (candidate.logicalWorkerTypeId != logicalWorkerTypeId ||
        candidate.profileDefinitionId != profileDefinitionId) {
      return false;
    }
    try {
      final profile = EngineProfile.parse(
        utf8.encode(canonicalJson(candidate.profile)),
      );
      return isEngineCompatible(profile, engineVersion) &&
          isProviderCompatible(profile, providerCliVersion);
    } on Object {
      return false;
    }
  }
}

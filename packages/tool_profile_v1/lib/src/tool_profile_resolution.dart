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

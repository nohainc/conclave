import 'dart:convert';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'worker_profile_store.dart';

export 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show
        ToolProfileResolutionSource,
        ToolProfileUnavailableReason,
        ToolProfileResolution,
        ToolProfileCompatibility;

/// Resolves the verified current V9 Profile, with one authorized last-known-good
/// snapshot available only when the current snapshot is unavailable.
class ToolProfileResolver {
  const ToolProfileResolver(this.store);
  final WorkerProfileStorePort store;

  Future<ToolProfileResolution<ToolProfileCandidate>> resolveForWorker({
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    String? providerCliVersion,
    Future<void> Function()? ensureAvailable,
  }) async {
    final draft = await store.developmentProfiles
        ?.load(profileDefinitionId, logicalWorkerTypeId);
    if (draft != null) {
      final result = _checkCandidate(draft,
          source: ToolProfileResolutionSource.draft,
          logicalWorkerTypeId: logicalWorkerTypeId,
          profileDefinitionId: profileDefinitionId,
          engineVersion: engineVersion,
          providerCliVersion: providerCliVersion);
      if (result.isAvailable || ensureAvailable == null) return result;
    }
    var result = await _resolveV9(
        logicalWorkerTypeId: logicalWorkerTypeId,
        profileDefinitionId: profileDefinitionId,
        engineVersion: engineVersion,
        providerCliVersion: providerCliVersion);
    if (!result.isAvailable && ensureAvailable != null) {
      await ensureAvailable();
      result = await _resolveV9(
          logicalWorkerTypeId: logicalWorkerTypeId,
          profileDefinitionId: profileDefinitionId,
          engineVersion: engineVersion,
          providerCliVersion: providerCliVersion);
    }
    return result;
  }

  Future<ToolProfileResolution<ToolProfileCandidate>> _resolveV9({
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    required String? providerCliVersion,
  }) async {
    WorkerProfileSnapshotAdmission? current;
    try {
      current = await store.currentWorkerProfile(logicalWorkerTypeId);
    } on WorkerProfileRevokedException {
      return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
          ToolProfileUnavailableReason.noEligibleRelease);
    } on Object catch (error) {
      // Keep the revocation fail-closed even when a Workspace binary has a
      // different copy of the transitional exception class loaded.
      if (error.toString().contains('Worker Profile is revoked')) {
        return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
            ToolProfileUnavailableReason.noEligibleRelease);
      }
      current = null;
    }
    if (current != null) {
      return _checkCandidate(current,
          source: ToolProfileResolutionSource.active,
          logicalWorkerTypeId: logicalWorkerTypeId,
          profileDefinitionId: profileDefinitionId,
          engineVersion: engineVersion,
          providerCliVersion: providerCliVersion);
    }
    final lastKnownGood =
        await store.lastKnownGoodWorkerProfile(logicalWorkerTypeId);
    if (lastKnownGood == null) {
      return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
          ToolProfileUnavailableReason.noEligibleRelease);
    }
    return _checkCandidate(lastKnownGood,
        source: ToolProfileResolutionSource.lastKnownGood,
        logicalWorkerTypeId: logicalWorkerTypeId,
        profileDefinitionId: profileDefinitionId,
        engineVersion: engineVersion,
        providerCliVersion: providerCliVersion);
  }

  ToolProfileResolution<ToolProfileCandidate> _checkCandidate(
    ToolProfileCandidate candidate, {
    required ToolProfileResolutionSource source,
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    required String? providerCliVersion,
  }) {
    if (candidate.logicalWorkerTypeId != logicalWorkerTypeId ||
        candidate.profileDefinitionId != profileDefinitionId) {
      return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
          ToolProfileUnavailableReason.noEligibleRelease);
    }
    try {
      final profile =
          EngineProfile.parse(utf8.encode(canonicalJson(candidate.profile)));
      if (!ToolProfileCompatibility.isEngineCompatible(
          profile, engineVersion)) {
        return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
            ToolProfileUnavailableReason.incompatibleEngineVersion);
      }
      if (providerCliVersion != null &&
          !ToolProfileCompatibility.isProviderCompatible(
              profile, providerCliVersion)) {
        return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
            ToolProfileUnavailableReason.unsupportedProviderVersion);
      }
      return ToolProfileResolution<ToolProfileCandidate>.selected(
          source: source, release: candidate);
    } on Object {
      return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
          ToolProfileUnavailableReason.noEligibleRelease);
    }
  }

  /// Legacy lifecycle APIs are intentionally unavailable after the V9
  /// cutover. Keeping a fail-closed stub avoids activating a pre-V9 cache
  /// through older readiness callers while they migrate to [resolveForWorker].
  Future<ToolProfileResolution<ToolProfileReleaseAdmission>>
      resolveBootstrapProfile({
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    String channel = 'stable',
  }) async =>
          const ToolProfileResolution<ToolProfileReleaseAdmission>.unavailable(
            ToolProfileUnavailableReason.noEligibleRelease,
          );

  Future<ToolProfileResolution<ToolProfileReleaseAdmission>> resolve({
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    required String providerCliVersion,
    String channel = 'stable',
  }) async =>
      const ToolProfileResolution<ToolProfileReleaseAdmission>.unavailable(
        ToolProfileUnavailableReason.noEligibleRelease,
      );

  bool isCompatibleRelease({
    required ToolProfileReleaseAdmission release,
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    String? providerCliVersion,
    String channel = 'stable',
  }) =>
      false;
}

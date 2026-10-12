import 'dart:convert';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

import 'tool_profile_release_store.dart';

export 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show
        ToolProfileResolutionSource,
        ToolProfileUnavailableReason,
        ToolProfileResolution,
        ToolProfileCompatibility;

/// Resolves signed cached Profiles, or explicit loopback development drafts.
/// V9 uses one current snapshot and, only when the current snapshot is
/// unavailable, one last-known-good snapshot. Legacy channel resolution stays
/// available only for pre-V9 cached installations during migration.
class ToolProfileResolver {
  const ToolProfileResolver(this.store);

  final ToolProfileReleaseStore store;

  /// Applies the same channel, provider-version, and bootstrap fallback used
  /// by Workspace readiness before selecting a Profile for an assignment.
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
      final profile =
          EngineProfile.parse(utf8.encode(canonicalJson(draft.profile)));
      if (!_engineCompatible(profile, engineVersion)) {
        return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
            ToolProfileUnavailableReason.incompatibleEngineVersion);
      }
      if (providerCliVersion != null &&
          !_providerCompatible(profile, providerCliVersion)) {
        return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
            ToolProfileUnavailableReason.unsupportedProviderVersion);
      }
      return ToolProfileResolution<ToolProfileCandidate>.selected(
          source: ToolProfileResolutionSource.draft, release: draft);
    }

    if (await store.hasWorkerProfileCache(logicalWorkerTypeId)) {
      var v9Result = await _resolveV9(
        logicalWorkerTypeId: logicalWorkerTypeId,
        profileDefinitionId: profileDefinitionId,
        engineVersion: engineVersion,
        providerCliVersion: providerCliVersion,
      );
      if (!v9Result.isAvailable && ensureAvailable != null) {
        await ensureAvailable();
        v9Result = await _resolveV9(
          logicalWorkerTypeId: logicalWorkerTypeId,
          profileDefinitionId: profileDefinitionId,
          engineVersion: engineVersion,
          providerCliVersion: providerCliVersion,
        );
      }
      return v9Result;
    }
    Future<ToolProfileResolution<ToolProfileReleaseAdmission>>
        resolveCurrent() async {
      final channel =
          (await store.releaseState(profileDefinitionId)).selectedChannel;
      var result = providerCliVersion == null
          ? await resolveBootstrapProfile(
              logicalWorkerTypeId: logicalWorkerTypeId,
              profileDefinitionId: profileDefinitionId,
              engineVersion: engineVersion,
              channel: channel,
            )
          : await resolve(
              logicalWorkerTypeId: logicalWorkerTypeId,
              profileDefinitionId: profileDefinitionId,
              engineVersion: engineVersion,
              providerCliVersion: providerCliVersion,
              channel: channel,
            );
      if (!result.isAvailable && providerCliVersion != null) {
        result = await resolveBootstrapProfile(
          logicalWorkerTypeId: logicalWorkerTypeId,
          profileDefinitionId: profileDefinitionId,
          engineVersion: engineVersion,
          channel: channel,
        );
      }
      return result;
    }

    var result = await resolveCurrent();
    if (!result.isAvailable && ensureAvailable != null) {
      await ensureAvailable();
      result = await resolveCurrent();
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
        ToolProfileUnavailableReason.noEligibleRelease,
      );
    } on Object {
      // A corrupt or incomplete current cache entry is unavailable. The
      // separately verified LKG may still be used under offline policy;
      // explicit revocation is handled above and never reaches this path.
      current = null;
    }
    if (current != null) {
      return _checkV9Candidate(
        current,
        source: ToolProfileResolutionSource.active,
        logicalWorkerTypeId: logicalWorkerTypeId,
        profileDefinitionId: profileDefinitionId,
        engineVersion: engineVersion,
        providerCliVersion: providerCliVersion,
      );
    }
    final lastKnownGood = await store.lastKnownGoodWorkerProfile(
      logicalWorkerTypeId,
    );
    if (lastKnownGood == null) {
      return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
        ToolProfileUnavailableReason.noEligibleRelease,
      );
    }
    return _checkV9Candidate(
      lastKnownGood,
      source: ToolProfileResolutionSource.lastKnownGood,
      logicalWorkerTypeId: logicalWorkerTypeId,
      profileDefinitionId: profileDefinitionId,
      engineVersion: engineVersion,
      providerCliVersion: providerCliVersion,
    );
  }

  ToolProfileResolution<ToolProfileCandidate> _checkV9Candidate(
    WorkerProfileSnapshotAdmission candidate, {
    required ToolProfileResolutionSource source,
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    required String? providerCliVersion,
  }) {
    if (candidate.logicalWorkerTypeId != logicalWorkerTypeId ||
        candidate.profileDefinitionId != profileDefinitionId) {
      return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
        ToolProfileUnavailableReason.noEligibleRelease,
      );
    }
    try {
      final profile = EngineProfile.parse(
        utf8.encode(canonicalJson(candidate.profile)),
      );
      if (!_engineCompatible(profile, engineVersion)) {
        return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
          ToolProfileUnavailableReason.incompatibleEngineVersion,
        );
      }
      if (providerCliVersion != null &&
          !_providerCompatible(profile, providerCliVersion)) {
        return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
          ToolProfileUnavailableReason.unsupportedProviderVersion,
        );
      }
      return ToolProfileResolution<ToolProfileCandidate>.selected(
        source: source,
        release: candidate,
      );
    } on Object {
      return const ToolProfileResolution<ToolProfileCandidate>.unavailable(
        ToolProfileUnavailableReason.noEligibleRelease,
      );
    }
  }

  /// Selects a verified, Engine-compatible Profile to run only its bounded
  /// version probe. The resulting provider version must be passed to [resolve]
  /// before the Profile is used for normal work.
  Future<ToolProfileResolution<ToolProfileReleaseAdmission>>
      resolveBootstrapProfile({
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    String channel = 'stable',
  }) async {
    if (!const {'stable', 'beta', 'testing'}.contains(channel)) {
      throw ArgumentError.value(channel, 'channel');
    }
    final candidates =
        <(ToolProfileResolutionSource, ToolProfileReleaseAdmission?)>[
      (
        ToolProfileResolutionSource.active,
        await store.activeRelease(profileDefinitionId)
      ),
      if (channel == 'stable')
        (
          ToolProfileResolutionSource.stable,
          await store.currentStableRelease(profileDefinitionId)
        ),
      (
        ToolProfileResolutionSource.lastKnownGood,
        await store.lastKnownGoodRelease(profileDefinitionId)
      ),
    ];
    var sawCandidate = false;
    for (final (source, candidate) in candidates) {
      if (candidate == null ||
          candidate.profileDefinitionId != profileDefinitionId ||
          candidate.logicalWorkerTypeId != logicalWorkerTypeId ||
          candidate.channel != channel) {
        continue;
      }
      sawCandidate = true;
      final profile = EngineProfile.parse(
        utf8.encode(canonicalJson(candidate.profile)),
      );
      if (_engineCompatible(profile, engineVersion)) {
        return ToolProfileResolution<ToolProfileReleaseAdmission>.selected(
            source: source, release: candidate);
      }
    }
    return ToolProfileResolution<ToolProfileReleaseAdmission>.unavailable(
      sawCandidate
          ? ToolProfileUnavailableReason.incompatibleEngineVersion
          : ToolProfileUnavailableReason.noEligibleRelease,
    );
  }

  Future<ToolProfileResolution<ToolProfileReleaseAdmission>> resolve({
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    required String providerCliVersion,
    String channel = 'stable',
  }) async {
    if (!const {'stable', 'beta', 'testing'}.contains(channel)) {
      throw ArgumentError.value(channel, 'channel');
    }
    final candidates =
        <(ToolProfileResolutionSource, ToolProfileReleaseAdmission?)>[
      (
        ToolProfileResolutionSource.active,
        await store.activeRelease(profileDefinitionId)
      ),
      if (channel == 'stable')
        (
          ToolProfileResolutionSource.stable,
          await store.currentStableRelease(profileDefinitionId)
        ),
      (
        ToolProfileResolutionSource.lastKnownGood,
        await store.lastKnownGoodRelease(profileDefinitionId)
      ),
    ];
    final checkedVersions = <int>{};
    var engineMismatch = false;
    var providerMismatch = false;
    for (final (source, candidate) in candidates) {
      if (candidate == null || !checkedVersions.add(candidate.releaseVersion)) {
        continue;
      }
      if (candidate.profileDefinitionId != profileDefinitionId ||
          candidate.logicalWorkerTypeId != logicalWorkerTypeId ||
          candidate.channel != channel) {
        continue;
      }
      final profile = EngineProfile.parse(
        utf8.encode(canonicalJson(candidate.profile)),
      );
      if (!_engineCompatible(profile, engineVersion)) {
        engineMismatch = true;
        continue;
      }
      if (!_providerCompatible(profile, providerCliVersion)) {
        providerMismatch = true;
        continue;
      }
      return ToolProfileResolution<ToolProfileReleaseAdmission>.selected(
          source: source, release: candidate);
    }
    if (providerMismatch) {
      return const ToolProfileResolution<
          ToolProfileReleaseAdmission>.unavailable(
        ToolProfileUnavailableReason.unsupportedProviderVersion,
      );
    }
    if (engineMismatch) {
      return const ToolProfileResolution<
          ToolProfileReleaseAdmission>.unavailable(
        ToolProfileUnavailableReason.incompatibleEngineVersion,
      );
    }
    return const ToolProfileResolution<ToolProfileReleaseAdmission>.unavailable(
      ToolProfileUnavailableReason.noEligibleRelease,
    );
  }

  bool isCompatibleRelease({
    required ToolProfileReleaseAdmission release,
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
    String? providerCliVersion,
    String channel = 'stable',
  }) {
    if (release.logicalWorkerTypeId != logicalWorkerTypeId ||
        release.profileDefinitionId != profileDefinitionId ||
        release.channel != channel) {
      return false;
    }
    try {
      final profile = EngineProfile.parse(
        utf8.encode(canonicalJson(release.profile)),
      );
      return _engineCompatible(profile, engineVersion) &&
          (providerCliVersion == null ||
              _providerCompatible(profile, providerCliVersion));
    } on Object {
      return false;
    }
  }

  bool _engineCompatible(EngineProfile profile, String version) =>
      ToolProfileCompatibility.isEngineCompatible(profile, version);

  bool _providerCompatible(EngineProfile profile, String version) =>
      ToolProfileCompatibility.isProviderCompatible(profile, version);
}

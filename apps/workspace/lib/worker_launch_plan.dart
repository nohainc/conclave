import 'dart:async';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

import 'tool_profile_resolver.dart';
import 'worker_profile_store.dart';

/// Everything needed to start a Worker's Engine, prepared before any
/// assignment asks for it: the verified executable Profile snapshot, the
/// immutable execution file Engine reads, and the compatibility inputs it was
/// validated against.
///
/// A plan is immutable. An assignment pins the plan it was admitted with, so a
/// later Profile activation, rollback or catalog refresh cannot change what an
/// accepted (possibly queued) assignment launches.
final class WorkerLaunchPlan {
  const WorkerLaunchPlan({
    required this.workerTypeId,
    required this.profileDefinitionId,
    required this.release,
    required this.profileFile,
    required this.source,
    required this.engineVersion,
    required this.providerCliVersion,
    required this.preparedAt,
  });

  final String workerTypeId;
  final String profileDefinitionId;
  final ToolProfileCandidate release;
  final File profileFile;
  final ToolProfileResolutionSource source;
  final String engineVersion;
  final String? providerCliVersion;
  final DateTime preparedAt;

  String get profileDigest => release.payloadDigest;
  int get profileRevision => release.revision;

  /// A stable, non-secret identity for diagnostics and Cloud stage updates.
  String get profileIdentity => '$workerTypeId@$profileRevision:$profileDigest';
}

/// Why no launch plan is available. Distinct reasons let the caller return a
/// specific, prompt error instead of waiting for an unrelated refresh.
enum WorkerLaunchUnavailable {
  /// No verified, non-revoked Profile snapshot exists locally.
  noProfile,

  /// The Profile exists but is not compatible with this Engine version.
  incompatibleEngine,

  /// The installed provider CLI version is not supported by the Profile.
  unsupportedProviderVersion,

  /// The Profile resolved but its execution file could not be prepared.
  profileFileUnavailable,
}

final class WorkerLaunchPlanResult {
  const WorkerLaunchPlanResult.ready(WorkerLaunchPlan this.plan,
      {this.fromCache = false})
      : unavailable = null;
  const WorkerLaunchPlanResult.unavailable(
      WorkerLaunchUnavailable this.unavailable,
      {this.fromCache = false})
      : plan = null;

  final WorkerLaunchPlan? plan;
  final WorkerLaunchUnavailable? unavailable;
  final bool fromCache;

  bool get isReady => plan != null;

  WorkerLaunchPlanResult asCached() => plan != null
      ? WorkerLaunchPlanResult.ready(plan!, fromCache: true)
      : WorkerLaunchPlanResult.unavailable(unavailable!, fromCache: true);
}

/// Caches validated launch plans so the assignment hot path performs no
/// network call, no signature verification and no catalog refresh.
///
/// A cached entry is keyed by Worker type, Profile definition, Engine version
/// and provider CLI version, and carries the store's state fingerprint taken
/// before the entry was prepared. Every lookup compares that fingerprint with
/// the store's current one (two file stats and the revocation revision), so a
/// Profile activation, rollback, last-known-good change or revocation is
/// noticed on the next lookup without any explicit invalidation. Local
/// permission and provider CLI changes arrive as different inputs and miss the
/// cache by construction.
class WorkerLaunchPlanCache {
  WorkerLaunchPlanCache({
    required this.store,
    required this.engineVersion,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final WorkerProfileStorePort store;
  final String engineVersion;
  final DateTime Function() _clock;

  final _entries = <String, _CachedPlan>{};
  final _preparing = <String, Future<WorkerLaunchPlanResult>>{};

  int _hits = 0;
  int _misses = 0;

  /// Lookups answered from memory. Telemetry only.
  int get hitCount => _hits;

  /// Lookups that had to prepare a plan from local files. Telemetry only.
  int get missCount => _misses;

  /// Returns the launch plan for [workerTypeId], preparing it from local state
  /// when it is not cached or the Profile state changed. Never contacts Cloud.
  Future<WorkerLaunchPlanResult> resolve({
    required String workerTypeId,
    required String profileDefinitionId,
    String? providerCliVersion,
  }) async {
    // Unsigned development drafts are read live so edits apply immediately.
    if (store.developmentProfiles != null) {
      _misses += 1;
      return _prepare(
        workerTypeId: workerTypeId,
        profileDefinitionId: profileDefinitionId,
        providerCliVersion: providerCliVersion,
      );
    }
    // Load persisted revocations before fingerprinting so the first entry is
    // keyed by the revocation state it was actually validated against.
    await store.restoreRevocations();
    final key = '$workerTypeId|$profileDefinitionId|$providerCliVersion|'
        '$engineVersion';
    final fingerprint = store.profileStateFingerprint(workerTypeId);
    final cached = _entries[key];
    if (cached != null && cached.fingerprint == fingerprint) {
      _hits += 1;
      return cached.result.asCached();
    }
    final preparingKey = '$key|$fingerprint';
    final inFlight = _preparing[preparingKey];
    if (inFlight != null) return inFlight;
    _misses += 1;
    final operation = _prepare(
      workerTypeId: workerTypeId,
      profileDefinitionId: profileDefinitionId,
      providerCliVersion: providerCliVersion,
    ).then((result) {
      // A failed preparation (for example an unreadable cache file) is not
      // remembered, so the next lookup retries from disk.
      if (result.unavailable !=
          WorkerLaunchUnavailable.profileFileUnavailable) {
        _entries[key] = _CachedPlan(fingerprint, result);
      }
      return result;
    }).whenComplete(() {
      // A block body: returning the removed Future from `whenComplete` would
      // make this operation wait for itself.
      _preparing.remove(preparingKey);
    });
    _preparing[preparingKey] = operation;
    return operation;
  }

  /// Prepares the plan ahead of any assignment (startup, Profile activation).
  /// Failures are not errors here: the hot path reports them when needed.
  Future<void> warm({
    required String workerTypeId,
    required String profileDefinitionId,
    String? providerCliVersion,
  }) async {
    try {
      await resolve(
        workerTypeId: workerTypeId,
        profileDefinitionId: profileDefinitionId,
        providerCliVersion: providerCliVersion,
      );
    } on Object {
      // Warming is best effort.
    }
  }

  /// Drops every cached plan for [workerTypeId]. The fingerprint check already
  /// makes this unnecessary for correctness; it only releases memory.
  void invalidate(String workerTypeId) {
    _entries.removeWhere((key, _) => key.startsWith('$workerTypeId|'));
  }

  Future<WorkerLaunchPlanResult> _prepare({
    required String workerTypeId,
    required String profileDefinitionId,
    required String? providerCliVersion,
  }) async {
    final ToolProfileResolution<ToolProfileCandidate> resolution;
    try {
      // No `ensureAvailable`: a missing Profile is reported, never fetched.
      resolution = await ToolProfileResolver(store).resolveForWorker(
        logicalWorkerTypeId: workerTypeId,
        profileDefinitionId: profileDefinitionId,
        engineVersion: engineVersion,
        providerCliVersion: providerCliVersion,
      );
    } on Object {
      return const WorkerLaunchPlanResult.unavailable(
          WorkerLaunchUnavailable.noProfile);
    }
    final release = resolution.release;
    if (!resolution.isAvailable || release == null) {
      return WorkerLaunchPlanResult.unavailable(switch (resolution.reason) {
        ToolProfileUnavailableReason.incompatibleEngineVersion =>
          WorkerLaunchUnavailable.incompatibleEngine,
        ToolProfileUnavailableReason.unsupportedProviderVersion =>
          WorkerLaunchUnavailable.unsupportedProviderVersion,
        _ => WorkerLaunchUnavailable.noProfile,
      });
    }
    final File profileFile;
    try {
      profileFile = await store.executionProfileFile(release);
    } on Object {
      return const WorkerLaunchPlanResult.unavailable(
          WorkerLaunchUnavailable.profileFileUnavailable);
    }
    return WorkerLaunchPlanResult.ready(WorkerLaunchPlan(
      workerTypeId: workerTypeId,
      profileDefinitionId: profileDefinitionId,
      release: release,
      profileFile: profileFile,
      source: resolution.source,
      engineVersion: engineVersion,
      providerCliVersion: providerCliVersion,
      preparedAt: _clock(),
    ));
  }
}

final class _CachedPlan {
  const _CachedPlan(this.fingerprint, this.result);
  final String fingerprint;
  final WorkerLaunchPlanResult result;
}

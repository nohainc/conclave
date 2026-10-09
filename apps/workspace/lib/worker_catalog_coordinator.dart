import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart'
    show SafeProviderDiagnostics;

import 'cli_worker_engine_supervisor.dart';
import 'local_worker_registry.dart';
import 'tool_profile_catalog.dart';
import 'tool_profile_release_store.dart';
import 'tool_profile_release_verifier.dart';
import 'tool_profile_resolver.dart';
import 'worker_inventory_projection.dart';
import 'workspace_worker_view.dart';

class WorkerCatalogSnapshot {
  const WorkerCatalogSnapshot({
    this.descriptors = const [],
    this.workers = const [],
    this.profiles = const {},
    this.catalogError,
    this.catalogConfirmed = false,
    this.refreshing = false,
    this.localRegistryLoaded = false,
    this.localRegistryError,
  });

  final List<WorkerDescriptor> descriptors;
  final List<WorkerCatalogWorkerState> workers;
  final Map<String, WorkerProfileResolution> profiles;
  final String? catalogError;
  final bool catalogConfirmed;
  final bool refreshing;
  final bool localRegistryLoaded;
  final String? localRegistryError;
}

/// Owns the Workspace catalog -> Profile -> readiness synchronization pipeline.
class WorkerCatalogCoordinator extends ChangeNotifier {
  WorkerCatalogCoordinator({
    required this.catalog,
    required this.releaseStore,
    this.registry,
    this.onCatalogReconciled,
    this.refreshReadiness,
    this.refreshExecutor,
    this.refreshInterval = const Duration(minutes: 10),
    this.minimumRefreshInterval = const Duration(minutes: 1),
  });

  final ToolProfileCatalogClient catalog;
  final ToolProfileReleaseStore releaseStore;
  final LocalWorkerRegistry? registry;
  final Future<void> Function()? onCatalogReconciled;
  final Future<void> Function()? refreshReadiness;
  final Future<void> Function(Future<void> Function())? refreshExecutor;
  final Duration refreshInterval;
  final Duration minimumRefreshInterval;

  WorkerCatalogSnapshot _snapshot = const WorkerCatalogSnapshot();
  WorkerCatalogSnapshot get snapshot => _snapshot;
  Future<void>? _activeRefresh;
  final Map<String, Future<void>> _activeProfileSyncs = {};
  List<LocalWorker> _localWorkers = const [];
  bool _localRegistryLoaded = false;
  String? _localRegistryError;
  DateTime? _lastRefreshAt;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool _refreshingReadiness = false;

  WorkerDescriptor? entryForWorker(String workerTypeId) =>
      catalog.entryForWorker(workerTypeId);

  String? profileDefinitionForWorker(String workerTypeId) =>
      catalog.profileDefinitionForWorker(workerTypeId);

  Future<ToolProfileResolution<ToolProfileCandidate>> resolveProfileForWorker({
    required String workerTypeId,
    required String engineVersion,
    String? providerCliVersion,
    bool synchronizeIfUnavailable = true,
  }) async {
    final descriptor = await ensureCatalogEntry(workerTypeId);
    if (descriptor == null) {
      return const ToolProfileResolution<
          ToolProfileReleaseAdmission>.unavailable(
        ToolProfileUnavailableReason.noEligibleRelease,
      );
    }
    return ToolProfileResolver(releaseStore).resolveForWorker(
      logicalWorkerTypeId: workerTypeId,
      profileDefinitionId: descriptor.profileDefinitionId,
      engineVersion: engineVersion,
      providerCliVersion: providerCliVersion,
      ensureAvailable: synchronizeIfUnavailable
          ? () => ensureWorkerProfileAvailable(
                workerTypeId,
                waitForActiveRefresh: true,
              )
          : null,
    );
  }

  Future<List<Map<String, Object?>>> inventoryForWorkers(
    Iterable<LocalWorker> workers, {
    required String engineVersion,
    required bool engineAvailable,
  }) async {
    final lastSeenAt = DateTime.now().toUtc().toIso8601String();
    final projected = await Future.wait(workers.map((worker) async {
      final descriptor = entryForWorker(worker.workerTypeId);
      if (descriptor == null) return null;
      ToolProfileCandidate? eligibleProfile;
      if (engineAvailable) {
        try {
          eligibleProfile = (await resolveProfileForWorker(
            workerTypeId: worker.workerTypeId,
            engineVersion: engineVersion,
            providerCliVersion: worker.toolVersion,
            synchronizeIfUnavailable: false,
          ))
              .release;
        } on Object {
          // Invalid or unavailable local Profile evidence is non-ready.
        }
      }
      return spaceWorkerInventory(
        worker: worker,
        descriptor: descriptor,
        eligibleProfile: eligibleProfile,
        engineVersion: engineAvailable ? engineVersion : null,
        lastSeenAt: lastSeenAt,
      );
    }));
    return projected.whereType<Map<String, Object?>>().toList();
  }

  /// Reloads the local registry and republishes render-ready Worker states.
  /// Registry mutations call this through the runtime's onChanged hook.
  Future<void> refreshLocalWorkers() async {
    final currentRegistry = registry;
    try {
      _localWorkers = await currentRegistry?.list() ?? const <LocalWorker>[];
      _localRegistryLoaded = currentRegistry != null;
      _localRegistryError = null;
    } on Object catch (error) {
      _localWorkers = const [];
      _localRegistryLoaded = true;
      _localRegistryError = 'Local Worker state could not be loaded: $error';
    }
    _publish(
      _snapshot.copyWith(
        workers: _buildWorkerStates(),
        localRegistryLoaded: _localRegistryLoaded,
        localRegistryError: _localRegistryError,
        clearLocalRegistryError: _localRegistryError == null,
      ),
      _generation,
    );
  }

  List<WorkerCatalogWorkerState> _buildWorkerStates({
    List<WorkerDescriptor>? descriptors,
    Map<String, WorkerProfileResolution>? profiles,
    bool? catalogConfirmed,
  }) {
    final currentDescriptors = descriptors ?? _snapshot.descriptors;
    final currentProfiles = profiles ?? _snapshot.profiles;
    final isCatalogConfirmed = catalogConfirmed ?? _snapshot.catalogConfirmed;
    final views = currentDescriptors.map((descriptor) {
      final worker = _localWorkers
          .where((record) => record.workerTypeId == descriptor.workerTypeId)
          .firstOrNull;
      final profile = currentProfiles[descriptor.workerTypeId] ??
          const WorkerProfileResolution(
            state: WorkspaceWorkerProfileState.resolving,
          );
      final localState = !_localRegistryLoaded
          ? WorkspaceLocalWorkerState.loading
          : _localRegistryError != null
              ? WorkspaceLocalWorkerState.unavailable
              : worker == null
                  ? WorkspaceLocalWorkerState.notConfigured
                  : WorkspaceLocalWorkerState.configured;
      return WorkerCatalogWorkerState(
        descriptor: descriptor,
        catalogRetired: false,
        localWorker: worker,
        localState: localState,
        profileAvailability: profile,
        providerToolState: _providerToolState(worker),
      );
    }).toList();
    if (isCatalogConfirmed) {
      final currentTypes =
          currentDescriptors.map((worker) => worker.workerTypeId).toSet();
      for (final worker in _localWorkers.where(
        (worker) => !currentTypes.contains(worker.workerTypeId),
      )) {
        views.add(WorkerCatalogWorkerState(
          descriptor: null,
          catalogRetired: true,
          localWorker: worker,
          localState: WorkspaceLocalWorkerState.configured,
          profileAvailability: const WorkerProfileResolution(
            state: WorkspaceWorkerProfileState.unavailable,
            message: 'Worker is no longer in the current Cloud catalog.',
          ),
          providerToolState: _providerToolState(worker),
        ));
      }
    }
    return List.unmodifiable(views);
  }

  WorkspaceProviderToolState _providerToolState(LocalWorker? worker) {
    if (worker == null) return WorkspaceProviderToolState.unknown;
    if (worker.readinessIssueCode == 'cli_not_found' ||
        worker.lastLiveTestIssueCode == 'cli_not_found') {
      return WorkspaceProviderToolState.missing;
    }
    return worker.toolVersion != null
        ? WorkspaceProviderToolState.available
        : WorkspaceProviderToolState.unknown;
  }

  /// Excludes retained local records whose Worker Type is no longer in the
  /// last-known-good or authoritative catalog before reporting inventory.
  List<LocalWorker> inventoryEligibleWorkers(Iterable<LocalWorker> workers) =>
      workers
          .where((worker) => entryForWorker(worker.workerTypeId) != null)
          .toList();

  /// Resolves assignment eligibility against the newest known authoritative
  /// catalog. A locally cached entry remains usable offline; absence is
  /// authoritative only after a successful catalog synchronization.
  Future<WorkerDescriptor?> ensureCatalogEntry(String workerTypeId) async {
    var entry = entryForWorker(workerTypeId);
    if (entry != null || _snapshot.catalogConfirmed) return entry;

    final activeRefresh = _activeRefresh;
    if (activeRefresh != null) {
      await activeRefresh;
    } else {
      await refresh(force: true);
    }
    entry = entryForWorker(workerTypeId);
    return entry;
  }

  void start() {
    if (_timer != null) return;
    unawaited(refreshLocalWorkers());
    unawaited(refresh());
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
  }

  Future<void> refresh({bool force = false}) {
    final active = _activeRefresh;
    if (active != null) return active;
    final lastRefreshAt = _lastRefreshAt;
    if (!force &&
        lastRefreshAt != null &&
        DateTime.now().difference(lastRefreshAt) < minimumRefreshInterval) {
      return Future<void>.value();
    }
    _publish(_snapshot.copyWith(refreshing: true), _generation);
    final operation = refreshExecutor == null
        ? _refreshCatalogAndProfiles()
        : refreshExecutor!(_refreshCatalogAndProfiles);
    _activeRefresh = operation;
    return operation.whenComplete(() {
      if (identical(_activeRefresh, operation)) _activeRefresh = null;
      _lastRefreshAt = DateTime.now();
    });
  }

  Future<void> _refreshCatalogAndProfiles() async {
    await refreshLocalWorkers();
    var generation = ++_generation;
    var cached = _snapshot.descriptors;
    Future<void>? cachedProfileResolution;
    try {
      cached = await catalog.loadCatalog();
      if (cached.isNotEmpty) {
        _publishCatalog(cached, generation, refreshing: true);
        await _notifyCatalogReconciled();
        cachedProfileResolution = _resolveProfiles(cached, generation);
      }
    } on Object {
      // A malformed cache is ignored; the Cloud catalog remains authoritative.
    }

    List<WorkerDescriptor> current;
    String? catalogError;
    var catalogConfirmed = false;
    if (!catalog.canSyncCatalogRemotely) {
      // A disconnected Workspace has no runtime identity for the Cloud
      // endpoint. Keep the last known catalog (or local in-memory state)
      // visible without surfacing that expected state as an error.
      current = catalog.workers.isNotEmpty ? catalog.workers : cached;
    } else {
      try {
        current = await catalog.syncCatalog();
        catalogConfirmed = true;
      } on Object catch (error) {
        current = catalog.workers.isNotEmpty ? catalog.workers : cached;
        catalogError = 'Cloud Worker catalog could not be loaded: $error';
      }
    }

    generation = ++_generation;
    _publishCatalog(
      current,
      generation,
      catalogError: catalogError,
      refreshing: true,
      catalogConfirmed: catalogConfirmed,
    );
    await _notifyCatalogReconciled();
    await cachedProfileResolution;
    await _syncAndResolveProfiles(current, generation);
    _refreshingReadiness = true;
    try {
      await refreshReadiness?.call();
    } on Object {
      // Keep catalog/Profile state; the next readiness cycle retries probes.
    } finally {
      _refreshingReadiness = false;
    }
    await refreshLocalWorkers();
    _publish(
      _snapshot.copyWith(refreshing: false),
      generation,
    );
  }

  Future<void> _notifyCatalogReconciled() async {
    try {
      await onCatalogReconciled?.call();
    } on Object {
      // Inventory transport failure does not invalidate local catalog state.
    }
  }

  /// Ensures a single assignment/readiness fallback uses the same Profile
  /// synchronization and selection policy as the full catalog refresh.
  Future<void> ensureWorkerProfileAvailable(
    String workerTypeId, {
    bool waitForActiveRefresh = false,
  }) async {
    if (_refreshingReadiness) return;
    final activeRefresh = _activeRefresh;
    if (activeRefresh != null) {
      if (waitForActiveRefresh) await activeRefresh;
      return;
    }
    var entry = catalog.entryForWorker(workerTypeId);
    if (entry == null) {
      try {
        final current = await catalog.syncCatalog();
        final generation = ++_generation;
        _publishCatalog(current, generation, catalogConfirmed: true);
        entry = current
            .where((worker) => worker.workerTypeId == workerTypeId)
            .firstOrNull;
      } on Object {
        return;
      }
    }
    if (entry == null) return;
    await _syncAndResolveWorker(entry, _generation);
  }

  Future<void> _syncAndResolveProfiles(
    List<WorkerDescriptor> workers,
    int generation,
  ) async {
    for (final worker in workers) {
      await _syncAndResolveWorker(worker, generation);
    }
  }

  Future<void> _syncAndResolveWorker(
    WorkerDescriptor worker,
    int generation,
  ) {
    final active = _activeProfileSyncs[worker.workerTypeId];
    if (active != null) return active;
    final operation = _runProfileSync(worker, generation);
    _activeProfileSyncs[worker.workerTypeId] = operation;
    return operation.whenComplete(() {
      if (identical(_activeProfileSyncs[worker.workerTypeId], operation)) {
        _activeProfileSyncs.remove(worker.workerTypeId);
      }
    });
  }

  Future<void> _runProfileSync(
    WorkerDescriptor worker,
    int generation,
  ) async {
    _setProfile(
      worker.workerTypeId,
      const WorkerProfileResolution(
        state: WorkspaceWorkerProfileState.syncing,
      ),
      generation,
    );
    try {
      await catalog.syncWorkerProfiles(worker.workerTypeId);
    } on Object catch (error) {
      // A verified cached Profile can remain usable when Cloud is unavailable.
      await _resolveAndSetProfile(worker, generation);
      final cached = _snapshot.profiles[worker.workerTypeId];
      if (cached?.state != WorkspaceWorkerProfileState.ready) {
        _setProfile(
            worker.workerTypeId,
            WorkerProfileResolution(
              state: WorkspaceWorkerProfileState.error,
              message:
                  'Profile download failed: ${SafeProviderDiagnostics.redact(error.toString())}',
            ),
            generation);
      }
      return;
    }
    await _resolveAndSetProfile(worker, generation);
  }

  Future<void> _resolveProfiles(
    List<WorkerDescriptor> workers,
    int generation,
  ) async {
    for (final worker in workers) {
      await _resolveAndSetProfile(worker, generation);
    }
  }

  Future<void> _resolveAndSetProfile(
    WorkerDescriptor entry,
    int generation,
  ) async {
    List<LocalWorker> workers = const [];
    try {
      workers = await registry?.list() ?? const <LocalWorker>[];
    } on Object {
      // Catalog and local Profile state remain visible during registry errors.
    }
    final worker = workers
        .where((item) => item.workerTypeId == entry.workerTypeId)
        .firstOrNull;
    final definitionId = entry.profileDefinitionId;
    try {
      final resolver = ToolProfileResolver(releaseStore);
      final profileState = await releaseStore.releaseState(definitionId);
      final resolution = await resolver.resolveForWorker(
        logicalWorkerTypeId: entry.workerTypeId,
        profileDefinitionId: definitionId,
        engineVersion: cliWorkerEngineVersion,
        providerCliVersion: worker?.toolVersion,
      );
      if (!resolution.isAvailable) {
        final incompatible = resolution.reason ==
                ToolProfileUnavailableReason.unsupportedProviderVersion ||
            resolution.reason ==
                ToolProfileUnavailableReason.incompatibleEngineVersion;
        _setProfile(
          entry.workerTypeId,
          WorkerProfileResolution(
            state: incompatible
                ? WorkspaceWorkerProfileState.incompatible
                : WorkspaceWorkerProfileState.unavailable,
            message: switch (resolution.reason) {
              ToolProfileUnavailableReason.noEligibleRelease =>
                'No eligible signed Profile release is downloaded.',
              ToolProfileUnavailableReason.unsupportedProviderVersion =>
                'The installed Provider CLI version is not supported by a Profile release.',
              ToolProfileUnavailableReason.incompatibleEngineVersion =>
                'No downloaded Profile release is compatible with this Engine version.',
              null => 'No compatible Profile release is available.',
            },
          ),
          generation,
        );
        return;
      }
      _setProfile(
        entry.workerTypeId,
        WorkerProfileResolution(
          state: WorkspaceWorkerProfileState.ready,
          details: {
            'definitionId': definitionId,
            'source': resolution.source.name,
            'unsignedDevelopment': resolution.release?.isSigned == false,
            'activeVersion': profileState.activeVersion,
            'lastKnownGoodVersion': profileState.lastKnownGoodVersion,
            'channel': profileState.selectedChannel,
            if (resolution.release != null)
              'releaseVersion': resolution.release!.releaseVersion,
          },
        ),
        generation,
      );
    } on Object {
      _setProfile(
        entry.workerTypeId,
        const WorkerProfileResolution(
          state: WorkspaceWorkerProfileState.error,
          message: 'A local Profile release could not be resolved.',
        ),
        generation,
      );
    }
  }

  void _publishCatalog(
    List<WorkerDescriptor> workers,
    int generation, {
    String? catalogError,
    bool refreshing = false,
    bool catalogConfirmed = false,
  }) {
    final previous = _snapshot.profiles;
    final previousDefinitions = {
      for (final worker in _snapshot.descriptors)
        worker.workerTypeId: worker.profileDefinitionId,
    };
    final nextProfiles = {
      for (final worker in workers)
        worker.workerTypeId: previousDefinitions[worker.workerTypeId] ==
                worker.profileDefinitionId
            ? previous[worker.workerTypeId] ??
                const WorkerProfileResolution(
                  state: WorkspaceWorkerProfileState.resolving,
                )
            : const WorkerProfileResolution(
                state: WorkspaceWorkerProfileState.resolving,
              ),
    };
    final confirmed = catalogConfirmed || _snapshot.catalogConfirmed;
    _publish(
      WorkerCatalogSnapshot(
        descriptors: List.unmodifiable(workers),
        workers: _buildWorkerStates(
          descriptors: workers,
          profiles: nextProfiles,
          catalogConfirmed: confirmed,
        ),
        profiles: nextProfiles,
        catalogError: catalogError,
        catalogConfirmed: confirmed,
        refreshing: refreshing,
        localRegistryLoaded: _snapshot.localRegistryLoaded,
        localRegistryError: _snapshot.localRegistryError,
      ),
      generation,
    );
  }

  void _setProfile(
    String workerTypeId,
    WorkerProfileResolution resolution,
    int generation,
  ) {
    final profiles = Map<String, WorkerProfileResolution>.from(
      _snapshot.profiles,
    )..[workerTypeId] = resolution;
    _publish(
      _snapshot.copyWith(
        profiles: profiles,
        workers: _buildWorkerStates(profiles: profiles),
      ),
      generation,
    );
  }

  void _publish(WorkerCatalogSnapshot snapshot, int generation) {
    if (_disposed || generation != _generation) return;
    _snapshot = snapshot;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

extension on WorkerCatalogSnapshot {
  WorkerCatalogSnapshot copyWith({
    List<WorkerDescriptor>? descriptors,
    List<WorkerCatalogWorkerState>? workers,
    Map<String, WorkerProfileResolution>? profiles,
    String? catalogError,
    bool clearCatalogError = false,
    bool? catalogConfirmed,
    bool? refreshing,
    bool? localRegistryLoaded,
    String? localRegistryError,
    bool clearLocalRegistryError = false,
  }) =>
      WorkerCatalogSnapshot(
        descriptors: descriptors ?? this.descriptors,
        workers: workers ?? this.workers,
        profiles: profiles ?? this.profiles,
        catalogError:
            clearCatalogError ? null : catalogError ?? this.catalogError,
        catalogConfirmed: catalogConfirmed ?? this.catalogConfirmed,
        refreshing: refreshing ?? this.refreshing,
        localRegistryLoaded: localRegistryLoaded ?? this.localRegistryLoaded,
        localRegistryError: clearLocalRegistryError
            ? null
            : localRegistryError ?? this.localRegistryError,
      );
}

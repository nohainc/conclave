import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_worker_registry.dart';
import 'tool_profile_catalog.dart';
import 'worker_catalog_coordinator.dart';
import 'workspace_notifier.dart';
import 'workspace_worker_view.dart';

typedef WorkspaceManagerRequest = Future<Object?> Function(
  String command, {
  Map<String, Object?> payload,
});

/// UI-facing Worker catalog projection backed only by Workspace Manager IPC.
class IpcWorkspaceWorkerCatalog extends WorkspaceNotifier
    implements WorkspaceWorkerCatalogClient {
  IpcWorkspaceWorkerCatalog(this._request, {File? cacheFile})
      : _cacheFile = cacheFile {
    try {
      if (cacheFile != null && cacheFile.existsSync()) {
        _snapshot = _decodeSnapshot(Map<String, Object?>.from(
            jsonDecode(cacheFile.readAsStringSync()) as Map));
      }
    } on Object {
      // A missing or damaged display cache never affects service state.
    }
  }

  final File? _cacheFile;

  final WorkspaceManagerRequest _request;
  WorkerCatalogSnapshot _snapshot = const WorkerCatalogSnapshot();

  @override
  WorkerCatalogSnapshot get snapshot => _snapshot;

  @override
  WorkerDescriptor? entryForWorker(String workerTypeId) => _snapshot.descriptors
      .where((entry) => entry.workerTypeId == workerTypeId)
      .firstOrNull;

  @override
  Future<void> refresh({bool force = false}) async {
    try {
      final result = await _request(
        force ? 'workers.refreshCatalog' : 'workers.getCatalogSnapshot',
        payload: const {},
      );
      if (result is Map) acceptSnapshot(Map<String, Object?>.from(result));
    } on Object catch (error) {
      _snapshot = WorkerCatalogSnapshot(
        descriptors: _snapshot.descriptors,
        workers: _snapshot.workers,
        catalogConfirmed: _snapshot.catalogConfirmed,
        catalogError: error.toString(),
        localRegistryLoaded: _snapshot.localRegistryLoaded,
        localRegistryError: _snapshot.localRegistryError,
      );
      notifyListeners();
    }
  }

  void acceptSnapshot(Map<String, Object?> value) {
    _snapshot = _decodeSnapshot(value);
    try {
      final cacheFile = _cacheFile;
      if (cacheFile != null) {
        cacheFile.parent.createSync(recursive: true);
        final temporary = File('${cacheFile.path}.tmp');
        temporary.writeAsStringSync(jsonEncode(value));
        temporary.renameSync(cacheFile.path);
      }
    } on Object {
      // Display caching is best-effort; IPC remains authoritative.
    }
    notifyListeners();
  }

  @override
  Future<void> refreshLocalWorkers() => refresh();

  @override
  Future<void> ensureWorkerProfileAvailable(
    String workerTypeId, {
    bool waitForActiveRefresh = false,
  }) async {
    await _request('workers.ensureProfile', payload: {
      'workerTypeId': workerTypeId,
      'waitForActiveRefresh': waitForActiveRefresh,
    });
    await refresh();
  }

  Future<void> configureWorker(String workerTypeId) async {
    await _request('workers.configureWorker', payload: {
      'workerTypeId': workerTypeId,
    });
    await refresh();
  }

  Future<void> setEnabled(String workerId, bool enabled) async {
    await _request(
      enabled ? 'workers.enableWorker' : 'workers.disableWorker',
      payload: {'workerId': workerId},
    );
    await refresh();
  }

  static WorkerCatalogSnapshot _decodeSnapshot(Map<String, Object?> json) {
    List<WorkerDescriptor> descriptorsFrom(Object? value) {
      if (value is! List) return const [];
      return value
          .whereType<Map>()
          .map((item) => WorkerDescriptor.fromJson(
                Map<String, Object?>.from(item),
              ))
          .toList(growable: false);
    }

    T enumValue<T extends Enum>(List<T> values, Object? value, T fallback) =>
        values.where((item) => item.name == value).firstOrNull ?? fallback;

    final descriptors = descriptorsFrom(json['descriptors']);
    final rawViews = json['views'];
    final views = <WorkerCatalogWorkerState>[];
    if (rawViews is List) {
      for (final raw in rawViews.whereType<Map>()) {
        final value = Map<String, Object?>.from(raw);
        final descriptorJson = value['descriptor'];
        final workerJson = value['localWorker'];
        final descriptor = descriptorJson is Map
            ? WorkerDescriptor.fromJson(
                Map<String, Object?>.from(descriptorJson))
            : null;
        final worker = workerJson is Map
            ? LocalWorker.fromJson(Map<String, dynamic>.from(workerJson))
            : null;
        final profileDetails = value['profileDetails'];
        views.add(WorkerCatalogWorkerState(
          descriptor: descriptor,
          catalogRetired: value['catalogRetired'] == true,
          localWorker: worker,
          localState: enumValue(
            WorkspaceLocalWorkerState.values,
            value['localState'],
            WorkspaceLocalWorkerState.unavailable,
          ),
          profileAvailability: WorkerProfileResolution(
            state: enumValue(
              WorkspaceWorkerProfileState.values,
              value['profileState'],
              WorkspaceWorkerProfileState.unavailable,
            ),
            message: value['profileMessage']?.toString(),
            details: profileDetails is Map
                ? Map<String, Object?>.from(profileDetails)
                : null,
          ),
          providerToolState: enumValue(
            WorkspaceProviderToolState.values,
            value['providerToolState'],
            WorkspaceProviderToolState.unknown,
          ),
        ));
      }
    }
    return WorkerCatalogSnapshot(
      descriptors: descriptors,
      workers: views,
      catalogConfirmed: json['catalogConfirmed'] == true,
      catalogError: json['catalogError']?.toString(),
      refreshing: json['refreshing'] == true,
      localRegistryLoaded: json['localRegistryLoaded'] == true,
      localRegistryError: json['localRegistryError']?.toString(),
    );
  }
}

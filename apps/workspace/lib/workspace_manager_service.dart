import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'cloud_connection.dart';
import 'diagnostics.dart';
import 'local_worker_permissions.dart';
import 'work_root.dart';
import 'workspace.dart';
import 'workspace_configuration.dart';
import 'workspace_lifecycle.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_manager_ipc.dart';
import 'local_worker_setup.dart';
import 'workspace_registration.dart';
import 'workspace_registration_models.dart';
import 'workspace_service_state.dart';
import 'worker_readiness.dart';

/// Runtime command boundary and event publisher for the local management UI.
class WorkspaceManagerService {
  WorkspaceManagerService(
    Workspace workspace, {
    this.reloadRuntime,
  }) : _workspace = workspace;

  Workspace _workspace;
  Workspace get workspace => _workspace;
  final Future<Workspace> Function()? reloadRuntime;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  WorkspaceManagerIpcServer? _server;
  Future<void>? _snapshotInFlight;
  bool _snapshotDirty = false;
  Map<String, Object?>? _previousSnapshot;
  bool _closed = false;
  WorkspaceCloudConnection? _observedConnection;
  WorkerCatalogCoordinator? _observedCatalog;

  Future<void> start() async {
    if (Platform.isWindows) {
      throw UnsupportedError(
        'Workspace Manager IPC is not available on this Windows build.',
      );
    }
    final paths = WorkspacePaths(workspace.config.dataDirectory);
    _server = WorkspaceManagerIpcServer(
      runtimeDirectory: paths.runtimeDirectory,
      serviceVersion: conclaveWorkspaceAppVersion,
      snapshotProvider: snapshot,
      requestHandler: _dispatchAndPublish,
      eventStream: _events.stream,
    );
    await _server!.start();
    _bindWorkspaceEvents(workspace);
    _previousSnapshot = await snapshot();
  }

  void _bindWorkspaceEvents(Workspace target) {
    final oldConnection = _observedConnection;
    if (oldConnection != null) oldConnection.onStateChanged = null;
    _observedCatalog?.removeListener(_handleWorkspaceChange);
    final connection = target.cloudConnection;
    _observedConnection = connection;
    if (connection != null) connection.onStateChanged = _handleWorkspaceChange;
    _observedCatalog = target.workerCatalogCoordinator;
    _observedCatalog?.addListener(_handleWorkspaceChange);
  }

  void _handleWorkspaceChange() => unawaited(_publishSnapshot());

  Future<Object?> _dispatchAndPublish(
    String command,
    Map<String, Object?> payload,
  ) async {
    final result = await _dispatch(command, payload);
    await _publishSnapshot();
    return result;
  }

  Future<Map<String, Object?>> snapshot() async {
    final connection = workspace.cloudConnection;
    final workers =
        await workspace.localWorkerRegistry?.list() ?? const <LocalWorker>[];
    final registration = WorkspaceRegistrationStore(
      workspace.config.dataDirectory,
    ).readSync();
    final stateFile = File(
      '${workspace.config.dataDirectory.path}/workspace-state.json',
    );
    Map<String, Object?> state = const {};
    if (await stateFile.exists()) {
      try {
        final decoded = jsonDecode(await stateFile.readAsString());
        if (decoded is Map) state = Map<String, Object?>.from(decoded);
      } on Object {
        state = const {};
      }
    }
    final activeIds = connection?.activeAssignmentIds ?? const <String>[];
    final journalRecords =
        await connection?.assignmentJournal?.reconcile() ?? const {};
    final recoveryRequired = journalRecords.values
        .where((record) => record.status == AssignmentStatus.interrupted)
        .map((record) => {
              'assignmentId': record.assignmentId,
              'state': record.result?['recoveryState'] ?? 'outcome_unknown',
              'workerId': record.workerId,
              'updatedAt': record.updatedAt.toIso8601String(),
            })
        .toList()
      ..sort((left, right) => (left['assignmentId']! as String)
          .compareTo(right['assignmentId']! as String));
    return {
      'service': {
        'processState': state['processState'] ??
            (workspace.isRunning ? 'ready' : 'stopped'),
        'startedAt': state['startedAt'],
        'version': conclaveWorkspaceAppVersion,
        'installationId': workspace.installationId,
        'uptimeSeconds': _serviceUptimeSeconds(state),
      },
      'cloud': {
        'state': WorkspaceServiceState.cloudStateFor(
          configured: workspace.config.cloudUri != null &&
              workspace.config.workspaceId != null,
          authenticated: workspace.config.authToken?.isNotEmpty == true,
          stage: connection?.connectionStage,
        ).name,
        'connected': connection?.isConnected ?? false,
        'transport': connection?.activeTransportMode,
        'acceptingNewWork': connection?.acceptingNewWork ?? false,
        'lastError': connection?.lastConnectionError,
        'reconnectCount': connection?.reconnectCount ?? 0,
        'lastInventorySyncAt':
            connection?.lastInventorySyncAt?.toIso8601String(),
      },
      'workspace': {
        'workspaceId': workspace.config.workspaceId,
        'workspaceRuntimeId': workspace.config.workspaceRuntimeId,
        'name': registration?.name,
        'cloudUrl': registration?.cloudUrl,
        'workRoot': workspace.workRoot?.path ??
            workspace.config.workRootPath ??
            WorkRootResolver().defaultPath,
      },
      'workers': workers.map((worker) => worker.toJson()).toList(),
      'workerCatalog': _workerCatalogSnapshot(),
      'assignments': {
        'activeCount': activeIds.length,
        'activeIds': activeIds,
        'recoveryRequired': recoveryRequired,
      },
    };
  }

  Map<String, Object?> _workerCatalogSnapshot() {
    final catalog = workspace.workerCatalogCoordinator?.snapshot;
    if (catalog == null) {
      return {
        'descriptors': workspace.toolProfileCatalog?.workers
                .map((descriptor) => descriptor.toJson())
                .toList() ??
            const [],
        'views': const [],
        'catalogConfirmed': false,
        'localRegistryLoaded': workspace.localWorkerRegistry != null,
      };
    }
    return {
      'descriptors':
          catalog.descriptors.map((descriptor) => descriptor.toJson()).toList(),
      'views': catalog.workers
          .map((view) => {
                if (view.descriptor != null)
                  'descriptor': view.descriptor!.toJson(),
                'catalogRetired': view.catalogRetired,
                if (view.localWorker != null)
                  'localWorker': view.localWorker!.toJson(),
                'localState': view.localState.name,
                'profileState': view.profileState.name,
                'profileMessage': view.profileAvailability.message,
                'profileDetails': view.profileAvailability.details,
                'providerToolState': view.providerToolState.name,
              })
          .toList(),
      'catalogConfirmed': catalog.catalogConfirmed,
      'catalogError': catalog.catalogError,
      'refreshing': catalog.refreshing,
      'localRegistryLoaded': catalog.localRegistryLoaded,
      'localRegistryError': catalog.localRegistryError,
    };
  }

  int? _serviceUptimeSeconds(Map<String, Object?> state) {
    final startedAt = DateTime.tryParse(state['startedAt']?.toString() ?? '');
    if (startedAt == null) return null;
    return DateTime.now()
        .toUtc()
        .difference(startedAt)
        .inSeconds
        .clamp(0, 1 << 31);
  }

  Future<void> _publishSnapshot() {
    if (_closed) return Future<void>.value();
    final active = _snapshotInFlight;
    if (active != null) {
      _snapshotDirty = true;
      return active;
    }
    final future = _publishSnapshotLoop();
    _snapshotInFlight = future;
    return future.whenComplete(() {
      if (identical(_snapshotInFlight, future)) _snapshotInFlight = null;
    });
  }

  Future<void> _publishSnapshotLoop() async {
    do {
      _snapshotDirty = false;
      await _publishSnapshotOnce();
    } while (!_closed && _snapshotDirty);
  }

  Future<void> _publishSnapshotOnce() async {
    final current = await snapshot();
    if (_closed) return;
    final previous = _previousSnapshot;
    if (previous == null || jsonEncode(previous) != jsonEncode(current)) {
      if (previous != null) {
        if (_nested(previous, 'cloud', 'state') !=
            _nested(current, 'cloud', 'state')) {
          _events.add({
            'name': 'cloud.connectionChanged',
            'cloud': current['cloud'],
          });
        }
        if (jsonEncode(previous['workers']) != jsonEncode(current['workers'])) {
          _events.add({
            'name': 'worker.inventoryChanged',
            'workers': current['workers'],
          });
        }
        if (jsonEncode(previous['workerCatalog']) !=
            jsonEncode(current['workerCatalog'])) {
          _events.add({
            'name': 'worker.catalogChanged',
            'workerCatalog': current['workerCatalog'],
          });
        }
        final before = _nested(previous, 'assignments', 'activeIds');
        final after = _nested(current, 'assignments', 'activeIds');
        final beforeIds =
            before is List ? before.cast<String>().toSet() : <String>{};
        final afterIds =
            after is List ? after.cast<String>().toSet() : <String>{};
        for (final id in afterIds.difference(beforeIds)) {
          _events.add({'name': 'assignment.started', 'assignmentId': id});
        }
        for (final id in beforeIds.difference(afterIds)) {
          _events.add({'name': 'assignment.completed', 'assignmentId': id});
        }
      }
      _events.add({'name': 'service.statusChanged', 'snapshot': current});
      _previousSnapshot = current;
    }
  }

  Object? _nested(Map<String, Object?> snapshot, String key, String child) {
    final value = snapshot[key];
    return value is Map ? value[child] : null;
  }

  Future<Object?> _dispatch(
    String command,
    Map<String, Object?> payload,
  ) async {
    final connection = workspace.cloudConnection;
    final registry = workspace.localWorkerRegistry;
    switch (command) {
      case 'service.getStatus':
        return snapshot();
      case 'service.getVersion':
        return {'version': conclaveWorkspaceAppVersion};
      case 'service.getHealth':
        return {
          'healthy': workspace.isRunning,
          'processState': workspace.isRunning ? 'ready' : 'stopped',
        };
      case 'service.restart':
      case 'service.shutdown':
        throw const WorkspaceManagerProtocolException(
          'host_boundary_required',
          'Service restart and shutdown must be requested through the host manager.',
        );
      case 'connection.connect':
      case 'connection.reconnect':
        if (connection == null) {
          throw const WorkspaceManagerProtocolException('not_configured',
              'Workspace Cloud connection is not configured.');
        }
        connection.validateConfiguration();
        if (connection.connectionStage == WorkspaceConnectionStage.ready &&
            command == 'connection.connect') {
          return snapshot();
        }
        await _setDesiredRuntime(DesiredRuntimeState.connected);
        connection.resumeNewWork();
        await connection.retryNow();
        return snapshot();
      case 'service.prepareStop':
        if (connection != null) {
          if (!await _drainAssignments(connection)) {
            connection.resumeNewWork();
            throw const WorkspaceManagerProtocolException(
              'assignments_active',
              'Work is still running. Let it finish before stopping the service.',
            );
          }
          await connection.close();
        }
        return snapshot();
      case 'connection.disconnect':
        if (connection == null) {
          await _setDesiredRuntime(DesiredRuntimeState.disconnected);
          return snapshot();
        }
        final drained = await _drainAssignments(connection);
        if (!drained) {
          connection.resumeNewWork();
          throw const WorkspaceManagerProtocolException(
            'assignments_active',
            'Active assignments did not finish within the disconnect grace period.',
          );
        }
        await connection.close();
        await _setDesiredRuntime(DesiredRuntimeState.disconnected);
        return snapshot();
      case 'connection.pause':
        connection?.pauseNewWork();
        return snapshot();
      case 'connection.resume':
        if (connection?.isConnected == true) connection?.resumeNewWork();
        return snapshot();
      case 'workers.list':
      case 'workers.getStatus':
        if (registry == null) return const [];
        final workerId = payload['workerId'];
        if (workerId is String) {
          final worker = await registry.find(workerId);
          if (worker == null) {
            throw const WorkspaceManagerProtocolException(
                'worker_not_found', 'Worker does not exist.');
          }
          return worker.toJson();
        }
        return (await registry.list())
            .map((worker) => worker.toJson())
            .toList();
      case 'workers.getCatalogSnapshot':
        return _workerCatalogSnapshot();
      case 'workers.reset':
        if (registry == null) return snapshot();
        if ((connection?.activeAssignmentCount ?? 0) > 0) {
          throw const WorkspaceManagerProtocolException(
              'assignments_active', 'Wait for active work to finish first.');
        }
        await registry.reset();
        return snapshot();
      case 'workers.refreshCatalog':
        await workspace.workerCatalogCoordinator?.refresh(force: true);
        return _workerCatalogSnapshot();
      case 'workers.ensureProfile':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId is! String) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'workerTypeId is required.');
        }
        await workspace.workerCatalogCoordinator?.ensureWorkerProfileAvailable(
            workerTypeId,
            waitForActiveRefresh: payload['waitForActiveRefresh'] == true);
        return _workerCatalogSnapshot();
      case 'workers.configureWorker':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId is! String || registry == null) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'workerTypeId is required.');
        }
        final coordinator = workspace.workerCatalogCoordinator;
        if (coordinator == null) {
          throw const WorkspaceManagerProtocolException(
            'catalog_unavailable',
            'The Worker catalog is not available from Workspace Service.',
          );
        }
        var descriptor = coordinator.entryForWorker(workerTypeId);
        if (descriptor == null) {
          await coordinator.refresh(force: true);
          descriptor = coordinator.entryForWorker(workerTypeId);
        }
        if (descriptor == null) {
          throw const WorkspaceManagerProtocolException('worker_not_found',
              'Worker is not in the approved Cloud catalog.');
        }
        final worker = await LocalWorkerSetupService(registry: registry)
            .createCatalogWorker(
          entry: descriptor,
          permissions: defaultLocalWorkerPermissions,
        );
        await coordinator.ensureWorkerProfileAvailable(
          workerTypeId,
          waitForActiveRefresh: true,
        );
        await workspace.workerReadinessMonitor?.checkNow(
          mode: LocalWorkerProbeMode.passive,
          workerTypeId: workerTypeId,
        );
        return (await registry.find(worker.id))?.toJson();
      case 'workers.enableWorker':
      case 'workers.disableWorker':
        if (registry == null) {
          throw const WorkspaceManagerProtocolException(
              'not_configured', 'Local Worker registry is not available.');
        }
        final workerId = payload['workerId'];
        if (workerId is! String) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'workerId is required.');
        }
        final worker = command == 'workers.disableWorker'
            ? await registry.update(
                workerId,
                (current) => current.copyWith(
                  status: LocalWorkerStatus.disabled,
                  activationState: LocalWorkerActivationState.disabled,
                ),
              )
            : await registry.update(
                workerId,
                (current) => current.copyWith(
                  status: LocalWorkerStatus.needsAttention,
                  activationState: LocalWorkerActivationState.enabled,
                ),
              );
        if (command == 'workers.enableWorker') {
          await workspace.workerReadinessMonitor?.checkNow(
            mode: LocalWorkerProbeMode.passive,
            workerTypeId: worker.workerTypeId,
          );
        }
        return worker.toJson();
      case 'workers.testWorker':
        final workerId = payload['workerId'];
        if (workerId is! String || registry == null) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'workerId is required.');
        }
        final worker = await registry.find(workerId);
        if (worker == null) {
          throw const WorkspaceManagerProtocolException(
              'worker_not_found', 'Worker does not exist.');
        }
        await workspace.workerReadinessMonitor?.checkNow(
          mode: LocalWorkerProbeMode.live,
          workerTypeId: worker.workerTypeId,
        );
        return (await registry.find(workerId))?.toJson();
      case 'workers.checkReadiness':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId != null && workerTypeId is! String) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'workerTypeId must be a string.');
        }
        final mode = payload['mode'] == 'live'
            ? LocalWorkerProbeMode.live
            : LocalWorkerProbeMode.passive;
        await workspace.workerReadinessMonitor?.checkNow(
          mode: mode,
          workerTypeId: workerTypeId as String?,
        );
        return snapshot();
      case 'workers.rollbackProfile':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId is! String) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'workerTypeId is required.');
        }
        final passed = await workspace.workerReadinessMonitor
                ?.rollbackToolProfile(workerTypeId) ??
            false;
        return {'passed': passed, 'snapshot': await snapshot()};
      case 'execution.listActiveAssignments':
        return {
          'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
        };
      case 'execution.cancelAssignment':
        final assignmentId = payload['assignmentId'];
        if (assignmentId is! String) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'assignmentId is required.');
        }
        final cancelled =
            await connection?.cancelActiveAssignment(assignmentId) ?? false;
        return {'cancelled': cancelled};
      case 'configuration.get':
        return {
          'workspace': await snapshot().then((value) => value['workspace']),
          'workRoot': workspace.workRoot?.path ??
              workspace.config.workRootPath ??
              WorkRootResolver().defaultPath,
        };
      case 'configuration.update':
        throw const WorkspaceManagerProtocolException(
          'service_running',
          'Stop the service and change Work Root in Workspace.app.',
        );
      case 'configuration.reload':
        await _reloadRuntime();
        return snapshot();
      case 'diagnostics.getLogs':
        return {'text': await _readLogTail()};
      case 'diagnostics.getMetrics':
        return {
          ...await sampleWorkspaceProcessMetrics(),
          'activeAssignments': connection?.activeAssignmentCount ?? 0,
          'configuredWorkers': (await registry?.list())?.length ?? 0,
          'cloudConnected': connection?.isConnected ?? false,
          'reconnectCount': connection?.reconnectCount ?? 0,
        };
      case 'diagnostics.getDiagnostics':
        final file = await writeWorkspaceDiagnostics(
          config: workspace.config,
          connection: connection,
          journal: connection?.assignmentJournal,
          workerRegistry: registry,
          toolProfileReleaseStore: workspace.toolProfileReleaseStore,
          workRootPath: workspace.workRoot?.path,
        );
        return {'path': file.path, 'text': await file.readAsString()};
      default:
        throw WorkspaceManagerProtocolException(
          'unsupported_command',
          'Unsupported Workspace Manager command: $command',
        );
    }
  }

  Future<void> _setDesiredRuntime(DesiredRuntimeState desired) async {
    final store = WorkspaceLifecyclePreferencesStore(
      workspace.config.dataDirectory,
    );
    await store.write(store.readSync().copyWith(desiredRuntime: desired));
  }

  Future<void> _reloadRuntime() async {
    final rebuild = reloadRuntime;
    if (rebuild == null) {
      throw const WorkspaceManagerProtocolException(
        'configuration_reload_unavailable',
        'This service cannot reload its runtime configuration.',
      );
    }
    final current = workspace;
    if (current.cloudConnection != null &&
        !await _drainAssignments(current.cloudConnection!)) {
      current.cloudConnection!.resumeNewWork();
      throw const WorkspaceManagerProtocolException(
        'assignments_active',
        'Active assignments must finish before configuration can be reloaded.',
      );
    }
    await current.stop();
    try {
      final replacement = await rebuild();
      final desired = WorkspaceLifecyclePreferencesStore(
        replacement.config.dataDirectory,
      ).readSync().desiredRuntime;
      await replacement.start(connectCloud: false);
      _workspace = replacement;
      _bindWorkspaceEvents(replacement);
      if (desired == DesiredRuntimeState.connected) {
        // Completing configuration reload means the local runtime is ready,
        // not that Cloud is reachable. Its transport owns retry/backoff.
        unawaited(replacement.cloudConnection?.connect().catchError(
                  (Object _) {},
                ) ??
            Future<void>.value());
      }
    } on Object {
      throw const WorkspaceManagerProtocolException(
        'configuration_reload_failed',
        'Workspace configuration could not be loaded. Local files were preserved.',
      );
    }
  }

  Future<bool> _drainAssignments(WorkspaceCloudConnection connection) async {
    connection.beginDrain();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (connection.activeAssignmentCount > 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return connection.activeAssignmentCount == 0;
  }

  Future<String> _readLogTail() async {
    final file = WorkspacePaths(workspace.config.dataDirectory).logsFile;
    if (!await file.exists()) return '';
    final length = await file.length();
    final start = length > 256 * 1024 ? length - 256 * 1024 : 0;
    final handle = await file.open();
    try {
      await handle.setPosition(start);
      return utf8.decode(await handle.read(length - start),
          allowMalformed: true);
    } finally {
      await handle.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final connection = _observedConnection;
    if (connection != null) connection.onStateChanged = null;
    _observedConnection = null;
    _observedCatalog?.removeListener(_handleWorkspaceChange);
    _observedCatalog = null;
    await _server?.close();
    _server = null;
    await _events.close();
  }
}

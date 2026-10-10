import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'cloud_connection.dart';
import 'diagnostics.dart';
import 'work_root.dart';
import 'workspace.dart';
import 'workspace_configuration.dart';
import 'workspace_lifecycle.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_manager_ipc.dart';
import 'workspace_registration.dart';
import 'workspace_registration_models.dart';
import 'workspace_service_state.dart';
import 'worker_readiness.dart';

/// Runtime command boundary and event publisher for the local management UI.
class WorkspaceManagerService {
  WorkspaceManagerService(this.workspace);

  final Workspace workspace;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  WorkspaceManagerIpcServer? _server;
  Timer? _snapshotTimer;
  Future<void>? _snapshotInFlight;
  Map<String, Object?>? _previousSnapshot;
  bool _closed = false;

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
      requestHandler: _dispatch,
      eventStream: _events.stream,
    );
    await _server!.start();
    _previousSnapshot = await snapshot();
    _snapshotTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_publishSnapshot());
    });
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
      'assignments': {
        'activeCount': activeIds.length,
        'activeIds': activeIds,
        'recoveryRequired': recoveryRequired,
      },
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

  Future<void> _publishSnapshot() async {
    if (_closed || _snapshotInFlight != null) return _snapshotInFlight;
    final future = _publishSnapshotOnce();
    _snapshotInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_snapshotInFlight, future)) _snapshotInFlight = null;
    }
  }

  Future<void> _publishSnapshotOnce() async {
    final current = await snapshot();
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
                  activationState: LocalWorkerActivationState.disabled,
                ),
              )
            : await registry.update(
                workerId,
                (current) => current.copyWith(
                  activationState: LocalWorkerActivationState.enabled,
                ),
              );
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
          'configuration_update_unavailable',
          'This service version does not support changing runtime configuration over IPC.',
        );
      case 'diagnostics.getLogs':
        return {'text': await _readLogTail()};
      case 'diagnostics.getMetrics':
        return {
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
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    await _server?.close();
    _server = null;
    await _events.close();
  }
}

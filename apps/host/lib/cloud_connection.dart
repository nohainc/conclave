import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'runtime_capabilities.dart';
import 'package:conclave_protocol/conclave_protocol.dart';
import 'worker_protocol.dart';
import 'workspace_enrollment.dart';

abstract interface class HostCloudSocket {
  Stream<Object?> get messages;
  void send(Object message);
  Future<void> close();
}

typedef HostCloudSocketFactory = Future<HostCloudSocket> Function(Uri uri);

class HostAssignmentContext {
  const HostAssignmentContext({
    required this.workspaceId,
    required this.hostId,
    required this.workerId,
    required this.runId,
    required this.taskId,
    required this.attemptId,
    required this.assignmentId,
    required this.idempotencyKey,
    required this.payload,
  });

  final String workspaceId;
  final String hostId;
  final String workerId;
  final String runId;
  final String taskId;
  final String attemptId;
  final String assignmentId;
  final String idempotencyKey;
  final Map<String, Object?> payload;

  HostAssignmentContext copyWith({
    String? workerId,
    Map<String, Object?>? payload,
  }) =>
      HostAssignmentContext(
        workspaceId: workspaceId,
        hostId: hostId,
        workerId: workerId ?? this.workerId,
        runId: runId,
        taskId: taskId,
        attemptId: attemptId,
        assignmentId: assignmentId,
        idempotencyKey: idempotencyKey,
        payload: payload ?? this.payload,
      );
}

class HostAssignmentResult {
  const HostAssignmentResult({
    required this.summary,
    this.output,
    this.artifactIds = const [],
    this.evidence,
  });

  final String summary;
  final Map<String, Object?>? output;
  final List<String> artifactIds;
  final Map<String, Object?>? evidence;
}

typedef HostAssignmentHandler = Future<HostAssignmentResult> Function(
    HostAssignmentContext context);
typedef HostAssignmentCancellationHandler = Future<bool> Function(
  String assignmentId,
  String reason,
);
typedef HostUpdateAvailableHandler = Future<void> Function(
  Map<String, Object?> payload,
);

class IoHostCloudSocket implements HostCloudSocket {
  IoHostCloudSocket(this.socket);
  final WebSocket socket;

  @override
  Stream<Object?> get messages => socket;

  @override
  void send(Object message) => socket.add(message);

  @override
  Future<void> close() async {
    await socket.close(WebSocketStatus.normalClosure);
  }
}

Future<HostCloudSocket> connectIoHostCloudSocket(
  Uri uri, {
  String? authToken,
}) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: authToken == null
        ? null
        : <String, String>{'Authorization': 'Bearer $authToken'},
  );
  return IoHostCloudSocket(socket);
}

class HostCloudConnection {
  HostCloudConnection({
    required this.uri,
    required this.hostId,
    required this.workspaceId,
    required this.factory,
    Set<String>? authorizedWorkspaceIds,
    this.name = 'Conclave Workspace',
    String? hostname,
    this.hostVersion = conclaveWorkspaceAppVersion,
    Map<String, Object?>? capabilities,
    this.activeWorkerIds = const [],
    this.unreconciledAssignmentIds = const [],
    this.assignmentHandler,
    this.assignmentCancellationHandler,
    this.assignmentJournal,
    this.workerInventoryProvider,
    this.hostUpdateAvailableHandler,
    this.workstreamCheckoutManager,
    this.heartbeat = const Duration(seconds: 15),
    this.reconnectBaseDelay = const Duration(milliseconds: 10),
    this.reconnectMaxDelay = const Duration(seconds: 5),
  })  : authorizedWorkspaceIds = {
          workspaceId,
          ...?authorizedWorkspaceIds,
        },
        legacyProtocol = uri.path.contains('/host') &&
            !uri.path.contains('workspace-gateway'),
        hostname = hostname ?? Platform.localHostname,
        capabilities = capabilities ?? _defaultCapabilities();

  final Uri uri;
  final String hostId;
  final String workspaceId;
  final Set<String> authorizedWorkspaceIds;
  final bool legacyProtocol;
  final HostCloudSocketFactory factory;
  final String name;
  final String hostname;
  final String hostVersion;
  final Map<String, Object?> capabilities;
  final List<String> activeWorkerIds;
  final List<String> unreconciledAssignmentIds;
  final HostAssignmentHandler? assignmentHandler;
  final HostAssignmentCancellationHandler? assignmentCancellationHandler;
  final AssignmentJournal? assignmentJournal;
  final Future<List<Map<String, Object?>>> Function()? workerInventoryProvider;
  final HostUpdateAvailableHandler? hostUpdateAvailableHandler;
  final WorkstreamCheckoutManager? workstreamCheckoutManager;
  final Duration heartbeat;
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;
  HostCloudSocket? _socket;
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  StreamSubscription<Object?>? _subscription;
  bool _closing = false;
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  int reconnectCount = 0;
  String? sessionId;
  bool get isConnected => sessionId != null;
  int get activeAssignmentCount => _activeAssignments.length;
  bool acceptingNewWork = true;
  bool get isDraining => _draining;
  bool _draining = false;
  DateTime? lastInventorySyncAt;

  void pauseNewWork() {
    acceptingNewWork = false;
    _draining = false;
  }

  void resumeNewWork() {
    _draining = false;
    acceptingNewWork = true;
  }

  void beginDrain() {
    acceptingNewWork = false;
    _draining = true;
  }

  Future<void> refreshWorkerInventory() => _reportCurrentWorkerInventory();
  List<String> get activeAssignmentIds => _activeAssignments.toList()..sort();
  int _messageSequence = 0;
  int _heartbeatCount = 0;
  Map<String, Object?>? syncResponse;
  final _activeAssignments = <String>{};
  final _lastEphemeralWorkerEvent = <String, DateTime>{};

  /// Sends the Workspace-owned inventory projection. Secrets, credential
  /// references, and local paths must not be included by the caller.
  void reportWorkerInventory(List<Map<String, Object?>> workers) {
    _sendIfConnected('worker.inventory', {
      'fullSnapshot': true,
      'workers': workers,
    });
  }

  Future<void> _reportCurrentWorkerInventory() async {
    final provider = workerInventoryProvider;
    if (provider == null || !isConnected) return;
    try {
      reportWorkerInventory(await provider());
      lastInventorySyncAt = DateTime.now().toUtc();
    } on Object {
      // A local inventory read failure must not tear down the runtime link.
    }
  }

  /// Reports only logical Workstream readiness. Local absolute paths and
  /// repository locations never cross the runtime boundary.
  void reportWorkstreamStatus({
    required String projectId,
    required String workstreamId,
    required String workingDirectoryState,
  }) {
    if (!const {'absent', 'ready', 'conflict', 'unavailable'}
        .contains(workingDirectoryState)) {
      throw ArgumentError.value(workingDirectoryState, 'workingDirectoryState');
    }
    _sendIfConnected('workstream.status', {
      'projectId': projectId,
      'workstreamId': workstreamId,
      'workingDirectoryState': workingDirectoryState,
    });
  }

  /// Relays validated Worker facts using the trusted Assignment correlation.
  /// Workers never provide Workspace, Host, Run, or Task identity.
  void reportWorkerNotification(
    HostAssignmentContext context,
    WorkerRpcNotification notification,
  ) {
    final assignmentId = notification.params['assignmentId'];
    if (assignmentId != context.assignmentId) return;
    final socket = _socket;
    if (socket == null || sessionId == null) return;
    final now = DateTime.now().toUtc();
    final terminal =
        notification.method == 'result' || notification.method == 'error';
    if (!terminal) {
      final last = _lastEphemeralWorkerEvent[context.assignmentId];
      if (last != null && now.difference(last).inMilliseconds < 100) return;
      _lastEphemeralWorkerEvent[context.assignmentId] = now;
    }
    final params = Map<String, Object?>.from(notification.params)
      ..remove('assignmentId');
    final correlation = {
      'workspaceId': context.workspaceId,
      'hostId': context.hostId,
      'workerId': context.workerId,
      'runId': context.runId,
      'taskId': context.taskId,
      'attemptId': context.attemptId,
      'assignmentId': context.assignmentId,
      'idempotencyKey': context.idempotencyKey,
    };
    if (notification.method == 'result') {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.result',
        correlation,
        {
          'assignmentId': context.assignmentId,
          'status': params['status'] ?? 'completed',
          'output': params['output'],
          'artifactIds': params['artifactIds'] ?? const [],
          'completedAt': params['completedAt'] ?? now.toIso8601String(),
        },
      )));
      return;
    }
    if (notification.method == 'error') {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.error',
        correlation,
        {
          'assignmentId': context.assignmentId,
          'error': {
            'code': params['code'] ?? 'worker_error',
            'message': params['message'] ?? 'Worker failed',
            'retryable': params['retryable'] ?? false,
            if (params['details'] is Map) 'details': params['details'],
          },
          'failedAt': params['timestamp'] ?? now.toIso8601String(),
        },
      )));
      return;
    }
    final percentage = params['percentage'] is num
        ? (params['percentage'] as num).toDouble()
        : 0.0;
    final message = params['message'] is String
        ? params['message'] as String
        : params['delta'] is String
            ? params['delta'] as String
            : notification.method;
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.progress',
      correlation,
      {
        'assignmentId': context.assignmentId,
        'percentage': percentage.clamp(0, 100),
        'message': message,
        'observedAt': params['timestamp'] ?? now.toIso8601String(),
        'metrics': {
          'workerEventType': notification.method,
          ...params,
        },
      },
    )));
  }

  void _sendIfConnected(String type, Map<String, Object?> payload) {
    final socket = _socket;
    if (socket == null || sessionId == null) return;
    socket.send(jsonEncode(_envelope(type, payload)));
  }

  static const protocol = workspaceRuntimeProtocolName;
  static const protocolVersion = workspaceRuntimeProtocolVersion;

  static bool _isCompatibleProtocolVersion(String remote) {
    final localParts = protocolVersion.split('.').map(int.parse).toList();
    final remoteParts = remote.split('.').map(int.tryParse).toList();
    if (remoteParts.length < 2 || remoteParts.any((part) => part == null)) {
      return false;
    }
    return remoteParts[0] == localParts[0] && remoteParts[1]! >= localParts[1];
  }

  static Map<String, Object?> _defaultCapabilities() {
    final operatingSystem = switch (Platform.operatingSystem) {
      'macos' => 'macos',
      'linux' => 'linux',
      'windows' => 'windows',
      _ => 'linux',
    };
    return {
      'os': operatingSystem,
      'arch': _architecture(),
      'hostVersion': conclaveWorkspaceAppVersion,
      'supportedRuntimes': <String>['dart'],
      'maxConcurrentWorkers': 1,
    };
  }

  static String _architecture() {
    final hint =
        '${Platform.environment['PROCESSOR_ARCHITECTURE'] ?? ''} ${Platform.environment['HOSTTYPE'] ?? ''} ${Platform.version}'
            .toLowerCase();
    return hint.contains('arm64') || hint.contains('aarch64') ? 'arm64' : 'x64';
  }

  Future<void> connect() async {
    _closing = false;
    await _open();
  }

  Future<void> _open() async {
    final socket = await factory(uri);
    _socket = socket;
    sessionId = null;
    _reconnectAttempt = 0;
    await _subscription?.cancel();
    _subscription = socket.messages.listen(
      _handleMessage,
      onDone: () => unawaited(_reconnect()),
      onError: (_) => unawaited(_reconnect()),
    );
    socket.send(jsonEncode(_envelope('workspace.hello', {
      'workspaceRuntimeId': hostId,
      'executionWorkspaceId': workspaceId,
      'name': name,
      'hostname': hostname,
      'hostVersion': hostVersion,
      'capabilities': capabilities,
    })));
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      final currentSessionId = sessionId;
      if (currentSessionId == null) return;
      _heartbeatTimeoutTimer ??= Timer(heartbeat * 2, () {
        _heartbeatTimeoutTimer = null;
        unawaited(_socket?.close());
      });
      socket.send(jsonEncode({
        ..._envelope('workspace.heartbeat', {
          'workspaceRuntimeId': hostId,
          'executionWorkspaceId': workspaceId,
          'sessionId': currentSessionId,
          'status': 'online',
          'activeWorkers': activeWorkerIds.length,
          'activeAssignments': _activeAssignments.length,
        }),
      }));
      _heartbeatCount++;
      if (_heartbeatCount >= 4) {
        _heartbeatCount = 0;
        unawaited(_reportCurrentWorkerInventory());
      }
    });
  }

  Map<String, Object?> _envelope(String type, Map<String, Object?> payload) =>
      _legacyMap({
        'protocol': protocol,
        'protocolVersion': protocolVersion,
        'messageId':
            'dart-${DateTime.now().microsecondsSinceEpoch}-${++_messageSequence}',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': type,
        'payload': payload,
      });

  Map<String, Object?> _legacyMap(Map<String, Object?> message) {
    if (!legacyProtocol) return message;
    Object? translate(Object? value) {
      if (value is! Map) return value;
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = switch (entry.key) {
          'executionWorkspaceId' => 'workspaceId',
          'workspaceRuntimeId' => 'hostId',
          _ => entry.key.toString(),
        };
        result[key] = translate(entry.value);
      }
      return result;
    }

    final translated = Map<String, Object?>.from(translate(message) as Map);
    translated['protocol'] = 'conclave.host-protocol';
    translated['protocolVersion'] = '4.0';
    if (translated['type'] is String) {
      translated['type'] =
          (translated['type'] as String).replaceFirst('workspace.', 'host.');
      if (translated['type'] == 'host.sync.result') {
        translated['type'] = 'host.sync.response';
      }
    }
    return translated;
  }

  static Map<String, dynamic> _normalizeLegacyMessage(
    Map<String, dynamic> message,
  ) {
    Object? translate(Object? value) {
      if (value is! Map) return value;
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = switch (entry.key) {
          'workspaceId' => 'executionWorkspaceId',
          'hostId' => 'workspaceRuntimeId',
          _ => entry.key.toString(),
        };
        result[key] = translate(entry.value);
      }
      return result;
    }

    final normalized = Map<String, dynamic>.from(translate(message) as Map);
    normalized['protocol'] = workspaceRuntimeProtocolName;
    final legacyVersion = message['protocolVersion'];
    if (legacyVersion is String && legacyVersion.startsWith('4.')) {
      final versionParts = legacyVersion.split('.');
      final minor = versionParts.length > 1 ? versionParts[1] : '0';
      normalized['protocolVersion'] = '5.$minor';
    } else {
      normalized['protocolVersion'] = legacyVersion;
    }
    if (normalized['type'] is String) {
      normalized['type'] =
          (normalized['type'] as String).replaceFirst('host.', 'workspace.');
      if (normalized['type'] == 'workspace.sync.response') {
        normalized['type'] = 'workspace.sync.result';
      }
    }
    return normalized;
  }

  void _handleMessage(Object? raw) {
    if (raw is! String) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (legacyProtocol) decoded = _normalizeLegacyMessage(decoded);
    final remoteProtocolVersion = decoded['protocolVersion'];
    if (remoteProtocolVersion is! String ||
        !_isCompatibleProtocolVersion(remoteProtocolVersion)) {
      return;
    }
    try {
      WorkspaceRuntimeMessage.parse(decoded);
    } on ProtocolException {
      return;
    }
    if (decoded['type'] == 'workspace.hello.ack') {
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic> && payload['sessionId'] is String) {
        sessionId = payload['sessionId'] as String;
        authorizedWorkspaceIds
          ..clear()
          ..add(workspaceId);
        if (legacyProtocol) {
          final bindings = payload['activeWorkspaceBindings'];
          if (bindings is List && bindings.every((value) => value is String)) {
            authorizedWorkspaceIds.addAll(bindings.cast<String>());
          }
        }
        unawaited(_sendSyncRequest());
        unawaited(_reportCurrentWorkerInventory());
      }
    } else if (decoded['type'] == 'workspace.sync.result') {
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic>) {
        syncResponse = Map<String, Object?>.from(payload);
        unawaited(_reconcileSyncResponse(syncResponse!).catchError((_) {}));
      }
    } else if (decoded['type'] == 'workspace.update') {
      final payload = decoded['payload'];
      final handler = hostUpdateAvailableHandler;
      if (payload is Map<String, dynamic> && handler != null) {
        unawaited(
          handler(Map<String, Object?>.from(payload)).catchError((_) {}),
        );
      }
    } else if (decoded['type'] == 'workspace.heartbeat.ack') {
      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer = null;
    } else if (decoded['type'] == 'workstream.status') {
      // Runtime readiness is currently informational. The payload is not
      // persisted here and contains no local path.
    } else if (decoded['type'] == 'assignment.start') {
      unawaited(_handleAssignmentStart(decoded));
    } else if (decoded['type'] == 'assignment.cancel') {
      unawaited(_handleAssignmentCancel(decoded));
    } else if (decoded['type'] == 'checkout.provision' ||
        decoded['type'] == 'checkout.recover' ||
        decoded['type'] == 'checkout.archive' ||
        decoded['type'] == 'checkout.finalize') {
      unawaited(_handleCheckoutCommand(decoded));
    }
  }

  Future<void> _handleCheckoutCommand(Map<String, dynamic> message) async {
    final payload = message['payload'];
    final manager = workstreamCheckoutManager;
    if (payload is! Map<String, dynamic> || manager == null) {
      _sendCheckoutStatus(message,
          status: 'stale', error: 'checkout manager unavailable');
      return;
    }
    final checkoutId = payload['checkoutId'];
    final workstreamId = payload['workstreamId'];
    if (checkoutId is! String || checkoutId.isEmpty) {
      _sendCheckoutStatus(message,
          status: 'stale', error: 'checkoutId is required');
      return;
    }
    try {
      final type = message['type'];
      if (type == 'checkout.provision') {
        if (workstreamId is! String || workstreamId.isEmpty) {
          throw const RuntimeViolation('workstreamId is required');
        }
        await manager.provision(
          checkoutId: checkoutId,
          workstreamId: workstreamId,
          revision: payload['revision'] is String
              ? payload['revision'] as String
              : 'HEAD',
        );
        final status = await manager.status(checkoutId);
        _sendCheckoutStatus(
          message,
          status: 'ready',
          headRevision: status.currentRevision,
        );
      } else if (type == 'checkout.recover') {
        await manager.resetAndRecover(
          checkoutId,
          revision: payload['revision'] is String
              ? payload['revision'] as String
              : null,
        );
        final status = await manager.status(checkoutId);
        _sendCheckoutStatus(
          message,
          status: 'ready',
          headRevision: status.currentRevision,
        );
      } else if (type == 'checkout.finalize') {
        final outcome = payload['outcome'];
        final baseRevision = payload['baseRevision'];
        if (outcome is! String || baseRevision is! String) {
          throw const RuntimeViolation(
              'finalize outcome and baseRevision are required');
        }
        final result = await manager.finalizeStatefulLease(
          checkoutId: checkoutId,
          baseRevision: baseRevision,
          outcome: outcome,
          message: payload['message'] is String
              ? payload['message'] as String
              : 'workstream checkpoint',
        );
        _sendCheckoutStatus(
          message,
          status: result.recoveryStatus == 'quarantined'
              ? 'recovery_required'
              : result.outcome == 'success'
                  ? 'checkpointed'
                  : 'rolled_back',
          headRevision: result.revision,
          diff: result.diff,
          changed: result.changed,
          recoveryStatus: result.recoveryStatus,
        );
      } else {
        await manager.archive(checkoutId);
        _sendCheckoutStatus(message, status: 'deleted');
      }
    } catch (error) {
      _sendCheckoutStatus(
        message,
        status: 'stale',
        error: error is RuntimeViolation ? error.message : error.toString(),
      );
    }
  }

  void _sendCheckoutStatus(
    Map<String, dynamic> message, {
    required String status,
    String? headRevision,
    String? error,
    String? diff,
    bool? changed,
    String? recoveryStatus,
  }) {
    _sendIfConnected('checkout.status', {
      'checkoutId': (message['payload'] as Map?)?['checkoutId'],
      if ((message['payload'] as Map?)?['workRequestId'] is String)
        'workRequestId': (message['payload'] as Map?)?['workRequestId'],
      'status': status,
      if (headRevision != null) 'headRevision': headRevision,
      if (diff != null) 'diff': diff,
      if (changed != null) 'changed': changed,
      if (recoveryStatus != null) 'recoveryStatus': recoveryStatus,
      if (error != null) 'error': error,
    });
  }

  Future<void> _handleAssignmentStart(Map<String, dynamic> message) async {
    final socket = _socket;
    final payload = message['payload'];
    final requiredFields = [
      'executionWorkspaceId',
      'workspaceRuntimeId',
      'workerId',
      'runId',
      'taskId',
      'attemptId',
      'assignmentId',
      'idempotencyKey',
    ];
    if (socket == null ||
        payload is! Map<String, dynamic> ||
        requiredFields.any((field) => message[field] is! String)) {
      return;
    }

    if (!authorizedWorkspaceIds.contains(message['executionWorkspaceId']) ||
        message['workspaceRuntimeId'] != hostId) {
      _sendAssignmentError(
        socket,
        message,
        'assignment_context_mismatch',
        'Assignment is not addressed to this host/workspace',
        retryable: false,
      );
      return;
    }

    final assignmentPayload = payload['snapshot'] is Map
        ? <String, dynamic>{
            ...(payload['snapshot'] as Map).cast<String, dynamic>(),
            if (payload['input'] is Map)
              'input': (payload['input'] as Map).cast<String, dynamic>(),
          }
        : payload;
    final payloadError = _validateAssignmentPayload(assignmentPayload);
    if (payloadError != null) {
      _sendAssignmentError(
        socket,
        message,
        'malformed_assignment',
        payloadError,
        retryable: false,
      );
      return;
    }

    final context = HostAssignmentContext(
      workspaceId: message['executionWorkspaceId'] as String,
      hostId: message['workspaceRuntimeId'] as String,
      workerId: message['workerId'] as String,
      runId: message['runId'] as String,
      taskId: message['taskId'] as String,
      attemptId: message['attemptId'] as String,
      assignmentId: message['assignmentId'] as String,
      idempotencyKey: message['idempotencyKey'] as String,
      payload: Map<String, Object?>.from(assignmentPayload),
    );
    final correlation = _assignmentCorrelation(message);
    if (!acceptingNewWork) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {
          'accepted': false,
          'reason': _draining ? 'workspace_draining' : 'workspace_paused'
        },
      )));
      return;
    }
    final journalState = await assignmentJournal?.reconcile();
    final previous = journalState?[context.assignmentId];
    if (previous != null) {
      if (previous.status == AssignmentStatus.completed &&
          previous.result != null) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.ack',
          correlation,
          {'accepted': true, 'estimatedStartMs': 0},
        )));
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.result',
          correlation,
          {
            'status': 'completed',
            'summary': previous.result!['summary'] ??
                'Assignment replayed from the local journal',
            'output': null,
            'artifactIds': previous.result!['artifactIds'] ?? const [],
          },
        )));
      } else if (previous.status == AssignmentStatus.failed) {
        _sendAssignmentError(
          socket,
          message,
          'assignment_replayed_failure',
          previous.result?['error']?.toString() ??
              'Assignment already failed locally',
          retryable: true,
        );
      } else if (previous.status == AssignmentStatus.cancelled) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.cancel.ack',
          correlation,
          {'cancelled': true, 'alreadyTerminated': true},
        )));
      } else {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.ack',
          correlation,
          {
            'accepted': false,
            'reason': 'assignment already exists in local journal',
          },
        )));
      }
      return;
    }
    await _recordAssignment(context.assignmentId, AssignmentStatus.received,
        context: context);

    if (assignmentHandler == null) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {'accepted': false, 'reason': 'no assignment handler configured'},
      )));
      return;
    }

    await _recordAssignment(context.assignmentId, AssignmentStatus.running,
        context: context);
    _activeAssignments.add(context.assignmentId);
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.ack',
      correlation,
      {'accepted': true, 'estimatedStartMs': 0},
    )));
    try {
      final result = await _runAssignmentWithRuntimeFence(context);
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.result',
        correlation,
        {
          'status': 'completed',
          'summary': result.summary,
          'output': result.output,
          'artifactIds': result.artifactIds,
          if (result.evidence != null)
            'evidence': {
              'observedAt': DateTime.now().toUtc().toIso8601String(),
              ...result.evidence!,
            },
        },
      )));
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.completed,
        context: context,
        result: {'summary': result.summary, 'artifactIds': result.artifactIds},
      );
    } catch (error) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.error',
        correlation,
        {
          'status': 'failed',
          'error': {
            'code': 'host_assignment_failed',
            'message': '$error',
            'retryable': true,
          },
        },
      )));
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.failed,
        context: context,
        result: {'error': '$error'},
      );
    } finally {
      _activeAssignments.remove(context.assignmentId);
    }
  }

  Future<HostAssignmentResult> _runAssignmentWithRuntimeFence(
      HostAssignmentContext context) async {
    final handler = assignmentHandler!;
    if (context.payload['executionClass'] != 'stateful_workstream') {
      return handler(context);
    }
    final manager = workstreamCheckoutManager;
    final hasCompleteCheckoutSnapshot =
        context.payload['checkoutId'] is String &&
            context.payload['leaseId'] is String &&
            context.payload['expectedRevision'] is String &&
            context.payload['fencingToken'] is int;
    if (manager == null || !hasCompleteCheckoutSnapshot) {
      // WD-7: a Workstream may execute in its empty, marker-backed directory.
      // Checkout metadata remains an optional compatibility/recovery layer.
      return handler(context);
    }
    return manager.withStatefulLease(
      snapshot: context.payload,
      action: (_) => handler(context),
    );
  }

  Future<void> _handleAssignmentCancel(Map<String, dynamic> message) async {
    final socket = _socket;
    if (socket == null ||
        message['assignmentId'] is! String ||
        message['executionWorkspaceId'] != workspaceId ||
        message['workspaceRuntimeId'] != hostId) {
      return;
    }
    final assignmentId = message['assignmentId'] as String;
    final payload = message['payload'];
    final reason = payload is Map && payload['reason'] is String
        ? payload['reason'] as String
        : 'Cloud requested cancellation';
    var cancelled = false;
    if (_activeAssignments.contains(assignmentId) &&
        assignmentCancellationHandler != null) {
      cancelled = await assignmentCancellationHandler!(assignmentId, reason);
    }
    final alreadyTerminated = !_activeAssignments.contains(assignmentId);
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.cancel.ack',
      _assignmentCorrelation(message),
      {
        'cancelled': cancelled,
        'alreadyTerminated': alreadyTerminated,
      },
    )));
  }

  String? _validateAssignmentPayload(Object? rawPayload) {
    if (rawPayload is! Map<String, dynamic>) {
      return 'Assignment payload must be an object';
    }
    if (rawPayload['snapshot'] == null &&
        rawPayload['objective'] == null &&
        rawPayload['role'] == null) {
      for (final field in [
        'assignmentId',
        'executionWorkspaceId',
        'projectId',
        'runId',
        'taskId',
        'attemptId',
        'requestedByUserId',
        'workspaceRuntimeId',
        'workerId',
        'resolvedWorkerVersion',
        'credentialProfileId',
        'config',
        'permissions',
        'contextRefs',
        'timeoutMs',
        'idempotencyKey',
      ]) {
        if (!rawPayload.containsKey(field)) {
          return 'Assignment field $field is required';
        }
      }
      if (rawPayload['config'] is! Map ||
          rawPayload['permissions'] is! List ||
          rawPayload['contextRefs'] is! List ||
          rawPayload['timeoutMs'] is! int ||
          (rawPayload['timeoutMs'] as int) < 1000) {
        return 'Assignment snapshot fields are invalid';
      }
      return null;
    }
    for (final field in [
      'objective',
      'role',
      'workerId',
      'resolvedWorkerVersion',
    ]) {
      if (rawPayload[field] is! String ||
          (rawPayload[field] as String).trim().isEmpty) {
        return 'Assignment field $field is required';
      }
    }
    if (rawPayload['input'] is! Map) {
      return 'Assignment input must be an object';
    }
    final artifactIds = rawPayload['contextArtifactIds'];
    if (artifactIds is! List || artifactIds.any((id) => id is! String)) {
      return 'Assignment contextArtifactIds must be a string array';
    }
    final timeoutMs = rawPayload['timeoutMs'];
    if (timeoutMs is! int || timeoutMs < 1000) {
      return 'Assignment timeoutMs must be at least 1000 milliseconds';
    }
    final repository = rawPayload['repository'];
    if (repository != null) {
      if (repository is! Map ||
          repository['repositoryId'] is! String ||
          (repository['repositoryId'] as String).trim().isEmpty ||
          repository['revision'] is! String ||
          (repository['revision'] as String).trim().isEmpty) {
        return 'Assignment repository must contain repositoryId and revision';
      }
    }
    return null;
  }

  void _sendAssignmentError(
    HostCloudSocket socket,
    Map<String, dynamic> message,
    String code,
    String errorMessage, {
    required bool retryable,
  }) {
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.error',
      _assignmentCorrelation(message),
      {
        'status': 'failed',
        'error': {
          'code': code,
          'message': errorMessage,
          'retryable': retryable,
        },
      },
    )));
  }

  Future<void> _recordAssignment(
    String assignmentId,
    AssignmentStatus status, {
    HostAssignmentContext? context,
    Map<String, Object?>? correlation,
    Map<String, Object?>? result,
  }) async {
    final journal = assignmentJournal;
    if (journal == null) return;
    await journal.append(AssignmentRecord(
      assignmentId: assignmentId,
      status: status,
      updatedAt: DateTime.now().toUtc(),
      workspaceId:
          context?.workspaceId ?? correlation?['workspaceId'] as String?,
      hostId: context?.hostId ?? correlation?['hostId'] as String?,
      workerId: context?.workerId ?? correlation?['workerId'] as String?,
      runId: context?.runId ?? correlation?['runId'] as String?,
      taskId: context?.taskId ?? correlation?['taskId'] as String?,
      attemptId: context?.attemptId ?? correlation?['attemptId'] as String?,
      idempotencyKey:
          context?.idempotencyKey ?? correlation?['idempotencyKey'] as String?,
      result: result,
    ));
  }

  Future<void> _reconcileSyncResponse(Map<String, Object?> payload) async {
    final rawStates = payload['assignmentStates'];
    final journal = assignmentJournal;
    if (journal == null || rawStates is! List) return;
    final states = <String, Map<String, Object?>>{};
    for (final raw in rawStates.whereType<Map>()) {
      final state = Map<String, Object?>.from(raw);
      final assignmentId = state['assignmentId'];
      if (assignmentId is String) states[assignmentId] = state;
    }
    final records = await journal.reconcile();
    for (final record in records.values) {
      final state = states[record.assignmentId];
      if (state == null) continue;
      final cloudStatus = state['status'];
      if (cloudStatus is! String) continue;
      if (const {'completed', 'failed', 'cancelled'}.contains(cloudStatus)) {
        if (record.status != AssignmentStatus.reconciled) {
          await _recordAssignment(
              record.assignmentId, AssignmentStatus.reconciled,
              correlation: _recordCorrelation(record), result: record.result);
        }
        continue;
      }
      if (!const {
        AssignmentStatus.completed,
        AssignmentStatus.failed,
        AssignmentStatus.cancelled,
      }.contains(record.status)) {
        continue;
      }
      final correlation = _recordCorrelation(record);
      if (correlation.values.any((value) => value is! String)) continue;
      final socket = _socket;
      if (socket == null || sessionId == null) continue;
      if (record.status == AssignmentStatus.completed) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.result',
          correlation,
          {
            'status': 'completed',
            'summary':
                record.result?['summary'] ?? 'Recovered assignment result',
            'output': null,
            'artifactIds': record.result?['artifactIds'] ?? const [],
          },
        )));
      } else if (record.status == AssignmentStatus.failed) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.error',
          correlation,
          {
            'status': 'failed',
            'error': {
              'code': 'host_assignment_recovered_failure',
              'message':
                  record.result?['error'] ?? 'Recovered assignment failure',
              'retryable': false,
            },
          },
        )));
      } else {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.cancelled',
          correlation,
          {
            'status': 'cancelled',
            'reason':
                'Assignment was cancelled while the Workspace was offline',
          },
        )));
      }
      await _recordAssignment(record.assignmentId, AssignmentStatus.reconciled,
          correlation: correlation, result: record.result);
    }
  }

  Map<String, Object?> _recordCorrelation(AssignmentRecord record) => {
        'executionWorkspaceId': record.workspaceId,
        'workspaceRuntimeId': record.hostId,
        'workerId': record.workerId,
        'runId': record.runId,
        'taskId': record.taskId,
        'attemptId': record.attemptId,
        'assignmentId': record.assignmentId,
        'idempotencyKey': record.idempotencyKey,
      };

  Map<String, Object?> _assignmentCorrelation(Map<String, dynamic> message) => {
        'executionWorkspaceId': message['executionWorkspaceId'],
        'workspaceRuntimeId': message['workspaceRuntimeId'],
        'workerId': message['workerId'],
        'runId': message['runId'],
        'taskId': message['taskId'],
        'attemptId': message['attemptId'],
        'assignmentId': message['assignmentId'],
        'idempotencyKey': message['idempotencyKey'],
      };

  Map<String, Object?> _assignmentEnvelope(
    String type,
    Map<String, Object?> correlation,
    Map<String, Object?> payload,
  ) =>
      _legacyMap({
        ..._envelope(type, payload),
        ...correlation,
      });

  Future<void> _sendSyncRequest() async {
    final socket = _socket;
    if (socket == null || sessionId == null) return;
    final recoveredAssignmentIds = <String>{...unreconciledAssignmentIds};
    final journal = assignmentJournal;
    if (journal != null) {
      final records = await journal.reconcile();
      for (final record in records.values) {
        // Include terminal local results until Cloud acknowledges them. This
        // closes the crash window after worker success but before the result
        // reaches Cloud.
        if (record.status != AssignmentStatus.reconciled) {
          recoveredAssignmentIds.add(record.assignmentId);
        }
      }
    }
    socket.send(jsonEncode(_envelope('workspace.sync.request', {
      'workspaceRuntimeId': hostId,
      'executionWorkspaceId': workspaceId,
      if (recoveredAssignmentIds.isNotEmpty)
        'unreconciledAssignmentIds': recoveredAssignmentIds.toList()..sort(),
    })));
  }

  Future<void> _reconnect() async {
    if (_closing || _reconnecting) return;
    _reconnecting = true;
    try {
      while (!_closing) {
        reconnectCount += 1;
        final multiplier = 1 << _reconnectAttempt.clamp(0, 8);
        final delay = Duration(
          microseconds: (reconnectBaseDelay.inMicroseconds * multiplier)
              .clamp(0, reconnectMaxDelay.inMicroseconds),
        );
        await Future<void>.delayed(delay);
        if (_closing) return;
        try {
          await _open();
          return;
        } on Object {
          _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 8);
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> close() async {
    _closing = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimeoutTimer?.cancel();
    await _subscription?.cancel();
    await _socket?.close();
    _socket = null;
  }
}

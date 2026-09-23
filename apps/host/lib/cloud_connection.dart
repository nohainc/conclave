import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'credential_profiles.dart';
import 'package:conclave_protocol/conclave_protocol.dart';
import 'worker_protocol.dart';

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
typedef HostSyncHandler = Future<void> Function(
  Map<String, Object?> payload,
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
    this.name = 'Conclave Host',
    String? hostname,
    this.hostVersion = '0.1.0',
    Map<String, Object?>? capabilities,
    this.installedWorkerVersions = const {},
    this.activeWorkerIds = const [],
    this.unreconciledAssignmentIds = const [],
    this.assignmentHandler,
    this.assignmentCancellationHandler,
    this.assignmentJournal,
    this.syncHandler,
    this.hostUpdateAvailableHandler,
    this.heartbeat = const Duration(seconds: 15),
    this.reconnectBaseDelay = const Duration(milliseconds: 10),
    this.reconnectMaxDelay = const Duration(seconds: 5),
  })  : authorizedWorkspaceIds = {
          workspaceId,
          ...?authorizedWorkspaceIds,
        },
        hostname = hostname ?? Platform.localHostname,
        capabilities = capabilities ?? _defaultCapabilities();

  final Uri uri;
  final String hostId;
  final String workspaceId;
  final Set<String> authorizedWorkspaceIds;
  final HostCloudSocketFactory factory;
  final String name;
  final String hostname;
  final String hostVersion;
  final Map<String, Object?> capabilities;
  final Map<String, String> installedWorkerVersions;
  final List<String> activeWorkerIds;
  final List<String> unreconciledAssignmentIds;
  final HostAssignmentHandler? assignmentHandler;
  final HostAssignmentCancellationHandler? assignmentCancellationHandler;
  final AssignmentJournal? assignmentJournal;
  final HostSyncHandler? syncHandler;
  final HostUpdateAvailableHandler? hostUpdateAvailableHandler;
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
  List<String> get activeAssignmentIds => _activeAssignments.toList()..sort();
  int _messageSequence = 0;
  Map<String, Object?>? syncResponse;
  final _activeAssignments = <String>{};
  final _lastEphemeralWorkerEvent = <String, DateTime>{};

  void reportWorkerStatuses(List<Map<String, Object?>> workers) {
    _sendIfConnected('worker.status', {'workers': workers});
  }

  void reportWorkerStatus({
    required String workerId,
    required String status,
    required int activeAssignments,
    String? healthDetail,
    List<String>? missingSecrets,
  }) {
    _sendIfConnected('worker.status', {
      'workerId': workerId,
      'hostId': hostId,
      'status': status,
      'activeAssignments': activeAssignments,
      if (healthDetail != null) 'healthDetail': healthDetail,
      if (missingSecrets != null) 'missingSecrets': missingSecrets,
    });
  }

  /// Reports credential metadata only. Raw secrets never cross this boundary.
  void reportCredentialStatus(CredentialProfile profile) {
    _sendIfConnected('credential.status', profile.toCloudMetadata());
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

  static const protocol = hostProtocolName;
  static const protocolVersion = hostProtocolVersion;

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
      'arch': 'x64',
      'hostVersion': '0.1.0',
      'supportedRuntimes': <String>['dart'],
      'maxConcurrentWorkers': 1,
    };
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
    socket.send(jsonEncode(_envelope('host.hello', {
      'hostId': hostId,
      'workspaceId': workspaceId,
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
        ..._envelope('host.heartbeat', {
          'hostId': hostId,
          'workspaceId': workspaceId,
          'sessionId': currentSessionId,
          'status': 'online',
          'activeWorkers': activeWorkerIds.length,
          'activeAssignments': _activeAssignments.length,
        }),
      }));
    });
  }

  Map<String, Object?> _envelope(String type, Map<String, Object?> payload) => {
        'protocol': protocol,
        'protocolVersion': protocolVersion,
        'messageId':
            'dart-${DateTime.now().microsecondsSinceEpoch}-${++_messageSequence}',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': type,
        'payload': payload,
      };

  void _handleMessage(Object? raw) {
    if (raw is! String) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final remoteProtocolVersion = decoded['protocolVersion'];
    if (remoteProtocolVersion is! String ||
        !_isCompatibleProtocolVersion(remoteProtocolVersion)) {
      return;
    }
    try {
      HostProtocolMessage.parse(decoded);
    } on ProtocolException {
      return;
    }
    if (decoded['type'] == 'host.hello.ack') {
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic> && payload['sessionId'] is String) {
        sessionId = payload['sessionId'] as String;
        final bindings = payload['activeWorkspaceBindings'];
        if (bindings is List && bindings.every((value) => value is String)) {
          authorizedWorkspaceIds
            ..clear()
            ..addAll(bindings.cast<String>())
            ..add(workspaceId);
        }
        unawaited(_sendSyncRequest());
      }
    } else if (decoded['type'] == 'host.sync.result') {
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic>) {
        syncResponse = Map<String, Object?>.from(payload);
        unawaited(_reconcileSyncResponse(syncResponse!).catchError((_) {}));
        final handler = syncHandler;
        if (handler != null) {
          unawaited(handler(syncResponse!).catchError((_) {}));
        }
      }
    } else if (decoded['type'] == 'host.update') {
      final payload = decoded['payload'];
      final handler = hostUpdateAvailableHandler;
      if (payload is Map<String, dynamic> && handler != null) {
        unawaited(
          handler(Map<String, Object?>.from(payload)).catchError((_) {}),
        );
      }
    } else if (decoded['type'] == 'host.heartbeat.ack') {
      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer = null;
    } else if (decoded['type'] == 'assignment.start') {
      unawaited(_handleAssignmentStart(decoded));
    } else if (decoded['type'] == 'assignment.cancel') {
      unawaited(_handleAssignmentCancel(decoded));
    }
  }

  Future<void> _handleAssignmentStart(Map<String, dynamic> message) async {
    final socket = _socket;
    final payload = message['payload'];
    final requiredFields = [
      'workspaceId',
      'hostId',
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

    if (!authorizedWorkspaceIds.contains(message['workspaceId']) ||
        message['hostId'] != hostId) {
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
      workspaceId: message['workspaceId'] as String,
      hostId: message['hostId'] as String,
      workerId: message['workerId'] as String,
      runId: message['runId'] as String,
      taskId: message['taskId'] as String,
      attemptId: message['attemptId'] as String,
      assignmentId: message['assignmentId'] as String,
      idempotencyKey: message['idempotencyKey'] as String,
      payload: Map<String, Object?>.from(assignmentPayload),
    );
    final correlation = _assignmentCorrelation(message);
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
      final result = await assignmentHandler!(context);
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

  Future<void> _handleAssignmentCancel(Map<String, dynamic> message) async {
    final socket = _socket;
    if (socket == null ||
        message['assignmentId'] is! String ||
        message['workspaceId'] != workspaceId ||
        message['hostId'] != hostId) {
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
        'workspaceId',
        'projectId',
        'runId',
        'taskId',
        'attemptId',
        'requestedByUserId',
        'hostId',
        'workerId',
        'resolvedWorkerVersion',
        'credentialProfileId',
        'config',
        'sessionPolicy',
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
            'reason': 'Assignment was cancelled while the Host was offline',
          },
        )));
      }
      await _recordAssignment(record.assignmentId, AssignmentStatus.reconciled,
          correlation: correlation, result: record.result);
    }
  }

  Map<String, Object?> _recordCorrelation(AssignmentRecord record) => {
        'workspaceId': record.workspaceId,
        'hostId': record.hostId,
        'workerId': record.workerId,
        'runId': record.runId,
        'taskId': record.taskId,
        'attemptId': record.attemptId,
        'assignmentId': record.assignmentId,
        'idempotencyKey': record.idempotencyKey,
      };

  Map<String, Object?> _assignmentCorrelation(Map<String, dynamic> message) => {
        'workspaceId': message['workspaceId'],
        'hostId': message['hostId'],
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
      {
        ..._envelope(type, payload),
        ...correlation,
      };

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
    socket.send(jsonEncode(_envelope('host.sync.request', {
      'hostId': hostId,
      'workspaceId': workspaceId,
      'installedWorkerVersions': installedWorkerVersions,
      'activeWorkerIds': activeWorkerIds,
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

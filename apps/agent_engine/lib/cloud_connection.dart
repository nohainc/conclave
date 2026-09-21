import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';

abstract interface class AgentCloudSocket {
  Stream<Object?> get messages;
  void send(Object message);
  Future<void> close();
}

typedef AgentCloudSocketFactory = Future<AgentCloudSocket> Function(Uri uri);

class AgentAssignmentContext {
  const AgentAssignmentContext({
    required this.workspaceId,
    required this.agentId,
    required this.workerId,
    required this.runId,
    required this.taskId,
    required this.attemptId,
    required this.assignmentId,
    required this.idempotencyKey,
    required this.payload,
  });

  final String workspaceId;
  final String agentId;
  final String workerId;
  final String runId;
  final String taskId;
  final String attemptId;
  final String assignmentId;
  final String idempotencyKey;
  final Map<String, Object?> payload;
}

class AgentAssignmentResult {
  const AgentAssignmentResult({
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

typedef AgentAssignmentHandler = Future<AgentAssignmentResult> Function(
    AgentAssignmentContext context);
typedef AgentAssignmentCancellationHandler = Future<bool> Function(
  String assignmentId,
  String reason,
);

class IoAgentCloudSocket implements AgentCloudSocket {
  IoAgentCloudSocket(this.socket);
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

Future<AgentCloudSocket> connectIoAgentCloudSocket(
  Uri uri, {
  String? authToken,
}) async {
  final socket = await WebSocket.connect(
    uri.toString(),
    headers: authToken == null
        ? null
        : <String, String>{'Authorization': 'Bearer $authToken'},
  );
  return IoAgentCloudSocket(socket);
}

class AgentCloudConnection {
  AgentCloudConnection({
    required this.uri,
    required this.agentId,
    required this.workspaceId,
    required this.factory,
    this.name = 'Conclave Agent',
    String? hostname,
    this.agentVersion = '0.1.0',
    Map<String, Object?>? capabilities,
    this.installedPluginVersions = const {},
    this.activeWorkerIds = const [],
    this.unreconciledAssignmentIds = const [],
    this.assignmentHandler,
    this.assignmentCancellationHandler,
    this.assignmentJournal,
    this.heartbeat = const Duration(seconds: 15),
  })  : hostname = hostname ?? Platform.localHostname,
        capabilities = capabilities ?? _defaultCapabilities();

  final Uri uri;
  final String agentId;
  final String workspaceId;
  final AgentCloudSocketFactory factory;
  final String name;
  final String hostname;
  final String agentVersion;
  final Map<String, Object?> capabilities;
  final Map<String, String> installedPluginVersions;
  final List<String> activeWorkerIds;
  final List<String> unreconciledAssignmentIds;
  final AgentAssignmentHandler? assignmentHandler;
  final AgentAssignmentCancellationHandler? assignmentCancellationHandler;
  final AssignmentJournal? assignmentJournal;
  final Duration heartbeat;
  AgentCloudSocket? _socket;
  Timer? _heartbeatTimer;
  StreamSubscription<Object?>? _subscription;
  bool _closing = false;
  int reconnectCount = 0;
  String? sessionId;
  int _messageSequence = 0;
  Map<String, Object?>? syncResponse;
  final _activeAssignments = <String>{};

  static const protocol = 'conclave.agent-protocol';
  static const protocolVersion = '2.0';

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
      'agentVersion': '0.1.0',
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
    await _subscription?.cancel();
    _subscription = socket.messages.listen(
      _handleMessage,
      onDone: () => unawaited(_reconnect()),
      onError: (_) => unawaited(_reconnect()),
    );
    socket.send(jsonEncode(_envelope('agent.hello', {
      'agentId': agentId,
      'workspaceId': workspaceId,
      'name': name,
      'hostname': hostname,
      'agentVersion': agentVersion,
      'capabilities': capabilities,
    })));
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      final currentSessionId = sessionId;
      if (currentSessionId == null) return;
      socket.send(jsonEncode({
        ..._envelope('agent.heartbeat', {
          'agentId': agentId,
          'workspaceId': workspaceId,
          'sessionId': currentSessionId,
          'status': 'online',
          'activeWorkers': 0,
          'activeAssignments': 0,
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
    if (decoded['protocol'] != protocol ||
        decoded['protocolVersion'] != protocolVersion) {
      return;
    }
    if (decoded['type'] == 'agent.hello.ack') {
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic> && payload['sessionId'] is String) {
        sessionId = payload['sessionId'] as String;
        _sendSyncRequest();
      }
    } else if (decoded['type'] == 'agent.sync.response') {
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic>) {
        syncResponse = Map<String, Object?>.from(payload);
      }
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
      'agentId',
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

    if (message['workspaceId'] != workspaceId ||
        message['agentId'] != agentId) {
      _sendAssignmentError(
        socket,
        message,
        'assignment_context_mismatch',
        'Assignment is not addressed to this agent/workspace',
        retryable: false,
      );
      return;
    }

    final payloadError = _validateAssignmentPayload(payload);
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

    final context = AgentAssignmentContext(
      workspaceId: message['workspaceId'] as String,
      agentId: message['agentId'] as String,
      workerId: message['workerId'] as String,
      runId: message['runId'] as String,
      taskId: message['taskId'] as String,
      attemptId: message['attemptId'] as String,
      assignmentId: message['assignmentId'] as String,
      idempotencyKey: message['idempotencyKey'] as String,
      payload: Map<String, Object?>.from(payload),
    );
    final correlation = _assignmentCorrelation(message);
    final journalState = await assignmentJournal?.reconcile();
    final previous = journalState?[context.assignmentId];
    if (previous?.status == AssignmentStatus.completed &&
        previous?.result != null) {
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
          'summary': previous!.result!['summary'] ??
              'Assignment replayed from the local journal',
          'output': null,
          'artifactIds': previous.result!['artifactIds'] ?? const [],
        },
      )));
      return;
    }
    await _recordAssignment(context.assignmentId, AssignmentStatus.received);

    if (assignmentHandler == null) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {'accepted': false, 'reason': 'no assignment handler configured'},
      )));
      return;
    }

    await _recordAssignment(context.assignmentId, AssignmentStatus.running);
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
        result: {'summary': result.summary, 'artifactIds': result.artifactIds},
      );
    } catch (error) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.error',
        correlation,
        {
          'status': 'failed',
          'error': {
            'code': 'agent_assignment_failed',
            'message': '$error',
            'retryable': true,
          },
        },
      )));
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.failed,
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
        message['agentId'] != agentId) {
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
    for (final field in [
      'objective',
      'role',
      'pluginId',
      'resolvedPluginVersion',
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
    return null;
  }

  void _sendAssignmentError(
    AgentCloudSocket socket,
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
    Map<String, Object?>? result,
  }) async {
    final journal = assignmentJournal;
    if (journal == null) return;
    await journal.append(AssignmentRecord(
      assignmentId: assignmentId,
      status: status,
      updatedAt: DateTime.now().toUtc(),
      result: result,
    ));
  }

  Map<String, Object?> _assignmentCorrelation(Map<String, dynamic> message) => {
        'workspaceId': message['workspaceId'],
        'agentId': message['agentId'],
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

  void _sendSyncRequest() {
    final socket = _socket;
    if (socket == null || sessionId == null) return;
    socket.send(jsonEncode(_envelope('agent.sync.request', {
      'agentId': agentId,
      'workspaceId': workspaceId,
      'installedPluginVersions': installedPluginVersions,
      'activeWorkerIds': activeWorkerIds,
      if (unreconciledAssignmentIds.isNotEmpty)
        'unreconciledAssignmentIds': unreconciledAssignmentIds,
    })));
  }

  Future<void> _reconnect() async {
    if (_closing) return;
    reconnectCount += 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (!_closing) await _open();
  }

  Future<void> close() async {
    _closing = true;
    _heartbeatTimer?.cancel();
    await _subscription?.cancel();
    await _socket?.close();
    _socket = null;
  }
}

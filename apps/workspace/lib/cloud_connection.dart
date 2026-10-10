import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'assignment_journal.dart';
import 'workspace_registration.dart';
import 'workspace_transport.dart';

part 'cloud_connection/assignment_handlers.dart';

class WorkspaceAssignmentContext {
  const WorkspaceAssignmentContext({
    required this.workspaceId,
    required this.workspaceRuntimeId,
    required this.workerId,
    required this.runId,
    required this.taskId,
    required this.attemptId,
    required this.assignmentId,
    required this.idempotencyKey,
    required this.payload,
  });

  final String workspaceId;
  final String workspaceRuntimeId;
  final String workerId;
  final String runId;
  final String taskId;
  final String attemptId;
  final String assignmentId;
  final String idempotencyKey;
  final Map<String, Object?> payload;

  WorkspaceAssignmentContext copyWith({
    String? workerId,
    Map<String, Object?>? payload,
  }) =>
      WorkspaceAssignmentContext(
        workspaceId: workspaceId,
        workspaceRuntimeId: workspaceRuntimeId,
        workerId: workerId ?? this.workerId,
        runId: runId,
        taskId: taskId,
        attemptId: attemptId,
        assignmentId: assignmentId,
        idempotencyKey: idempotencyKey,
        payload: payload ?? this.payload,
      );
}

class WorkspaceAssignmentResult {
  const WorkspaceAssignmentResult({
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

typedef WorkspaceAssignmentHandler = Future<WorkspaceAssignmentResult> Function(
    WorkspaceAssignmentContext context);
typedef WorkspaceAssignmentCancellationHandler = Future<bool> Function(
  String assignmentId,
  String reason,
);
typedef WorkspaceUpdateAvailableHandler = Future<void> Function(
  Map<String, Object?> payload,
);

enum WorkspaceConnectionStage {
  validating,
  offline,
  connecting,
  authenticating,
  synchronizing,
  ready,
  reconnecting,
  switchingToWebSocket,
}

class WorkspaceConnectionPreflightException implements Exception {
  const WorkspaceConnectionPreflightException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A normalized local assignment failure safe to report across the runtime link.
class AssignmentExecutionFailure implements Exception {
  const AssignmentExecutionFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.localDiagnostic,
  });

  final String code;
  final String message;
  final bool retryable;

  /// Redacted, bounded local details for Workspace diagnostics only. Runtime
  /// Cloud reporting deliberately serializes only [code], [message] and
  /// [retryable].
  final String? localDiagnostic;

  @override
  String toString() => message;
}

class WebSocketWorkspaceTransport implements WorkspaceTransport {
  WebSocketWorkspaceTransport(this.socket);
  final WebSocket socket;

  @override
  Stream<Object?> get messages => socket;

  @override
  void send(Object message) => socket.add(message);

  @override
  Future<void> close() async {
    try {
      await socket.close(WebSocketStatus.normalClosure).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          // Normal closure handshake timed out (e.g. network dead / wake from sleep);
          // do not block connection cleanup.
        },
      );
    } catch (_) {
      // Ignore errors on close to ensure teardown always finishes.
    }
  }
}

Future<WorkspaceTransport> connectWebSocketWorkspaceTransport(
  Uri uri, {
  String? authToken,
  Duration connectTimeout = const Duration(seconds: 15),
}) async {
  final socketUri =
      uri.hasPort ? uri : uri.replace(port: uri.scheme == 'wss' ? 443 : 80);
  // A fresh client discards stale pooled sockets/DNS state after sleep.
  final client = HttpClient();
  var expired = false;
  final pending = WebSocket.connect(
    socketUri.toString(),
    customClient: client,
    headers: authToken == null
        ? null
        : <String, String>{'Authorization': 'Bearer $authToken'},
  );
  unawaited(pending.then<void>((socket) async {
    if (expired) await socket.close();
  }, onError: (Object _) {}).catchError((Object _) {}));
  late final WebSocket socket;
  try {
    socket = await pending.timeout(connectTimeout);
  } on Object {
    expired = true;
    rethrow;
  } finally {
    client.close(force: true);
  }

  socket.pingInterval = const Duration(seconds: 10);
  return WebSocketWorkspaceTransport(socket);
}

class WorkspaceCloudConnection {
  WorkspaceCloudConnection({
    required this.uri,
    required this.workspaceRuntimeId,
    required this.workspaceId,
    required this.factory,
    this.fallbackFactory,
    Set<String>? authorizedWorkspaceIds,
    this.name = 'Conclave Workspace',
    String? hostname,
    this.workspaceVersion = conclaveWorkspaceAppVersion,
    Map<String, Object?>? capabilities,
    this.activeWorkerIds = const [],
    this.unreconciledAssignmentIds = const [],
    this.assignmentHandler,
    this.assignmentCancellationHandler,
    this.assignmentJournal,
    this.workerInventoryProvider,
    this.onSessionReady,
    this.workspaceUpdateAvailableHandler,
    this.heartbeat = const Duration(seconds: 15),
    this.reconnectBaseDelay = const Duration(milliseconds: 10),
    this.reconnectMaxDelay = const Duration(seconds: 5),
    this.protocolHandshakeTimeout = const Duration(seconds: 15),
    this.syncTimeout = const Duration(seconds: 20),
    this.webSocketProbeInterval = const Duration(minutes: 5),
    this.webSocketProbeMaxInterval = const Duration(hours: 1),
    this.webSocketFailureLimit = 3,
    this.credentialAvailable = true,
  })  : authorizedWorkspaceIds = {
          workspaceId,
          ...?authorizedWorkspaceIds,
        },
        hostname = hostname ?? Platform.localHostname,
        capabilities = capabilities ?? _defaultCapabilities();

  final Uri uri;
  final String workspaceRuntimeId;
  final String workspaceId;
  final Set<String> authorizedWorkspaceIds;
  final WorkspaceTransportFactory factory;
  final WorkspaceTransportFactory? fallbackFactory;
  final String name;
  final String hostname;
  final String workspaceVersion;
  final Map<String, Object?> capabilities;
  final List<String> activeWorkerIds;
  final List<String> unreconciledAssignmentIds;
  final WorkspaceAssignmentHandler? assignmentHandler;
  final WorkspaceAssignmentCancellationHandler? assignmentCancellationHandler;
  final AssignmentJournal? assignmentJournal;
  final Future<List<Map<String, Object?>>> Function()? workerInventoryProvider;
  final Future<void> Function()? onSessionReady;
  final WorkspaceUpdateAvailableHandler? workspaceUpdateAvailableHandler;
  final Duration heartbeat;
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;
  final Duration protocolHandshakeTimeout;
  final Duration syncTimeout;
  final Duration webSocketProbeInterval;
  final Duration webSocketProbeMaxInterval;
  int _webSocketProbeFailures = 0;
  int _transportGeneration = 0;
  final int webSocketFailureLimit;
  final bool credentialAvailable;
  WorkspaceTransport? _transport;
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeoutTimer;
  Timer? _protocolHandshakeTimer;
  Timer? _syncTimer;
  Timer? _webSocketProbeTimer;
  StreamSubscription<Object?>? _subscription;
  Completer<void>? _reconnectWakeup;
  bool _closing = false;
  bool _reconnecting = false;
  bool _preferFallbackTransport = false;
  bool _probingWebSocket = false;
  int _reconnectAttempt = 0;
  int reconnectCount = 0;
  String? sessionId;
  bool get isConnected => sessionId != null;
  WorkspaceConnectionStage connectionStage = WorkspaceConnectionStage.offline;
  DateTime? lastConnectionAttemptAt;
  DateTime? lastWebSocketUpgradeAt;
  String? activeTransportMode;
  String? _pendingTransportMode;
  String? lastWebSocketFailure;
  int? lastWebSocketHttpStatusCode;
  DateTime? lastWebSocketFailureAt;
  String fallbackHealthStatus = 'not configured';
  String get transportMode => activeTransportMode ?? 'offline';
  DateTime? lastHelloSentAt;
  DateTime? lastHelloAcknowledgedAt;
  DateTime? lastReadyAt;
  String? lastConnectionError;
  int? lastHttpStatusCode;
  String lastDnsTlsStatus = 'not checked';
  bool _workerInventorySent = false;
  bool _syncResultReceived = false;
  bool _syncReconciliationComplete = false;
  String? _readyCallbackSessionId;
  String? _helloMessageId;
  String? _syncRequestMessageId;

  String get protocolHelloStatus {
    if (lastHelloSentAt == null) return 'not started';
    if (sessionId != null) return 'acknowledged';
    if (lastConnectionError?.contains('did not acknowledge workspace.hello') ==
        true) {
      return 'timed out';
    }
    return 'waiting for acknowledgement';
  }

  void validateConfiguration() {
    if (!credentialAvailable) {
      throw const WorkspaceConnectionPreflightException(
        'The Workspace runtime credential is missing from secure storage.',
      );
    }
    if (!const {'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) ||
        uri.hasFragment) {
      throw const WorkspaceConnectionPreflightException(
        'The Cloud WebSocket endpoint is invalid. Expected ws/wss, a workspace, '
        'a valid port, and no URL fragment.',
      );
    }
    if (uri.path != '/api/workspace-gateway/connect' ||
        uri.queryParameters['workspaceRuntimeId'] != workspaceRuntimeId) {
      throw const WorkspaceConnectionPreflightException(
        'The Cloud WebSocket endpoint must include the Workspace Gateway '
        'path and this runtime ID.',
      );
    }
  }

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

  Future<bool> cancelActiveAssignment(
    String assignmentId, {
    String reason = 'Cancelled by Workspace user',
  }) async {
    if (!_activeAssignments.contains(assignmentId)) return false;
    final cancel = assignmentCancellationHandler;
    if (cancel == null) return false;
    return cancel(assignmentId, reason);
  }

  int _messageSequence = 0;
  int _heartbeatCount = 0;
  Map<String, Object?>? syncResponse;
  final _activeAssignments = <String>{};
  final _cancelledBeforeStart = <String>{};
  final _pendingAssignmentsDuringSync = <Map<String, dynamic>>[];
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
    if (provider == null) {
      _workerInventorySent = true;
      _completeSynchronizationWhenReady();
      return;
    }
    if (sessionId == null) return;
    try {
      reportWorkerInventory(await provider());
      lastInventorySyncAt = DateTime.now().toUtc();
      _workerInventorySent = true;
      _completeSynchronizationWhenReady();
    } on Object {
      lastConnectionError =
          'Workspace authenticated, but its Worker inventory could not be read.';
    }
  }

  /// Reports only logical Thread readiness. Local absolute paths and
  /// repository locations never cross the runtime boundary.
  void reportThreadStatus({
    required String spaceId,
    required String threadId,
    required String workingDirectoryState,
  }) {
    if (!const {'absent', 'ready', 'conflict', 'unavailable'}
        .contains(workingDirectoryState)) {
      throw ArgumentError.value(workingDirectoryState, 'workingDirectoryState');
    }
    _sendIfConnected('thread.status', {
      'spaceId': spaceId,
      'threadId': threadId,
      'workingDirectoryState': workingDirectoryState,
    });
  }

  /// Relays validated Worker facts using the trusted Assignment correlation.
  /// Workers never provide Workspace, Workspace, Run, or Task identity.
  void reportWorkerProgress(
    WorkspaceAssignmentContext context,
    WorkerProgress progress,
  ) {
    if (progress.assignmentId != context.assignmentId) return;
    final socket = _transport;
    if (socket == null || sessionId == null) return;
    final now = DateTime.now().toUtc();
    final last = _lastEphemeralWorkerEvent[context.assignmentId];
    if (last != null && now.difference(last).inMilliseconds < 100) return;
    _lastEphemeralWorkerEvent[context.assignmentId] = now;
    final correlation = {
      'workspaceId': context.workspaceId,
      'workspaceRuntimeId': context.workspaceRuntimeId,
      'workerId': context.workerId,
      'runId': context.runId,
      'taskId': context.taskId,
      'attemptId': context.attemptId,
      'assignmentId': context.assignmentId,
      'idempotencyKey': context.idempotencyKey,
    };
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.progress',
      correlation,
      {
        'assignmentId': context.assignmentId,
        'percentage': progress.percentage,
        'message': progress.message ?? '',
        'observedAt': now.toIso8601String(),
      },
    )));
  }

  void _sendIfConnected(String type, Map<String, Object?> payload) {
    final socket = _transport;
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
      'workspaceVersion': conclaveWorkspaceAppVersion,
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
    lastConnectionAttemptAt = DateTime.now().toUtc();
    connectionStage = WorkspaceConnectionStage.validating;
    try {
      validateConfiguration();
    } on Object catch (error) {
      lastConnectionError = error.toString();
      connectionStage = WorkspaceConnectionStage.offline;
      rethrow;
    }
    await _open();
  }

  /// Fully tears down any existing timers, subscriptions, and socket objects
  /// with a timeout guarantee so reconnects can never hang on dead resources.
  Future<void> _cleanCurrentTransport() async {
    _transportGeneration++;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatTimeoutTimer?.cancel();
    _heartbeatTimeoutTimer = null;
    _protocolHandshakeTimer?.cancel();
    _protocolHandshakeTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    _webSocketProbeTimer?.cancel();
    _webSocketProbeTimer = null;
    final sub = _subscription;
    _subscription = null;
    if (sub != null) {
      await sub.cancel().catchError((_) {});
    }
    final transport = _transport;
    _transport = null;
    activeTransportMode = null;
    _pendingTransportMode = null;
    sessionId = null;
    if (transport != null) {
      try {
        await transport.close().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            // Transport closure timed out; proceed with teardown.
          },
        );
      } catch (_) {
        // Ignore errors on transport close
      }
    }
  }

  /// Requests an immediate transport retry without recreating local Workers
  /// or interrupting their assignment processes.
  Future<void> retryNow() async {
    if (_closing) _closing = false;
    _reconnectAttempt = 0;
    final wakeup = _reconnectWakeup;
    if (_reconnecting) {
      if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
      return;
    }
    await _cleanCurrentTransport();
    await _open();
  }

  Future<void> _open({WorkspaceTransport? preparedWebSocket}) async {
    await _cleanCurrentTransport();
    if (_closing && preparedWebSocket != null) {
      await preparedWebSocket.close();
      return;
    }
    lastConnectionAttemptAt = DateTime.now().toUtc();
    connectionStage = WorkspaceConnectionStage.connecting;
    lastHelloSentAt = null;
    _helloMessageId = null;
    _syncRequestMessageId = null;
    activeTransportMode = null;
    _pendingTransportMode = null;
    _workerInventorySent = workerInventoryProvider == null;
    _syncResultReceived = false;
    _syncReconciliationComplete = false;
    _readyCallbackSessionId = null;
    late final WorkspaceTransport socket;
    var selectedWebSocket = false;
    try {
      final fallback = fallbackFactory;
      final gatewayPath = uri.path.indexOf('/api/workspace-gateway');
      final basePath =
          gatewayPath < 0 ? '' : uri.path.substring(0, gatewayPath);
      final httpUri = uri.replace(
        scheme: uri.scheme == 'wss' ? 'https' : 'http',
        path: basePath,
        query: null,
        fragment: null,
      );
      if (preparedWebSocket != null) {
        socket = preparedWebSocket;
        selectedWebSocket = true;
      } else if (_preferFallbackTransport && fallback != null) {
        try {
          socket = await fallback(httpUri).timeout(
            protocolHandshakeTimeout,
            onTimeout: () => throw const SocketException(
              'HTTP fallback connection timed out',
            ),
          );
        } on Object {
          socket = await factory(uri).timeout(
            protocolHandshakeTimeout,
            onTimeout: () => throw const SocketException(
              'WebSocket connection timed out',
            ),
          );
          selectedWebSocket = true;
        }
      } else {
        Object? lastWebSocketError;
        var connected = false;
        final attempts =
            fallback == null ? 1 : webSocketFailureLimit.clamp(1, 5);
        for (var attempt = 0; attempt < attempts; attempt++) {
          try {
            socket = await factory(uri).timeout(
              protocolHandshakeTimeout,
              onTimeout: () => throw const SocketException(
                'WebSocket connection timed out',
              ),
            );
            selectedWebSocket = true;
            connected = true;
            break;
          } on Object catch (error) {
            lastWebSocketError = error;
            _recordWebSocketFailure(error);
            if (_isTerminalWebSocketFailure(error) || attempt + 1 >= attempts) {
              break;
            }
            final delay = Duration(
              microseconds: (reconnectBaseDelay.inMicroseconds * (attempt + 1))
                  .clamp(0, reconnectMaxDelay.inMicroseconds),
            );
            if (delay > Duration.zero) await Future<void>.delayed(delay);
          }
        }
        if (!connected) {
          if (fallback == null ||
              _isTerminalWebSocketFailure(lastWebSocketError)) {
            throw lastWebSocketError ??
                StateError('WebSocket connection failed');
          }
          socket = await fallback(httpUri).timeout(
            protocolHandshakeTimeout,
            onTimeout: () => throw const SocketException(
              'HTTP fallback connection timed out',
            ),
          );
          selectedWebSocket = false;
        }
      }
    } on Object catch (error) {
      lastConnectionError = _describeConnectionError(error);
      if (!selectedWebSocket && fallbackFactory != null) {
        fallbackHealthStatus = 'unavailable';
      }
      if (error is WebSocketException) {
        lastHttpStatusCode = error.httpStatusCode;
        if (selectedWebSocket) _recordWebSocketFailure(error);
        lastDnsTlsStatus =
            error.httpStatusCode == null ? 'not confirmed' : 'passed';
      } else {
        lastDnsTlsStatus = 'not confirmed (${error.runtimeType})';
      }
      connectionStage = _closing || !_reconnecting
          ? WorkspaceConnectionStage.offline
          : WorkspaceConnectionStage.reconnecting;
      rethrow;
    }
    _transport = socket;
    lastHttpStatusCode = null;
    _pendingTransportMode = selectedWebSocket ? 'websocket' : 'http_long_poll';
    activeTransportMode =
        _probingWebSocket && _pendingTransportMode == 'websocket'
            ? 'switching_to_websocket'
            : _pendingTransportMode;
    if (_pendingTransportMode == 'http_long_poll') {
      fallbackHealthStatus = 'connecting';
    } else if (fallbackFactory != null) {
      fallbackHealthStatus = 'standby';
    }
    if (selectedWebSocket) {
      _preferFallbackTransport = false;
      lastWebSocketUpgradeAt = DateTime.now().toUtc();
    } else {
      _preferFallbackTransport = true;
    }
    lastDnsTlsStatus = 'passed';
    sessionId = null;
    _reconnectAttempt = 0;
    connectionStage = WorkspaceConnectionStage.authenticating;
    await _subscription?.cancel();
    _subscription = socket.messages.listen(
      _handleMessage,
      onDone: _handleTransportEnd,
      onError: (_) => _handleTransportEnd(),
    );
    final hello = _envelope('workspace.hello', {
      'workspaceRuntimeId': workspaceRuntimeId,
      'executionWorkspaceId': workspaceId,
      'name': name,
      'hostname': hostname,
      'workspaceVersion': workspaceVersion,
      'capabilities': capabilities,
    });
    _helloMessageId = hello['messageId'] as String;
    socket.send(jsonEncode(hello));
    lastHelloSentAt = DateTime.now().toUtc();
    _protocolHandshakeTimer?.cancel();
    _protocolHandshakeTimer = Timer(protocolHandshakeTimeout, () {
      if (sessionId != null || _closing) return;
      if (_pendingTransportMode == 'websocket' && fallbackFactory != null) {
        _preferFallbackTransport = true;
      }
      lastConnectionError =
          'Runtime transport connected, but Cloud did not acknowledge workspace.hello '
          'within ${protocolHandshakeTimeout.inSeconds} seconds.';
      if (_pendingTransportMode == 'websocket') {
        lastWebSocketFailure = lastConnectionError;
        lastWebSocketFailureAt = DateTime.now().toUtc();
      }
      connectionStage = WorkspaceConnectionStage.reconnecting;
      _handleTransportEnd();
    });
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      final currentSessionId = sessionId;
      if (currentSessionId == null) return;
      _heartbeatTimeoutTimer ??= Timer(heartbeat * 2, () {
        _heartbeatTimeoutTimer = null;
        lastConnectionError = 'Cloud heartbeat acknowledgement timed out.';
        if (_pendingTransportMode == 'websocket') {
          lastWebSocketFailure = lastConnectionError;
          lastWebSocketFailureAt = DateTime.now().toUtc();
        }
        connectionStage = WorkspaceConnectionStage.reconnecting;
        _handleTransportEnd();
      });
      socket.send(jsonEncode({
        ..._envelope('workspace.heartbeat', {
          'workspaceRuntimeId': workspaceRuntimeId,
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
      WorkspaceRuntimeMessage.parse(decoded);
    } on ProtocolException {
      return;
    }
    if (decoded['type'] == 'workspace.hello.ack') {
      final payload = decoded['payload'];
      final runtimeId = decoded['workspaceRuntimeId'];
      final executionWorkspaceId = decoded['executionWorkspaceId'];
      if (runtimeId != workspaceRuntimeId ||
          executionWorkspaceId != workspaceId ||
          decoded['correlationId'] != _helloMessageId) {
        lastConnectionError =
            'Cloud hello acknowledgement did not match this Workspace runtime.';
        if (_pendingTransportMode == 'websocket') {
          lastWebSocketFailure = lastConnectionError;
          lastWebSocketFailureAt = DateTime.now().toUtc();
        }
        connectionStage = WorkspaceConnectionStage.reconnecting;
        _handleTransportEnd();
        return;
      }
      if (payload is Map<String, dynamic> &&
          payload['sessionId'] is String &&
          (payload['sessionId'] as String).isNotEmpty) {
        _protocolHandshakeTimer?.cancel();
        _protocolHandshakeTimer = null;
        lastHelloAcknowledgedAt = DateTime.now().toUtc();
        connectionStage = WorkspaceConnectionStage.synchronizing;
        sessionId = payload['sessionId'] as String;
        _syncTimer?.cancel();
        _syncTimer = Timer(syncTimeout, () {
          if ((_syncResultReceived &&
                  _syncReconciliationComplete &&
                  _workerInventorySent) ||
              _closing) {
            return;
          }
          lastConnectionError = !_syncResultReceived
              ? 'Workspace authenticated, but Cloud synchronization did '
                  'not complete within ${syncTimeout.inSeconds} seconds.'
              : !_syncReconciliationComplete
                  ? 'Workspace synchronization completed, but assignment '
                      'reconciliation did not finish within '
                      '${syncTimeout.inSeconds} seconds.'
                  : 'Cloud synchronization completed, but the Worker inventory '
                      'did not finish within ${syncTimeout.inSeconds} seconds.';
          if (_pendingTransportMode == 'websocket') {
            lastWebSocketFailure = lastConnectionError;
            lastWebSocketFailureAt = DateTime.now().toUtc();
          }
          connectionStage = WorkspaceConnectionStage.reconnecting;
          _handleTransportEnd();
        });
        authorizedWorkspaceIds
          ..clear()
          ..add(workspaceId);
        unawaited(_sendSyncRequest());
        unawaited(_reportCurrentWorkerInventory());
      }
    } else if (decoded['type'] == 'workspace.sync.result') {
      if (decoded['workspaceRuntimeId'] != workspaceRuntimeId ||
          decoded['executionWorkspaceId'] != workspaceId ||
          decoded['correlationId'] != _syncRequestMessageId) {
        lastConnectionError =
            'Cloud synchronization response did not match this runtime session.';
        if (_pendingTransportMode == 'websocket') {
          lastWebSocketFailure = lastConnectionError;
          lastWebSocketFailureAt = DateTime.now().toUtc();
        }
        connectionStage = WorkspaceConnectionStage.reconnecting;
        _handleTransportEnd();
        return;
      }
      final payload = decoded['payload'];
      if (payload is Map<String, dynamic>) {
        syncResponse = Map<String, Object?>.from(payload);
        _syncResultReceived = true;
        unawaited(_finishSyncReconciliation(syncResponse!));
      }
    } else if (decoded['type'] == 'workspace.update') {
      final payload = decoded['payload'];
      final handler = workspaceUpdateAvailableHandler;
      if (payload is Map<String, dynamic> && handler != null) {
        unawaited(
          handler(Map<String, Object?>.from(payload)).catchError((_) {}),
        );
      }
    } else if (decoded['type'] == 'workspace.heartbeat.ack') {
      _heartbeatTimeoutTimer?.cancel();
      _heartbeatTimeoutTimer = null;
    } else if (decoded['type'] == 'thread.status') {
      // Runtime readiness is currently informational. The payload is not
      // persisted here and contains no local path.
    } else if (decoded['type'] == 'assignment.start') {
      if (connectionStage != WorkspaceConnectionStage.ready) {
        final assignmentId = decoded['assignmentId'];
        if (assignmentId is! String ||
            !_pendingAssignmentsDuringSync.any(
              (item) => item['assignmentId'] == assignmentId,
            )) {
          _pendingAssignmentsDuringSync.add(decoded);
        }
      } else {
        unawaited(_handleAssignmentStart(decoded));
      }
    } else if (decoded['type'] == 'assignment.cancel') {
      unawaited(_handleAssignmentCancel(decoded));
    }
  }

  void _completeSynchronizationWhenReady() {
    if (!_syncResultReceived ||
        !_syncReconciliationComplete ||
        !_workerInventorySent ||
        sessionId == null) {
      return;
    }
    _syncTimer?.cancel();
    _syncTimer = null;
    connectionStage = WorkspaceConnectionStage.ready;
    activeTransportMode = _pendingTransportMode ?? activeTransportMode;
    _pendingTransportMode = null;
    fallbackHealthStatus = activeTransportMode == 'http_long_poll'
        ? 'healthy'
        : fallbackFactory == null
            ? 'not configured'
            : 'standby';
    if (activeTransportMode == 'websocket') _webSocketProbeFailures = 0;
    lastReadyAt = DateTime.now().toUtc();
    lastConnectionError = null;
    lastHttpStatusCode = null;
    final readyCallback = onSessionReady;
    final readySessionId = sessionId;
    if (readyCallback != null &&
        readySessionId != null &&
        readySessionId != _readyCallbackSessionId) {
      _readyCallbackSessionId = readySessionId;
      unawaited(readyCallback().catchError((_) {}));
    }
    if (_pendingAssignmentsDuringSync.isNotEmpty) {
      final pending = List<Map<String, dynamic>>.from(
        _pendingAssignmentsDuringSync,
      );
      _pendingAssignmentsDuringSync.clear();
      for (final message in pending) {
        unawaited(_handleAssignmentStart(message));
      }
    }
    _scheduleWebSocketProbe();
  }

  Future<void> _finishSyncReconciliation(Map<String, Object?> payload) async {
    try {
      await _reconcileSyncResponse(payload);
      _syncReconciliationComplete = true;
      _completeSynchronizationWhenReady();
    } on Object catch (error) {
      lastConnectionError =
          'Workspace sync reconciliation failed (${error.runtimeType}).';
      connectionStage = WorkspaceConnectionStage.reconnecting;
      _handleTransportEnd();
    }
  }

  void _scheduleWebSocketProbe() {
    _webSocketProbeTimer?.cancel();
    if (_closing ||
        fallbackFactory == null ||
        activeTransportMode != 'http_long_poll' ||
        connectionStage != WorkspaceConnectionStage.ready ||
        webSocketProbeInterval <= Duration.zero) {
      return;
    }
    _webSocketProbeTimer = Timer(nextWebSocketProbeDelay, () {
      unawaited(_probeWebSocket());
    });
  }

  Duration get nextWebSocketProbeDelay => Duration(
        microseconds: (webSocketProbeInterval.inMicroseconds *
                (1 << _webSocketProbeFailures.clamp(0, 8)))
            .clamp(0, webSocketProbeMaxInterval.inMicroseconds),
      );

  /// Wake/network recovery should not wait for a backed-off periodic retry.
  Future<void> retryWebSocketNow() async {
    if (_closing) return;
    _webSocketProbeFailures = 0;
    _webSocketProbeTimer?.cancel();
    await _probeWebSocket();
  }

  Future<void> _probeWebSocket() async {
    if (_closing ||
        _probingWebSocket ||
        activeTransportMode != 'http_long_poll' ||
        connectionStage != WorkspaceConnectionStage.ready) {
      return;
    }
    _probingWebSocket = true;
    _webSocketProbeTimer?.cancel();
    final generation = _transportGeneration;
    var expired = false;
    var handedOver = false;
    try {
      // Each factory call creates fresh WSS resources. Keep HTTPS alive until
      // Cloud accepts the upgrade; its single-session fence then requires handover.
      final pending = factory(uri);
      unawaited(pending.then<void>((candidate) async {
        if (expired || _closing || generation != _transportGeneration) {
          await candidate.close();
        }
      }, onError: (Object _) {}).catchError((Object _) {}));
      final candidate = await pending.timeout(protocolHandshakeTimeout);
      if (_closing || generation != _transportGeneration) return;
      connectionStage = WorkspaceConnectionStage.switchingToWebSocket;
      handedOver = true;
      await _open(preparedWebSocket: candidate);
    } on Object catch (error) {
      expired = true;
      if (!_closing && generation == _transportGeneration) {
        _recordWebSocketFailure(error);
        _webSocketProbeFailures++;
      } else if (!_closing && handedOver) {
        _preferFallbackTransport = true;
        unawaited(_reconnect());
      }
    } finally {
      _probingWebSocket = false;
      if (!_closing && connectionStage == WorkspaceConnectionStage.ready) {
        _scheduleWebSocketProbe();
      }
    }
  }

  String _describeConnectionError(Object error) {
    if (error is WebSocketException && error.httpStatusCode != null) {
      return 'Cloud rejected the WebSocket upgrade with HTTP '
          '${error.httpStatusCode}.';
    }
    if (error is WebSocketException) {
      return 'WebSocket upgrade failed.';
    }
    if (error is TimeoutException) {
      return 'Connection timed out (${error.message ?? 'timeout'}).';
    }
    if (error is SocketException) {
      return 'Socket connection failed (${error.message}).';
    }
    return 'WebSocket connection failed (${error.runtimeType}).';
  }

  void _recordWebSocketFailure(Object error) {
    lastWebSocketFailure = _describeConnectionError(error);
    lastWebSocketHttpStatusCode =
        error is WebSocketException ? error.httpStatusCode : null;
    lastWebSocketFailureAt = DateTime.now().toUtc();
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
      final socket = _transport;
      if (socket == null || sessionId == null) continue;
      if (record.status == AssignmentStatus.completed) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.result',
          correlation,
          {
            'status': 'completed',
            'summary':
                record.result?['summary'] ?? 'Recovered assignment result',
            'output': record.result?['output'],
            'artifactIds': record.result?['artifactIds'] ?? const [],
            if (record.result?['evidence'] is Map)
              'evidence': record.result?['evidence'],
          },
        )));
      } else if (record.status == AssignmentStatus.failed) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.error',
          correlation,
          {
            'status': 'failed',
            'error': {
              'code': 'workspace_assignment_recovered_failure',
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
        'workspaceRuntimeId': record.workspaceRuntimeId,
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
      {
        ..._envelope(type, payload),
        ...correlation,
      };

  Future<void> _sendSyncRequest() async {
    final socket = _transport;
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
    final request = _envelope('workspace.sync.request', {
      'workspaceRuntimeId': workspaceRuntimeId,
      'executionWorkspaceId': workspaceId,
      if (recoveredAssignmentIds.isNotEmpty)
        'unreconciledAssignmentIds': recoveredAssignmentIds.toList()..sort(),
    });
    _syncRequestMessageId = request['messageId'] as String;
    socket.send(jsonEncode(request));
  }

  Future<void> _reconnect() async {
    if (_closing || _reconnecting) return;
    _reconnecting = true;
    sessionId = null;
    connectionStage = WorkspaceConnectionStage.reconnecting;
    await _cleanCurrentTransport();
    try {
      while (!_closing) {
        reconnectCount += 1;
        final multiplier = 1 << _reconnectAttempt.clamp(0, 8);
        final delay = Duration(
          microseconds: (reconnectBaseDelay.inMicroseconds * multiplier)
              .clamp(0, reconnectMaxDelay.inMicroseconds),
        );
        final wakeup = Completer<void>();
        _reconnectWakeup = wakeup;
        await Future.any([Future<void>.delayed(delay), wakeup.future]);
        if (identical(_reconnectWakeup, wakeup)) _reconnectWakeup = null;
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

  void _handleTransportEnd() {
    if ((_pendingTransportMode ?? activeTransportMode) == 'websocket' &&
        fallbackFactory != null) {
      if (_pendingTransportMode == 'websocket') _webSocketProbeFailures++;
      _preferFallbackTransport = true;
      fallbackHealthStatus = 'connecting';
    } else if ((_pendingTransportMode ?? activeTransportMode) ==
            'http_long_poll' &&
        fallbackFactory != null) {
      fallbackHealthStatus = 'unavailable';
    }
    final wakeup = _reconnectWakeup;
    if (_reconnecting && wakeup != null && !wakeup.isCompleted) {
      wakeup.complete();
    } else {
      unawaited(_reconnect());
    }
  }

  bool _isTerminalWebSocketFailure(Object? error) {
    if (error is! WebSocketException) return false;
    // These responses indicate auth, ownership, or protocol remediation is
    // needed. Opening HTTP with the same runtime credential cannot fix them.
    return const {401, 403, 409, 426}.contains(error.httpStatusCode);
  }

  Future<void> close() async {
    _closing = true;
    final wakeup = _reconnectWakeup;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
    final cancelAssignment = assignmentCancellationHandler;
    if (cancelAssignment != null) {
      for (final assignmentId in _activeAssignments.toList(growable: false)) {
        try {
          await cancelAssignment(assignmentId, 'Workspace shutdown');
        } on Object {
          // Workspace shutdown must continue even if a cancellation callback
          // fails; the executor shutdown hook is the final cleanup boundary.
        }
      }
    }
    await _cleanCurrentTransport();
    lastHelloSentAt = null;
    connectionStage = WorkspaceConnectionStage.offline;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

abstract interface class AgentCloudSocket {
  Stream<Object?> get messages;
  void send(Object message);
  Future<void> close();
}

typedef AgentCloudSocketFactory = Future<AgentCloudSocket> Function(Uri uri);

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

Future<AgentCloudSocket> connectIoAgentCloudSocket(Uri uri) async {
  final socket = await WebSocket.connect(uri.toString());
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
  final Duration heartbeat;
  AgentCloudSocket? _socket;
  Timer? _heartbeatTimer;
  StreamSubscription<Object?>? _subscription;
  bool _closing = false;
  int reconnectCount = 0;
  String? sessionId;
  int _messageSequence = 0;
  Map<String, Object?>? syncResponse;

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
    final decoded = jsonDecode(raw);
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
    }
  }

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

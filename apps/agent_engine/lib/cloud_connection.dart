import 'dart:async';
import 'dart:convert';

abstract interface class AgentCloudSocket {
  Stream<Object?> get messages;
  void send(Object message);
  Future<void> close();
}

typedef AgentCloudSocketFactory = Future<AgentCloudSocket> Function(Uri uri);

class AgentCloudConnection {
  AgentCloudConnection({
    required this.uri,
    required this.agentId,
    required this.workspaceId,
    required this.factory,
    this.heartbeat = const Duration(seconds: 15),
  });

  final Uri uri;
  final String agentId;
  final String workspaceId;
  final AgentCloudSocketFactory factory;
  final Duration heartbeat;
  AgentCloudSocket? _socket;
  Timer? _heartbeatTimer;
  StreamSubscription<Object?>? _subscription;
  bool _closing = false;
  int reconnectCount = 0;

  Future<void> connect() async {
    _closing = false;
    await _open();
  }

  Future<void> _open() async {
    final socket = await factory(uri);
    _socket = socket;
    socket.send(jsonEncode({
      'type': 'agent.hello',
      'agentId': agentId,
      'workspaceId': workspaceId,
    }));
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      socket.send(jsonEncode({
        'type': 'agent.heartbeat',
        'agentId': agentId,
        'workspaceId': workspaceId,
      }));
    });
    await _subscription?.cancel();
    _subscription = socket.messages.listen(
      (_) {},
      onDone: () => unawaited(_reconnect()),
      onError: (_) => unawaited(_reconnect()),
    );
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

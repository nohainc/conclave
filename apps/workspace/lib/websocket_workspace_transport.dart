import 'dart:async';
import 'dart:io';

import 'workspace_transport.dart';

class WebSocketWorkspaceTransport implements WorkspaceTransport {
  WebSocketWorkspaceTransport(this.socket);
  final WebSocket socket;

  @override
  Stream<Object?> get messages => socket;

  @override
  void send(Object message) => socket.add(message);

  @override
  Future<void> sendAndWait(Object message) {
    socket.add(message);
    return Future<void>.value();
  }

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

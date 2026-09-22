import 'dart:io';
import 'package:conclave_host/cloud_connection.dart';
import 'package:test/test.dart';

void main() {
  test('adapts a real WebSocket server to the Cloud socket interface',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) => socket.add(message));
      }
    });
    final adapter = await connectIoHostCloudSocket(
      Uri.parse('ws://${server.address.address}:${server.port}'),
    );
    final received = expectLater(adapter.messages, emits('ping'));
    adapter.send('ping');
    await received;
    await adapter.close();
    await server.close(force: true);
  });
}

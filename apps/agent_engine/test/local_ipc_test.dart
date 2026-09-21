import 'dart:convert';
import 'dart:io';

import 'package:conclave_agent_engine/local_ipc.dart';
import 'package:test/test.dart';

void main() {
  test('authenticated local IPC delivers typed commands', () async {
    final server = LocalIpcServer(token: 'secret');
    await server.start();
    final received = expectLater(
      server.messages,
      emits(isA<IpcCommand>()),
    );
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port!);
    socket.writeln(jsonEncode({'token': 'secret'}));
    socket.writeln(
        jsonEncode(IpcCommand('engine.status', {'online': true}).toJson()));
    await received;
    await socket.close();
    await server.close();
  });

  test('rejects an invalid message shape', () {
    expect(() => parseLocalIpcMessage({'payload': {}}), throwsFormatException);
  });
}

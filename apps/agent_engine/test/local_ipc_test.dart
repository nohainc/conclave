import 'dart:async';
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

  test('responds to authenticated commands without losing frame boundaries',
      () async {
    final response = Completer<Map<String, dynamic>>();
    final server = LocalIpcServer(
      token: 'secret',
      onCommand: (command) async => {
        'echoType': command.type,
        'echoPayload': command.payload,
      },
    );
    await server.start();
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port!);
    socket
        .map((bytes) => bytes.toList())
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      if (decoded['type'] == 'engine.status') response.complete(decoded);
    });
    socket.write(jsonEncode({'token': 'secret'}));
    socket.write('\n');
    socket.write(jsonEncode(IpcCommand(
      'engine.status',
      {'request': 'status'},
      requestId: 'request-1',
    ).toJson()));
    socket.write('\n');

    final decoded = await response.future.timeout(const Duration(seconds: 2));
    expect(decoded['ok'], isTrue);
    expect(decoded['requestId'], 'request-1');
    expect(
      (decoded['payload'] as Map<String, dynamic>)['echoPayload'],
      {'request': 'status'},
    );
    await socket.close();
    await server.close();
  });

  test('client authenticates and receives a typed command response', () async {
    final server = LocalIpcServer(
      token: 'client-secret',
      onCommand: (command) async => {'status': command.type},
    );
    await server.start();
    final client = await LocalIpcClient.connect(
      port: server.port!,
      token: 'client-secret',
    );
    final result = await client.command('engine.status', const {});
    expect(result['status'], 'engine.status');
    await client.close();
    await server.close();
  });
}

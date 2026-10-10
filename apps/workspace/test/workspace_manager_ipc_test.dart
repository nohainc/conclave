import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/workspace_manager_ipc.dart';
import 'package:test/test.dart';

void main() {
  test('versioned IPC authenticates, responds and streams runtime events',
      () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('workspace-ipc-');
    addTearDown(() => root.delete(recursive: true));
    final source = StreamController<Map<String, Object?>>.broadcast();
    addTearDown(source.close);
    final server = WorkspaceManagerIpcServer(
      runtimeDirectory: root,
      serviceVersion: 'test-service',
      snapshotProvider: () async => {'processState': 'ready'},
      eventStream: source.stream,
      requestHandler: (command, payload) async {
        if (command == 'echo') return payload;
        throw const WorkspaceManagerProtocolException(
            'unsupported_command', 'Unsupported command.');
      },
    );
    try {
      await server.start();
    } on SocketException catch (error) {
      if (error.osError?.errorCode == 1) {
        markTestSkipped('Execution sandbox blocks local Unix sockets.');
        return;
      }
      rethrow;
    }
    addTearDown(server.close);

    final key =
        (await File('${root.path}/manager-ipc.key').readAsString()).trim();
    final client = await WorkspaceManagerIpcClient.connect(
      socketPath: server.socketPath,
      key: key,
    );
    addTearDown(client.close);
    expect(client.serviceVersion, 'test-service');
    expect(client.initialSnapshot['processState'], 'ready');
    expect(
      await client.request('echo', payload: {'value': 7}),
      {'value': 7},
    );

    await client.subscribe();
    final event = client.events.first;
    source.add({'name': 'cloud.connectionChanged', 'state': 'connected'});
    final receivedEvent = await event;
    expect(receivedEvent['type'], 'event');
    expect(receivedEvent['name'], 'cloud.connectionChanged');
  });

  test('IPC rejects clients that do not possess the local capability key',
      () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('workspace-ipc-auth-');
    addTearDown(() => root.delete(recursive: true));
    final server = WorkspaceManagerIpcServer(
      runtimeDirectory: root,
      serviceVersion: 'test-service',
      snapshotProvider: () async => const {},
      requestHandler: (_, __) async => null,
    );
    try {
      await server.start();
    } on SocketException catch (error) {
      if (error.osError?.errorCode == 1) {
        markTestSkipped('Execution sandbox blocks local Unix sockets.');
        return;
      }
      rethrow;
    }
    addTearDown(server.close);

    await expectLater(
      WorkspaceManagerIpcClient.connect(
        socketPath: server.socketPath,
        key: '0' * 64,
      ),
      throwsA(isA<WorkspaceManagerProtocolException>().having(
        (error) => error.code,
        'error code',
        'unauthorized',
      )),
    );
  });
}

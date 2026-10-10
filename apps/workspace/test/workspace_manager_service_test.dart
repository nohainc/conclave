import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_lifecycle.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:conclave_workspace/workspace_manager_ipc.dart';
import 'package:conclave_workspace/workspace_manager_service.dart';
import 'package:test/test.dart';

void main() {
  test(
      'prepareStop drains Cloud admission while process shutdown stays host-owned',
      () async {
    if (Platform.isWindows) return;
    final root = await Directory('/tmp').createTemp('ws-stop-');
    addTearDown(() => root.delete(recursive: true));
    var cloudAttempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('https://cloud.example.test'),
      workspaceRuntimeId: 'runtime-test',
      workspaceId: 'workspace-test',
      factory: (_) async {
        cloudAttempts++;
        throw StateError('This test must not open a Cloud connection');
      },
    );
    addTearDown(connection.close);
    final manager = WorkspaceManagerService(Workspace(
      config: WorkspaceConfig(dataDirectory: root),
      cloudConnection: connection,
    ));
    try {
      await manager.start();
    } on SocketException catch (error) {
      if (error.osError?.errorCode == 1) {
        markTestSkipped('Execution sandbox blocks local Unix sockets.');
        return;
      }
      rethrow;
    }
    addTearDown(manager.close);
    final key =
        (await File('${root.path}/runtime/manager-ipc.key').readAsString())
            .trim();
    final client = await WorkspaceManagerIpcClient.connect(
        socketPath: '${root.path}/runtime/manager.sock', key: key);
    addTearDown(client.close);
    await expectLater(
        client.request('configuration.update',
            payload: {'workRootPath': '${root.path}/work'}),
        throwsA(isA<WorkspaceManagerProtocolException>()
            .having((error) => error.code, 'code', 'service_running')));
    await client.request('service.prepareStop');
    expect(connection.acceptingNewWork, isFalse);
    expect(cloudAttempts, 0);
    // The IPC process remains available until the native host stops it.
    expect(await client.request('service.getStatus'), isA<Map>());
    await expectLater(client.request('service.shutdown'),
        throwsA(isA<WorkspaceManagerProtocolException>()));
  });
  test('configuration reload responds before a slow Cloud handshake', () async {
    if (Platform.isWindows) return;
    final root = await Directory('/tmp').createTemp('ws-reload-');
    addTearDown(() => root.delete(recursive: true));
    final cloudGate = Completer<void>();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.example.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-test'),
      workspaceRuntimeId: 'runtime-test',
      workspaceId: 'workspace-test',
      factory: (_) async {
        attempts++;
        await cloudGate.future;
        throw StateError('Offline fixture');
      },
    );
    final replacement = Workspace(
      config: WorkspaceConfig(
          dataDirectory: root, workRootPath: '${root.path}-work'),
      cloudConnection: connection,
    );
    // User work cannot be nested inside this isolated application-data root.
    addTearDown(() async {
      if (!cloudGate.isCompleted) cloudGate.complete();
      await replacement.stop();
      final work = Directory('${root.path}-work');
      if (await work.exists()) await work.delete(recursive: true);
    });
    final preferences = WorkspaceLifecyclePreferencesStore(root);
    await preferences.write(preferences
        .readSync()
        .copyWith(desiredRuntime: DesiredRuntimeState.connected));
    final manager = WorkspaceManagerService(
        Workspace(config: WorkspaceConfig(dataDirectory: root)),
        reloadRuntime: () async => replacement);
    await manager.start();
    addTearDown(manager.close);
    final key =
        (await File('${root.path}/runtime/manager-ipc.key').readAsString())
            .trim();
    final client = await WorkspaceManagerIpcClient.connect(
        socketPath: '${root.path}/runtime/manager.sock', key: key);
    addTearDown(client.close);
    await client.request('configuration.reload',
        timeout: const Duration(seconds: 2));
    expect(attempts, 1);
    expect(cloudGate.isCompleted, isFalse);
    expect(replacement.isRunning, isTrue);
    cloudGate.complete();
  });
}

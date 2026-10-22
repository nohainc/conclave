import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_workspace/windows_service_manager.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_lifecycle.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:conclave_workspace/workspace_manager_ipc.dart';

void main() {
  test(
      'Windows logon task registration, stop and unregister retain installation',
      () async {
    final path = Platform.environment['CONCLAVE_TEST_WINDOWS_SERVICE'];
    if (path == null) {
      markTestSkipped('Set CONCLAVE_TEST_WINDOWS_SERVICE');
      return;
    }
    final root = await Directory.systemTemp.createTemp('conclave-task-');
    final data = Directory('${root.path}/state');
    await WorkspaceLifecyclePreferencesStore(data)
        .write(WorkspaceLifecyclePreferences(
      launchAtLogin: true,
      preventSleep: false,
      managementLockPreference: ManagementLockState.unlocked,
      workRootPath: '${root.path}/work',
    ));
    final manager = WindowsWorkspaceServiceManager(
        dataDirectory: data, executable: File(path));
    WorkspaceManagerIpcClient? client;
    try {
      expect((await manager.register()).registered, true);
      final identity = InstallationIdentityStore(data).readSync();
      expect(identity, startsWith('install_'));
      await manager.start();
      var ready = false;
      final until = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(until)) {
        try {
          final runtime = Directory('${data.path}/runtime');
          final key =
              await File('${runtime.path}/manager-ipc.key').readAsString();
          client = await WorkspaceManagerIpcClient.connect(
              socketPath: workspaceManagerEndpoint(runtime), key: key);
          ready = true;
          break;
        } on Object {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      if (!ready) {
        final info = await manager.getInfo();
        if ({0x80041320, 0x80070520}.contains(info.lastExitCode)) {
          markTestSkipped(
              'Runner lacks an interactive logon token; registration succeeded, target-device start is still required');
        } else {
          fail(
              'Registered Windows task did not start IPC; Task Scheduler result ${info.lastExitCode}');
        }
      } else {
        expect((client!.initialSnapshot['service'] as Map)['processState'],
            'ready');
        await client.request('connection.disconnect');
        expect(await client.request('status'), isA<Map>());
      }
      await client?.close();
      client = null;
      expect((await manager.stop()).registered, true);
      expect((await manager.unregister()).registered, false);
      expect(InstallationIdentityStore(data).readSync(), identity);
    } finally {
      await client?.close();
      await manager.unregister();
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(seconds: 150)));
}

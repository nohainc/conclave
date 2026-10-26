import 'dart:io';
import 'dart:convert';
import 'package:conclave_workspace/windows_native.dart';

import 'package:test/test.dart';
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
      final definition = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''
$ErrorActionPreference = 'Stop'
$x = [xml](Export-ScheduledTask -TaskName ('Conclave Workspace ' + $env:CONCLAVE_TEST_INSTALLATION))
$id = [string]$x.Task.Principals.Principal.UserId
if (-not $id.StartsWith('S-')) { $id = ([System.Security.Principal.NTAccount]::new($id)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
# Task Scheduler may omit the schema-default LeastPrivilege value.
$level = [string]$x.Task.Principals.Principal.RunLevel
if (-not $level) { $level = 'LeastPrivilege' }
@{ sid = $id; logonType = [string]$x.Task.Principals.Principal.LogonType; runLevel = $level } | ConvertTo-Json -Compress
'''
      ], environment: {
        'CONCLAVE_TEST_INSTALLATION': identity!
      });
      expect(definition.exitCode, 0, reason: definition.stderr.toString());
      expect(jsonDecode(definition.stdout.toString()), {
        'sid': WindowsNative.currentSid,
        'logonType': 'InteractiveToken',
        'runLevel': 'LeastPrivilege',
      });
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
        expect(await client.request('service.getHealth'),
            containsPair('healthy', true));
      }
      await client?.close();
      client = null;
      final stopped = await manager.stop();
      expect(stopped.registered, true);
      expect(stopped.processRunning, false);
      expect(stopped.lastExitCode, 0);
      expect((await manager.unregister()).registered, false);
      expect(InstallationIdentityStore(data).readSync(), identity);
    } finally {
      await client?.close();
      await manager.unregister();
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(seconds: 150)));
}

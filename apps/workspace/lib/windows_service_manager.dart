import 'dart:convert';
import 'dart:io';

import 'workspace_background_service.dart';
import 'workspace_configuration.dart';
import 'windows_native.dart';

/// Per-user interactive logon task. Task Scheduler supervises the standalone
/// service; this adapter never starts an Engine or contacts Cloud.
class WindowsWorkspaceServiceManager implements WorkspaceServiceManager {
  WindowsWorkspaceServiceManager({Directory? dataDirectory, File? executable})
      : dataDirectory = dataDirectory ??
            WorkspaceConfigurationResolver.resolveDataDirectory(const []),
        executable = executable ??
            File(
                '${File(Platform.resolvedExecutable).parent.path}/conclave-service.exe');
  final Directory dataDirectory;
  final File executable;
  Future<String> _identity() async {
    await dataDirectory.create(recursive: true);
    WindowsNative.securePath(dataDirectory.path);
    final id = await InstallationIdentityStore(dataDirectory).getOrCreate();
    if (!RegExp(r'^[A-Za-z0-9-]{8,128}$').hasMatch(id)) {
      throw StateError('Invalid installation identity');
    }
    return id;
  }

  Future<Map<String, Object?>> _run(String operation) async {
    final id = await _identity();
    final script = r'''
$ErrorActionPreference = 'Stop'
$name = 'Conclave Workspace ' + $env:CONCLAVE_HOST_ID
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
switch ($env:CONCLAVE_HOST_OPERATION) {
  'register' {
    if ($task -and $task.Actions.Execute -ne $env:CONCLAVE_HOST_EXECUTABLE) { throw 'Existing task points to a different service; preserve state and unregister it explicitly first.' }
    $arguments = '--data-dir "' + $env:CONCLAVE_HOST_DATA + '"'
    $action = New-ScheduledTaskAction -Execute $env:CONCLAVE_HOST_EXECUTABLE -Argument $arguments -WorkingDirectory (Split-Path $env:CONCLAVE_HOST_EXECUTABLE)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  }
  'start' {
    if (-not $task) { throw 'Workspace service is not registered.' }
    if ($task.Actions.Execute -ne $env:CONCLAVE_HOST_EXECUTABLE) { throw 'Registered service path differs from this application.' }
    Start-ScheduledTask -TaskName $name
  }
  'force-stop' { if ($task) { Stop-ScheduledTask -TaskName $name } }
  'unregister' { if ($task) { Unregister-ScheduledTask -TaskName $name -Confirm:$false } }
}
$task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
$info = if ($task) { Get-ScheduledTaskInfo -TaskName $name } else { $null }
@{ registered = [bool]$task; running = [bool]($task -and $task.State -eq 'Running'); lastExitCode = if ($info) { $info.LastTaskResult } else { 0 } } | ConvertTo-Json -Compress
''';
    final bytes = <int>[];
    for (final code in script.codeUnits) {
      bytes.add(code & 255);
      bytes.add(code >> 8);
    }
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64Encode(bytes)
    ], environment: {
      'CONCLAVE_HOST_ID': id,
      'CONCLAVE_HOST_OPERATION': operation,
      'CONCLAVE_HOST_EXECUTABLE': executable.absolute.path,
      'CONCLAVE_HOST_DATA': dataDirectory.absolute.path,
    }).timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) {
      throw StateError('Windows service $operation failed: ${result.stderr}');
    }
    return Map<String, Object?>.from(
        jsonDecode(result.stdout.toString()) as Map);
  }

  @override
  Future<WorkspaceServiceInfo> getInfo() async {
    final result = await _run('status');
    return WorkspaceServiceInfo(
      supported: true,
      helperPresent: executable.existsSync(),
      plistPresent: true,
      enginePresent: File(
              '${executable.parent.path}/assets/engines/conclave_cli_worker_engine.exe')
          .existsSync(),
      registration: result['registered'] == true
          ? ServiceInstallationState.registered
          : ServiceInstallationState.notRegistered,
      process: result['running'] == true
          ? ServiceRuntimeState.running
          : ServiceRuntimeState.stopped,
      launchdState: result['running'] == true ? 'running' : 'stopped',
      lastExitCode: result['lastExitCode'] as int?,
    );
  }

  @override
  Future<WorkspaceServiceInfo> status() => getInfo();
  @override
  Future<WorkspaceServiceInfo> register() async {
    if (!executable.existsSync()) {
      throw StateError('Bundled Workspace service is missing');
    }
    await _run('register');
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> start() async {
    final stop = File('${dataDirectory.path}/runtime/stop-request');
    if (stop.existsSync()) stop.deleteSync();
    await _run('start');
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> stop() async {
    final stop = File('${dataDirectory.path}/runtime/stop-request');
    await stop.parent.create(recursive: true);
    WindowsNative.securePath(stop.parent.path);
    await stop.writeAsString('stop', flush: true);
    for (var attempt = 0; attempt < 40; attempt++) {
      final info = await getInfo();
      if (!info.processRunning) return info;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _run('force-stop');
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> restart() async {
    await stop();
    return start();
  }

  @override
  Future<WorkspaceServiceInfo> unregister() async {
    await stop();
    await _run('unregister');
    return getInfo();
  }

  @override
  Future<void> openSettings() async {
    await Process.start('mmc.exe', ['taskschd.msc']);
  }
}

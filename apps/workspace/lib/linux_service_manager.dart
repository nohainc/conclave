import 'dart:io';

import 'workspace_background_service.dart';
import 'workspace_configuration.dart';

typedef SystemctlRunner = Future<ProcessResult> Function(List<String> args);

/// systemd user unit for the standalone service (ADR-021 §2.1). systemd
/// supervises the service; this adapter never starts an Engine or contacts
/// Cloud. `Stop` keeps the unit enabled; only `unregister` removes it.
class LinuxWorkspaceServiceManager implements WorkspaceServiceManager {
  LinuxWorkspaceServiceManager({
    Directory? dataDirectory,
    File? executable,
    Directory? unitDirectory,
    SystemctlRunner? systemctl,
  })  : dataDirectory = dataDirectory ??
            WorkspaceConfigurationResolver.resolveDataDirectory(const []),
        executable = executable ?? File(Platform.resolvedExecutable),
        unitDirectory = unitDirectory ?? defaultUnitDirectory(),
        _systemctl = systemctl ?? _runSystemctl;

  final Directory dataDirectory;
  final File executable;
  final Directory unitDirectory;
  final SystemctlRunner _systemctl;

  static Directory defaultUnitDirectory() {
    final config = Platform.environment['XDG_CONFIG_HOME'];
    final base = config != null && config.startsWith('/')
        ? config
        : '${Platform.environment['HOME']}/.config';
    return Directory('$base/systemd/user');
  }

  static Future<ProcessResult> _runSystemctl(List<String> args) => Process.run(
        'systemctl',
        ['--user', ...args],
      ).timeout(const Duration(seconds: 30));

  Future<String> _unitName() async {
    await dataDirectory.create(recursive: true);
    final id = await InstallationIdentityStore(dataDirectory).getOrCreate();
    if (!RegExp(r'^[A-Za-z0-9._-]{8,128}$').hasMatch(id)) {
      throw StateError('Invalid installation identity');
    }
    return 'workspace-$id.service';
  }

  /// Quotes one ExecStart word. systemd expands `%` specifiers and `$`
  /// variables even inside quotes, so both are escaped.
  static String quoteExecArgument(String value) {
    if (value.contains('\n') ||
        value.contains('\r') ||
        value.contains('\u0000')) {
      throw ArgumentError.value(value, 'value', 'contains a control character');
    }
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('%', '%%')
        .replaceAll(r'$', r'$$');
    return '"$escaped"';
  }

  String execStart() => [
        executable.absolute.path,
        'run',
        '--data-dir',
        dataDirectory.absolute.path,
      ].map(quoteExecArgument).join(' ');

  // Path directives are not ExecStart argument lists: quotes become literal
  // path characters. Escape unit-file specifiers and backslashes instead.
  String workingDirectory() {
    final path = executable.parent.absolute.path;
    if (path.contains(RegExp(r'[\r\n\x00]'))) {
      throw ArgumentError('Working directory contains a control character');
    }
    return path.replaceAll(r'\', r'\\').replaceAll('%', '%%');
  }

  String unitContents() => '''
[Unit]
Description=Syntila Workspace Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${execStart()}
WorkingDirectory=${workingDirectory()}
Restart=on-failure
RestartSec=5
# SIGTERM lets the service stop its Engine and provider CLIs; anything left in
# the unit's cgroup afterwards is killed when the stop timeout expires.
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=default.target
''';

  File _unitFile(String name) => File('${unitDirectory.path}/$name');

  Future<void> _check(List<String> args) async {
    final result = await _systemctl(args);
    if (result.exitCode != 0) {
      throw StateError(
        'systemctl --user ${args.join(' ')} failed: ${result.stderr}'.trim(),
      );
    }
  }

  Future<void> _requireOwnedUnit(File unit) async {
    if (!await unit.exists()) {
      throw StateError('Workspace service is not registered.');
    }
    final expected = 'ExecStart=${execStart()}';
    final lines = await unit.readAsLines();
    if (!lines.contains(expected)) {
      throw StateError(
        'Registered service ${unit.path} points to a different service; '
        'preserve state and unregister it explicitly first.',
      );
    }
  }

  @override
  Future<WorkspaceServiceInfo> getInfo() async {
    final name = await _unitName();
    final unit = _unitFile(name);
    final result = await _systemctl([
      'show',
      name,
      '--property=ActiveState,SubState,MainPID,ExecMainStatus,UnitFileState',
    ]);
    final values = <String, String>{};
    if (result.exitCode == 0) {
      for (final line in result.stdout.toString().split('\n')) {
        final split = line.indexOf('=');
        if (split > 0) {
          values[line.substring(0, split)] = line.substring(split + 1).trim();
        }
      }
    }
    final active = values['ActiveState'];
    final running =
        active == 'active' || active == 'activating' || active == 'reloading';
    final pid = int.tryParse(values['MainPID'] ?? '');
    return WorkspaceServiceInfo(
      supported: result.exitCode == 0,
      helperPresent: executable.existsSync(),
      plistPresent: unit.existsSync(),
      enginePresent: File(
            '${executable.parent.path}/assets/engines/syntila-agent',
          ).existsSync() ||
          File(
            '${executable.parent.path}/assets/engines/syntila_cli_worker_engine',
          ).existsSync(),
      registration: unit.existsSync() && values['UnitFileState'] == 'enabled'
          ? ServiceInstallationState.registered
          : ServiceInstallationState.notRegistered,
      process:
          running ? ServiceRuntimeState.running : ServiceRuntimeState.stopped,
      pid: pid == null || pid == 0 ? null : pid,
      launchdState: values['SubState'] ?? active ?? 'unknown',
      lastExitCode: int.tryParse(values['ExecMainStatus'] ?? ''),
      lastExitReason: result.exitCode == 0
          ? null
          : 'systemd user manager unavailable: ${result.stderr}'.trim(),
    );
  }

  @override
  Future<WorkspaceServiceInfo> status() => getInfo();

  @override
  Future<WorkspaceServiceInfo> register() async {
    if (!executable.existsSync()) {
      throw StateError('Bundled Workspace service is missing');
    }
    final name = await _unitName();
    final unit = _unitFile(name);
    if (await unit.exists()) {
      await _requireOwnedUnit(unit);
    }
    await unitDirectory.create(recursive: true);
    final temporary = File('${unit.path}.$pid.tmp');
    await temporary.writeAsString(unitContents(), flush: true);
    await temporary.rename(unit.path);
    await _check(['daemon-reload']);
    await _check(['enable', name]);
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> start() async {
    final name = await _unitName();
    await _requireOwnedUnit(_unitFile(name));
    await _check(['start', name]);
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> stop() async {
    final name = await _unitName();
    if (await _unitFile(name).exists()) await _check(['stop', name]);
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> restart() async {
    final name = await _unitName();
    await _requireOwnedUnit(_unitFile(name));
    await _check(['restart', name]);
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> unregister() async {
    final name = await _unitName();
    final unit = _unitFile(name);
    if (await unit.exists()) {
      await _check(['stop', name]);
      await _check(['disable', name]);
      await unit.delete();
      await _check(['daemon-reload']);
    }
    return getInfo();
  }

  /// There is no system settings pane for user units; show the unit file.
  @override
  Future<void> openSettings() async {
    await Process.start('xdg-open', [unitDirectory.path]);
  }
}

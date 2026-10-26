import 'dart:io';

import 'workspace_background_service.dart';
import 'workspace_configuration.dart';

typedef LaunchctlRunner = Future<ProcessResult> Function(List<String> args);

/// Pure-Dart macOS LaunchAgent manager for `conclave-workspace run`.
///
/// Installs and supervises the user agent directly in `~/Library/LaunchAgents`,
/// avoiding any Flutter UI or `SMAppService` framework dependency.
class MacOsWorkspaceServiceManager implements WorkspaceServiceManager {
  MacOsWorkspaceServiceManager({
    Directory? dataDirectory,
    File? executable,
    Directory? launchAgentsDirectory,
    LaunchctlRunner? launchctl,
  })  : dataDirectory = dataDirectory ??
            WorkspaceConfigurationResolver.resolveDataDirectory(const []),
        executable = executable ?? File(Platform.resolvedExecutable),
        launchAgentsDirectory =
            launchAgentsDirectory ?? defaultLaunchAgentsDirectory(),
        _launchctl = launchctl ?? _runLaunchctl;

  final Directory dataDirectory;
  final File executable;
  final Directory launchAgentsDirectory;
  final LaunchctlRunner _launchctl;

  static Directory defaultLaunchAgentsDirectory() {
    final home = Platform.environment['HOME'] ?? '';
    return Directory('$home/Library/LaunchAgents');
  }

  static Future<ProcessResult> _runLaunchctl(List<String> args) =>
      Process.run('launchctl', args).timeout(const Duration(seconds: 30));

  Future<String> _serviceLabel() async {
    await dataDirectory.create(recursive: true);
    final id = await InstallationIdentityStore(dataDirectory).getOrCreate();
    if (!RegExp(r'^[A-Za-z0-9._-]{8,128}$').hasMatch(id)) {
      throw StateError('Invalid installation identity');
    }
    return 'com.conclaveax.workspace.$id';
  }

  File _plistFile(String label) =>
      File('${launchAgentsDirectory.path}/$label.plist');

  String plistContents(String label) {
    final binaryPath = executable.absolute.path;
    final logDir = '${dataDirectory.absolute.path}/logs';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>$label</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>$binaryPath</string>
\t\t<string>run</string>
\t\t<string>--data-dir</string>
\t\t<string>${dataDirectory.absolute.path}</string>
\t</array>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>KeepAlive</key>
\t<dict>
\t\t<key>Crashed</key>
\t\t<true/>
\t</dict>
\t<key>StandardOutPath</key>
\t<string>$logDir/service.log</string>
\t<key>StandardErrorPath</key>
\t<string>$logDir/service.err.log</string>
\t<key>ProcessType</key>
\t<string>Background</string>
\t<key>EnvironmentVariables</key>
\t<dict>
\t\t<key>PATH</key>
\t\t<string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
\t</dict>
</dict>
</plist>
''';
  }

  @override
  Future<WorkspaceServiceInfo> register() async {
    final label = await _serviceLabel();
    await launchAgentsDirectory.create(recursive: true);
    final plist = _plistFile(label);
    await File('${dataDirectory.path}/logs').create(recursive: true);
    await plist.writeAsString(plistContents(label), flush: true);
    await _launchctl(['load', '-w', plist.path]);
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> unregister() async {
    final label = await _serviceLabel();
    final plist = _plistFile(label);
    if (plist.existsSync()) {
      try {
        await _launchctl(['unload', '-w', plist.path]);
      } catch (_) {}
      await plist.delete();
    }
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> start() async {
    final label = await _serviceLabel();
    final plist = _plistFile(label);
    if (!plist.existsSync()) {
      await register();
    }
    await _launchctl(['start', label]);
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> stop() async {
    final label = await _serviceLabel();
    try {
      await _launchctl(['stop', label]);
    } catch (_) {}
    return getInfo();
  }

  @override
  Future<WorkspaceServiceInfo> restart() async {
    await stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return start();
  }

  @override
  Future<WorkspaceServiceInfo> status() => getInfo();

  @override
  Future<WorkspaceServiceInfo> getInfo() async {
    final label = await _serviceLabel();
    final plist = _plistFile(label);
    final engine = File(
      '${executable.parent.path}/assets/engines/conclave-agent',
    );
    final fallbackEngine = File(
      '${executable.parent.path}/conclave-agent',
    );
    final enginePresent = engine.existsSync() || fallbackEngine.existsSync();

    if (!plist.existsSync()) {
      return WorkspaceServiceInfo(
        registration: ServiceInstallationState.notRegistered,
        supported: true,
        helperPresent: executable.existsSync(),
        plistPresent: false,
        enginePresent: enginePresent,
        process: ServiceRuntimeState.stopped,
      );
    }

    final uid = Platform.environment['UID'] ?? '501';
    final target = 'gui/$uid/$label';
    final result = await _launchctl(['print', target]);
    final out = '${result.stdout}\n${result.stderr}';
    final running = out.contains('state = running');
    int? pid;
    final pidMatch = RegExp(r'pid = (\d+)').firstMatch(out);
    if (pidMatch != null) {
      pid = int.tryParse(pidMatch.group(1)!);
    }

    return WorkspaceServiceInfo(
      registration: ServiceInstallationState.registered,
      supported: true,
      helperPresent: executable.existsSync(),
      plistPresent: true,
      enginePresent: enginePresent,
      process: running ? ServiceRuntimeState.running : ServiceRuntimeState.stopped,
      pid: pid,
      launchdState: running ? 'running' : 'stopped',
    );
  }

  @override
  Future<void> openSettings() async {}
}

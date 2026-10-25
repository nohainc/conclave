import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'workspace_registration_models.dart' show conclaveWorkspaceIsLocalBuild;

typedef DesktopProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

typedef DesktopShellLogger = void Function(String message);

/// Desktop integration used by the Workspace management UI: opening paths and
/// URLs and choosing directories.
///
/// The native method channel is preferred. When it is unavailable or fails,
/// the shell falls back to the platform's standard tools. Every failure is
/// reported to [log] instead of being silently discarded.
class DesktopShell {
  DesktopShell({
    MethodChannel channel = defaultChannel,
    DesktopProcessRunner? runProcess,
    String? operatingSystem,
    DesktopShellLogger? log,
  })  : _channel = channel,
        _runProcess = runProcess ?? Process.run,
        _os = operatingSystem ?? Platform.operatingSystem,
        _log = log ?? debugPrint;

  static const defaultChannel = MethodChannel('com.conclave.workspace/desktop');

  static const productionAXUrl = 'https://app.conclaveax.com';
  static const localAXUrl = 'http://localhost:3000';

  static const _workRootPrompt = 'Select Work Root Directory';

  final MethodChannel _channel;
  final DesktopProcessRunner _runProcess;
  final String _os;
  final DesktopShellLogger _log;

  Future<void> openPath(String path) async {
    try {
      await _channel.invokeMethod<void>('openPath', path);
      return;
    } catch (error) {
      _log('Native openPath failed, using platform fallback: $error');
    }
    await _openWithPlatform(path);
  }

  Future<void> openAX([String? url]) async {
    // The native handler always opens the production web app, so local builds
    // open the local web app directly.
    if (!conclaveWorkspaceIsLocalBuild && url == null) {
      try {
        await _channel.invokeMethod<void>('openAX');
        return;
      } catch (error) {
        _log('Native openAX failed, using platform fallback: $error');
      }
    }
    await _openWithPlatform(
      url ?? (conclaveWorkspaceIsLocalBuild ? localAXUrl : productionAXUrl),
    );
  }

  Future<String?> chooseDirectory({String? initialPath, String? prompt}) async {
    final native = await _invokePathMethod('chooseDirectory', initialPath);
    if (native != null) return native;
    final command = directoryPickerCommand(_os,
        initialPath: initialPath, prompt: prompt ?? _workRootPrompt);
    if (command == null) return null;
    try {
      final result = await _runProcess(command.$1, command.$2);
      if (result.exitCode == 0) return _nonEmpty(result.stdout);
      // A non-zero exit is the normal outcome when the user cancels.
      return null;
    } catch (error) {
      _log('Directory picker ${command.$1} failed: $error');
      return null;
    }
  }

  Future<String?> requestWorkRootAccess({String? initialPath}) async {
    final native =
        await _invokePathMethod('requestWorkRootAccess', initialPath);
    return native ?? chooseDirectory(initialPath: initialPath);
  }

  Future<void> publishStatus(Map<String, Object?> status) async {
    try {
      await _channel.invokeMethod<void>('status', status);
    } catch (error) {
      _log('Could not publish menu status: $error');
    }
  }

  Future<String?> _invokePathMethod(String method, String? initialPath) async {
    try {
      return _nonEmpty(
          await _channel.invokeMethod<String>(method, initialPath));
    } catch (error) {
      _log('Native $method failed, using platform fallback: $error');
      return null;
    }
  }

  Future<void> _openWithPlatform(String target) async {
    final executable = switch (_os) {
      'macos' => 'open',
      'linux' => 'xdg-open',
      'windows' => 'explorer',
      _ => null,
    };
    if (executable == null) {
      _log('Cannot open $target on unsupported platform $_os');
      return;
    }
    try {
      await _runProcess(executable, [target]);
    } catch (error) {
      _log('Could not open $target with $executable: $error');
    }
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// The fallback directory picker command for [os], or null when the
  /// platform has none.
  @visibleForTesting
  static (String, List<String>)? directoryPickerCommand(
    String os, {
    String? initialPath,
    String prompt = _workRootPrompt,
  }) {
    switch (os) {
      case 'macos':
        final hasInitial =
            initialPath != null && Directory(initialPath).existsSync();
        final location = hasInitial
            ? ' default location POSIX file "${appleScriptEscape(initialPath)}"'
            : '';
        return (
          'osascript',
          [
            '-e',
            'POSIX path of (choose folder with prompt "${appleScriptEscape(prompt)}"'
                '$location)',
          ],
        );
      case 'linux':
        return (
          'zenity',
          ['--file-selection', '--directory', '--title=$prompt'],
        );
      case 'windows':
        return (
          'powershell',
          [
            '-NoProfile',
            '-Command',
            '''
Add-Type -AssemblyName System.Windows.Forms
\$f = New-Object System.Windows.Forms.FolderBrowserDialog
\$f.Description = "${prompt.replaceAll('"', "'")}"
if (\$f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { \$f.SelectedPath }
''',
          ],
        );
      default:
        return null;
    }
  }

  /// Escapes [value] for use inside an AppleScript string literal.
  @visibleForTesting
  static String appleScriptEscape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

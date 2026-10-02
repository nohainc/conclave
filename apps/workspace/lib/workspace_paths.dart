import 'dart:io';

import 'platform_runtime.dart';

/// Owns the on-disk layout for the Workspace desktop runtime.
///
/// On macOS, user-managed state, work, and updates live under the
/// Workspace Application Support directory, while logs use the standard
/// per-user Logs directory. Explicit --data-dir deployments remain colocated.
class WorkspacePaths {
  WorkspacePaths(this.stateDirectory, {PlatformRuntime? platform})
      : platform = platform ?? currentPlatformRuntime;

  final Directory stateDirectory;
  final PlatformRuntime platform;

  static String _join(List<String> parts) => parts.join(Platform.pathSeparator);

  static Directory defaultStateDirectory({PlatformRuntime? platform}) {
    final runtime = platform ?? currentPlatformRuntime;
    if (runtime.operatingSystem == 'macos') {
      return Directory(_join([
        runtime.homeDirectory,
        'Library',
        'Application Support',
        'Conclave',
        'Workspace',
        'State',
      ]));
    }
    return Directory(
        '${runtime.homeDirectory}${Platform.pathSeparator}.conclave-workspace');
  }

  bool get _usesManagedMacLayout {
    if (platform.operatingSystem != 'macos') return false;
    return _canonical(stateDirectory.path) ==
        _canonical(defaultStateDirectory(platform: platform).path);
  }

  Directory get applicationSupportDirectory =>
      _usesManagedMacLayout ? stateDirectory.parent : stateDirectory;

  /// Private state owned by each configured logical Worker.
  Directory get workersDirectory =>
      Directory('${applicationSupportDirectory.path}/Workers');

  /// Immutable signed Tool Profile material managed independently of Engines.
  Directory get profilesDirectory =>
      Directory('${applicationSupportDirectory.path}/Profiles');

  /// Materialized app-bundled generic Engine executables.
  Directory get enginesDirectory =>
      Directory('${applicationSupportDirectory.path}/Engines');

  Directory workerStateDirectory(String workerId) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(workerId) ||
        workerId == '.' ||
        workerId == '..') {
      throw ArgumentError.value(workerId, 'workerId', 'invalid Worker ID');
    }
    return Directory(
      '${workersDirectory.path}${Platform.pathSeparator}$workerId'
      '${Platform.pathSeparator}state',
    );
  }

  Directory get updatesDirectory => _usesManagedMacLayout
      ? Directory('${applicationSupportDirectory.path}/Updates')
      : Directory('${stateDirectory.path}/updates');

  Directory get logsDirectory {
    if (!_usesManagedMacLayout) {
      return Directory('${stateDirectory.path}/logs');
    }
    return Directory(_join([
      platform.homeDirectory,
      'Library',
      'Logs',
      'Conclave Workspace',
    ]));
  }

  File get logsFile => File('${logsDirectory.path}/workspace.log');

  Future<void> prepareRuntimeDirectories() async {
    if (_usesManagedMacLayout) {
      await applicationSupportDirectory.create(recursive: true);
      await platform.restrictPermissions(
        applicationSupportDirectory.path,
        directory: true,
      );
    }
    for (final directory in [
      stateDirectory,
      workersDirectory,
      profilesDirectory,
      enginesDirectory,
      updatesDirectory,
      logsDirectory,
    ]) {
      await directory.create(recursive: true);
      await platform.restrictPermissions(directory.path, directory: true);
      final probe = File(
        '${directory.path}${Platform.pathSeparator}.write-check-$pid-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
      } on FileSystemException catch (error) {
        throw StateError(
          'Workspace cannot write to ${directory.path}: ${error.message}',
        );
      }
    }
  }

  static String _canonical(String path) => path.replaceAll(RegExp(r'/+$'), '');

  /// Preserves the existing Work Root when the macOS state layout changes.
  static Future<void> preserveMacWorkRoot({
    PlatformRuntime? platform,
  }) async {
    final runtime = platform ?? currentPlatformRuntime;
    if (runtime.operatingSystem != 'macos') return;
    final target = defaultStateDirectory(platform: runtime);
    final oldWork = Directory(_join([
      runtime.homeDirectory,
      'Library',
      'Application Support',
      'Conclave',
      'Work',
    ]));
    final newWork = Directory('${target.parent.path}/Work');
    if (await oldWork.exists() && !await newWork.exists()) {
      await newWork.parent.create(recursive: true);
      await oldWork.rename(newWork.path);
    }
  }
}

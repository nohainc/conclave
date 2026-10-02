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
        '${runtime.homeDirectory}${Platform.pathSeparator}.conclave-host');
  }

  static Directory legacyMacStateDirectory({PlatformRuntime? platform}) {
    final runtime = platform ?? currentPlatformRuntime;
    return Directory(
        '${runtime.homeDirectory}${Platform.pathSeparator}.conclave-host');
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

  File get logsFile => File('${logsDirectory.path}/host.log');

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

  /// Moves legacy macOS state into the standard Workspace layout before the
  /// UI reads registration or starts the runtime. The old directory is kept
  /// when a merge is required; migration never deletes a source file.
  static Future<void> migrateLegacyMacLayout({
    PlatformRuntime? platform,
    bool migrateState = true,
  }) async {
    final runtime = platform ?? currentPlatformRuntime;
    if (runtime.operatingSystem != 'macos') return;
    final source = legacyMacStateDirectory(platform: runtime);
    final target = defaultStateDirectory(platform: runtime);
    final marker = File('${target.path}/.legacy-layout-migrated-v1');
    if (migrateState && await source.exists() && !await marker.exists()) {
      final lockFile = File('${source.path}/host.lock');
      RandomAccessFile? migrationLock;
      if (await lockFile.exists()) {
        migrationLock = await lockFile.open(mode: FileMode.append);
        try {
          await migrationLock.lock(FileLock.exclusive);
        } on FileSystemException {
          await migrationLock.close();
          throw StateError(
            'Close the running Conclave Workspace before upgrading its local '
            'storage layout, then reopen it.',
          );
        }
      }
      try {
        await target.create(recursive: true);
        await _mergeMissingFiles(source, target, skip: const {
          'host.lock',
          'logs',
          'Adapters',
          'Workers',
          'Work',
          'configured-workers.json',
          'v7-adapters',
          'updates',
        });

        final paths = WorkspacePaths(target, platform: runtime);
        await _moveOrMergeDirectory(
          Directory('${source.path}/updates'),
          paths.updatesDirectory,
        );
        await _moveOrMergeDirectory(
          Directory('${source.path}/logs'),
          paths.logsDirectory,
        );

        await marker.writeAsString('completed', flush: true);
        await runtime.restrictPermissions(target.path, directory: true);
        await runtime.restrictPermissions(marker.path, directory: false);
      } finally {
        if (migrationLock != null) {
          await migrationLock.unlock();
          await migrationLock.close();
        }
      }
    }

    // Rename the old default Work Root only when the new location is empty.
    // If both exist, retain both so user files are never overwritten.
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

  static Future<void> _moveOrMergeDirectory(
    Directory source,
    Directory destination,
  ) async {
    if (!await source.exists()) return;
    if (!await destination.exists()) {
      await destination.parent.create(recursive: true);
      await source.rename(destination.path);
      return;
    }
    await _mergeMissingFiles(source, destination);
  }

  static Future<void> _mergeMissingFiles(
    Directory source,
    Directory destination, {
    Set<String> skip = const {},
  }) async {
    if (!await source.exists()) return;
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : Uri.decodeComponent(entity.uri.pathSegments.last);
      if (skip.contains(name) || name.isEmpty) continue;
      final targetPath = '${destination.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _mergeMissingFiles(Directory(entity.path), Directory(targetPath));
      } else if (entity is File && !await File(targetPath).exists()) {
        await entity.copy(targetPath);
      }
    }
  }
}

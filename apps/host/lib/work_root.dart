import 'dart:io';

import 'platform_runtime.dart';

/// Resolves and prepares the stable local Work Root for one Workspace
/// runtime. The root is deliberately independent of Workspace enrollment IDs.
class WorkRootResolver {
  WorkRootResolver({
    PlatformRuntime? platform,
    this.overridePath,
  }) : platform = platform ?? currentPlatformRuntime;

  final PlatformRuntime platform;
  final String? overridePath;

  String get defaultPath {
    final separator = platform.isWindows ? r'\' : '/';
    if (platform.isWindows) {
      return _join(
          platform.homeDirectory, 'AppData', 'Local', 'Conclave', 'Work',
          separator: separator);
    }
    if (platform.operatingSystem == 'macos') {
      return _join(platform.homeDirectory, 'Library', 'Application Support',
          'Conclave', 'Work',
          separator: separator);
    }
    return _join(platform.homeDirectory, '.local', 'share', 'conclave', 'work',
        separator: separator);
  }

  String get configuredPath => overridePath ?? defaultPath;

  /// Creates, canonicalizes, and permission-hardens the Work Root.
  Future<Directory> resolve({bool hasActiveWork = false}) async {
    final path = configuredPath.trim();
    if (path.isEmpty) {
      throw const WorkRootViolation('Work Root path must not be empty');
    }
    if (overridePath != null && hasActiveWork) {
      throw const WorkRootViolation(
          'Work Root cannot change while active Workstream work exists');
    }

    final requested = Directory(path);
    try {
      await requested.create(recursive: true);
    } on FileSystemException catch (error) {
      throw WorkRootViolation('cannot create Work Root: ${error.message}');
    }
    final type = await FileSystemEntity.type(requested.path, followLinks: true);
    if (type != FileSystemEntityType.directory) {
      throw WorkRootViolation(
          'Work Root is not a directory: ${requested.path}');
    }
    final canonicalPath = await requested.resolveSymbolicLinks();
    final canonical = Directory(canonicalPath);
    try {
      await platform.restrictPermissions(canonical.path, directory: true);
    } on Object catch (error) {
      throw WorkRootViolation('cannot secure Work Root: $error');
    }
    return canonical;
  }

  String _join(
      String first, String second, String third, String fourth, String fifth,
      {String? separator}) {
    return [first, second, third, fourth, fifth]
        .join(separator ?? Platform.pathSeparator);
  }
}

class WorkRootViolation implements Exception {
  const WorkRootViolation(this.message);

  final String message;

  @override
  String toString() => 'WorkRootViolation: $message';
}

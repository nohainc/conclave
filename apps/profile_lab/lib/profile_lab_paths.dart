import 'dart:io';

import 'profile_lab_cloud_config.dart';

/// Standard, isolated filesystem paths for Conclave Profile Lab on macOS.
///
/// Profile Lab uses its own subtree of the Conclave application-family root,
/// separate from Conclave Workspace.
class ProfileLabPaths {
  ProfileLabPaths({String? homeDirectory, Directory? repositoryRoot})
      : _repositoryRoot = repositoryRoot,
        _home = homeDirectory ??
            Platform.environment['HOME'] ??
            Directory.current.path;

  final String _home;
  final Directory? _repositoryRoot;

  /// Application-managed Profile Lab data:
  /// `~/Library/Application Support/Conclave/Profile Lab/`
  ///
  /// Local development builds use `Conclave Local` instead of `Conclave` so
  /// drafts and settings never mix with the production app.
  Directory get applicationSupportDirectory => Directory(
        '$_home/Library/Application Support/'
        '${ProfileLabCloudConfig.isLocalBuild ? 'Conclave Local' : 'Conclave'}'
        '/Profile Lab',
      );

  /// Isolated drafts storage root:
  /// `~/Library/Application Support/Conclave/Profile Lab/drafts/`
  Directory get draftsDirectory =>
      Directory('${applicationSupportDirectory.path}/drafts');

  /// Repository that holds the Profile files. Profile Lab is an internal tool
  /// that runs from a checkout: this is the nearest ancestor containing `.git`
  /// of the current directory or of the running executable. Tests inject it.
  late final Directory? repositoryRoot = _repositoryRoot ?? _findRepository();

  /// Worker Profile source files, one per Worker:
  /// `<repository>/apps/profile_lab/assets/profiles/<workerTypeId>.json`
  Directory? get profilesDirectory {
    final root = repositoryRoot;
    return root == null
        ? null
        : Directory('${root.path}/apps/profile_lab/assets/profiles');
  }

  static Directory? _findRepository() {
    for (final start in [
      Directory.current.absolute.path,
      File(Platform.resolvedExecutable).parent.absolute.path,
    ]) {
      var dir = Directory(start);
      while (true) {
        if (FileSystemEntity.typeSync('${dir.path}/.git') !=
            FileSystemEntityType.notFound) {
          return dir;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }

  /// Bundled/cached CLI Worker Engine binaries root:
  /// `~/Library/Application Support/Conclave/Profile Lab/engines/`
  Directory get enginesDirectory =>
      Directory('${applicationSupportDirectory.path}/engines');

  /// Dedicated isolated scratch and execution sandbox root:
  /// `~/Library/Application Support/Conclave/Profile Lab/sandbox/`
  Directory get sandboxDirectory =>
      Directory('${applicationSupportDirectory.path}/sandbox');

  /// Dedicated macOS logging directory:
  /// `~/Library/Logs/conclave.profile_lab/`
  Directory get logsDirectory =>
      Directory('$_home/Library/Logs/conclave.profile_lab');

  /// Legacy credentials root used only to remove or migrate old session files.
  Directory get credentialsDirectory =>
      Directory('${applicationSupportDirectory.path}/credentials');

  /// Legacy session file path. New sessions are stored in macOS Keychain.
  File get sessionFile =>
      File('${credentialsDirectory.path}/profile_lab_session.json');

  /// Non-secret Cloud origin override selected in Profile Lab settings.
  File get cloudSettingsFile =>
      File('${applicationSupportDirectory.path}/cloud_settings.json');

  Directory get legacyApplicationSupportDirectory => Directory(
        '$_home/Library/Application Support/conclave.profile_lab',
      );

  /// Bundle identifier and secure Keychain service namespace.
  static const String bundleIdentifier = 'com.conclaveax.profile-lab';
  static const String keychainService = 'com.conclaveax.profile-lab';

  /// Ensures all required application support directories exist with restrictive
  /// POSIX permissions (0700).
  Future<void> ensureDirectoriesExist() async {
    if (await legacyApplicationSupportDirectory.exists() &&
        !await applicationSupportDirectory.exists()) {
      await applicationSupportDirectory.parent.create(recursive: true);
      await legacyApplicationSupportDirectory
          .rename(applicationSupportDirectory.path);
    }
    for (final dir in [
      applicationSupportDirectory,
      draftsDirectory,
      enginesDirectory,
      sandboxDirectory,
      logsDirectory,
    ]) {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (Platform.isMacOS || Platform.isLinux) {
        try {
          await Process.run('chmod', ['700', dir.path]);
        } catch (_) {
          // Best effort if permissions are constrained in tests
        }
      }
    }
  }
}

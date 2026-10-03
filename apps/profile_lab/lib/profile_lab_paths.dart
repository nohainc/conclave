import 'dart:io';

/// Standard, isolated filesystem paths for Conclave Profile Lab on macOS.
///
/// Profile Lab maintains its own dedicated application support directory,
/// logs directory, and credentials namespace, completely segregated from
/// Conclave Workspace.
class ProfileLabPaths {
  ProfileLabPaths({String? homeDirectory})
      : _home = homeDirectory ??
            Platform.environment['HOME'] ??
            Directory.current.path;

  final String _home;

  /// Root application support directory:
  /// `~/Library/Application Support/conclave.profile_lab/`
  Directory get applicationSupportDirectory => Directory(
        '$_home/Library/Application Support/conclave.profile_lab',
      );

  /// Isolated drafts storage root:
  /// `~/Library/Application Support/conclave.profile_lab/drafts/`
  Directory get draftsDirectory =>
      Directory('${applicationSupportDirectory.path}/drafts');

  /// Bundled/cached CLI Worker Engine binaries root:
  /// `~/Library/Application Support/conclave.profile_lab/engines/`
  Directory get enginesDirectory =>
      Directory('${applicationSupportDirectory.path}/engines');

  /// Dedicated isolated scratch and execution sandbox root:
  /// `~/Library/Application Support/conclave.profile_lab/sandbox/`
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

  /// Bundle identifier and secure Keychain service namespace.
  static const String bundleIdentifier = 'com.conclaveax.profile-lab';
  static const String keychainService = 'com.conclaveax.profile-lab';

  /// Ensures all required application support directories exist with restrictive
  /// POSIX permissions (0700).
  Future<void> ensureDirectoriesExist() async {
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

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Linux secret store selection (ADR-021 §2.3).
enum LinuxCredentialStoreKind {
  /// libsecret via `secret-tool`; requires a session D-Bus.
  secretService('secret-service'),

  /// A `0600` file owned by the service user under the state root.
  file('file');

  const LinuxCredentialStoreKind(this.id);
  final String id;

  static LinuxCredentialStoreKind? parse(String? value) {
    for (final kind in values) {
      if (kind.id == value?.trim()) return kind;
    }
    return null;
  }
}

/// Resolves and records the store for one state root. The UI and the
/// headless service may start with different environments (a systemd user
/// unit can lack the session bus), so the first selection is persisted and
/// every later reader uses it. There is no fallback after selection.
class LinuxCredentialStoreSelector {
  LinuxCredentialStoreSelector(this.stateDirectory,
      {Map<String, String>? environment,
      bool Function()? secretServiceAvailable})
      : environment = environment ?? Platform.environment,
        _secretServiceAvailable = secretServiceAvailable ?? _probeSecretService;

  final bool Function() _secretServiceAvailable;

  static bool _probeSecretService() {
    if (!Platform.isLinux) return false;
    try {
      final helper = Process.runSync('which', ['secret-tool']);
      if (helper.exitCode != 0) return false;
      // A user bus also exists on headless systemd hosts. Require an actual
      // Secret Service owner; never activate or unlock a desktop keyring here.
      final owner = Process.runSync('busctl', [
        '--user',
        '--timeout=2',
        'call',
        'org.freedesktop.DBus',
        '/org/freedesktop/DBus',
        'org.freedesktop.DBus',
        'NameHasOwner',
        's',
        'org.freedesktop.secrets'
      ]);
      return owner.exitCode == 0 && owner.stdout.toString().trim() == 'b true';
    } on ProcessException {
      return false;
    }
  }

  final Directory stateDirectory;
  final Map<String, String> environment;

  File get _record => File('${stateDirectory.path}/credential-store');

  LinuxCredentialStoreKind? recorded() {
    if (!_record.existsSync()) return null;
    final kind = LinuxCredentialStoreKind.parse(_record.readAsStringSync());
    if (kind == null) {
      throw StateError(
          'Unknown credential store recorded in ${_record.path}; files were preserved.');
    }
    return kind;
  }

  LinuxCredentialStoreKind preferred() {
    final configured = environment['CONCLAVE_WORKSPACE_SECRET_STORE'];
    if (configured != null && configured.isNotEmpty) {
      return LinuxCredentialStoreKind.parse(configured) ??
          (throw StateError(
              'CONCLAVE_WORKSPACE_SECRET_STORE must be secret-service or file'));
    }
    final bus = environment['DBUS_SESSION_BUS_ADDRESS'];
    return bus != null && bus.isNotEmpty && _secretServiceAvailable()
        ? LinuxCredentialStoreKind.secretService
        : LinuxCredentialStoreKind.file;
  }

  /// The store readers use: the recorded one, else the current preference.
  LinuxCredentialStoreKind effective() => recorded() ?? preferred();

  /// Records the selection on first write.
  LinuxCredentialStoreKind selectForWrite() {
    final existing = recorded();
    if (existing != null) return existing;
    final kind = preferred();
    stateDirectory.createSync(recursive: true);
    _restrict(stateDirectory.path, directory: true);
    _record.writeAsStringSync(kind.id, flush: true);
    _restrict(_record.path, directory: false);
    return kind;
  }
}

/// User-only file store for headless Linux hosts. Values are plaintext on
/// disk protected by ownership and mode, so the store refuses to read any
/// file or directory that group or other users can access.
class LinuxFileCredentials {
  LinuxFileCredentials(this.directory);
  final Directory directory;

  File _file(String service, String key) => File(
      '${directory.path}/${sha256.convert(utf8.encode('$service\u0000$key'))}.secret');

  String? read(String service, String key) {
    final file = _file(service, key);
    if (!file.existsSync()) return null;
    _requirePrivate(directory.path);
    _requirePrivate(file.path);
    if (file.lengthSync() > 1024 * 1024) {
      throw StateError('Credential file exceeds limit');
    }
    final value = file.readAsStringSync();
    return value.isEmpty ? null : value;
  }

  void write(String service, String key, String value) {
    directory.createSync(recursive: true);
    _restrict(directory.path, directory: true);
    final file = _file(service, key);
    final temporary = File('${file.path}.$pid.tmp');
    try {
      // Create with a private mode before any secret bytes are written.
      temporary.createSync();
      _restrict(temporary.path, directory: false);
      temporary.writeAsStringSync(value, flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  void delete(String service, String key) {
    final file = _file(service, key);
    if (file.existsSync()) file.deleteSync();
  }

  static void _requirePrivate(String path) {
    final mode = FileStat.statSync(path).mode;
    if (mode & 0x3f != 0) {
      throw StateError(
          'Refusing to use $path: permissions allow group or other access');
    }
  }
}

void _restrict(String path, {required bool directory}) {
  final result = Process.runSync('chmod', [directory ? '700' : '600', path]);
  if (result.exitCode != 0) {
    throw StateError('failed to restrict permissions for $path');
  }
}

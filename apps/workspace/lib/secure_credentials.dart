import 'dart:io';

import 'credential_backend.dart';

/// OS-backed storage for credentials used by the Workspace.
abstract interface class SecureCredentialStore {
  String? readSync(String key);

  Future<String?> read(String key) async => readSync(key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

abstract interface class NativeSecureCredentialBridge {
  Future<String?> read({required String service, required String account});

  Future<void> write({
    required String service,
    required String account,
    required String value,
  });

  Future<void> delete({required String service, required String account});
}

/// Uses the platform's native credential service rather than a plaintext file.
/// Unsupported platforms fail closed and return no credential.
class PlatformSecureCredentialStore implements SecureCredentialStore {
  const PlatformSecureCredentialStore({
    this.service = 'com.conclaveax.workspace',
    String? platform,
    this.nativeKeychain,
  }) : _platform = platform;

  static final Map<String, String?> _cache = {};
  static final Set<String> _loaded = {};

  final String service;
  final String? _platform;
  final NativeSecureCredentialBridge? nativeKeychain;

  String get _effectivePlatform => _platform ?? Platform.operatingSystem;

  String _cacheKey(String key) => '$service\u0000$key';

  @override
  String? readSync(String key) {
    if (key.isEmpty) return null;
    final cacheKey = _cacheKey(key);
    if (_loaded.contains(cacheKey)) return _cache[cacheKey];
    final command = currentCredentialBackend.read(service, key);
    if (command == null) return null;
    try {
      final result = Process.runSync(command.executable, command.arguments);
      if (result.exitCode != 0) {
        _cache[cacheKey] = null;
        _loaded.add(cacheKey);
        return null;
      }
      final value = result.stdout.toString().trim();
      final resolved = value.isEmpty ? null : value;
      _cache[cacheKey] = resolved;
      _loaded.add(cacheKey);
      return resolved;
    } on ProcessException {
      // Minimal Linux/CI environments may not have the platform credential
      // helper installed. Treat that as secure storage being unavailable,
      // rather than making configuration parsing fail.
      return null;
    }
  }

  @override
  Future<String?> read(String key) async {
    if (key.isEmpty) return null;
    final cacheKey = _cacheKey(key);
    if (_loaded.contains(cacheKey)) return _cache[cacheKey];
    if (_effectivePlatform == 'macos') {
      final keychain = nativeKeychain;
      if (keychain != null) {
        final value = await keychain.read(service: service, account: key);
        _cache[cacheKey] = value;
        _loaded.add(cacheKey);
        return value;
      }
    }
    return readSync(key);
  }

  /// Loads the runtime credential before [WorkspaceConfig.fromArgs] performs its
  /// synchronous read. This also supports older runtime IDs that do not use
  /// the current `runtime-` prefix.
  Future<String?> readForSynchronousConfig(String key) async {
    String? value;
    try {
      value = await read(key);
    } on Object {
      // A Keychain/channel failure must not prevent the desktop UI from
      // starting. Fall back to the OS credential helper used by headless
      // startup; if that also fails, the Workspace stays safely offline.
      value = readSync(key);
    }
    final cacheKey = _cacheKey(key);
    _cache[cacheKey] = value;
    _loaded.add(cacheKey);
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    if (key.isEmpty || value.isEmpty) {
      throw ArgumentError('credential key and value are required');
    }
    final cacheKey = _cacheKey(key);
    if (_effectivePlatform == 'macos') {
      final keychain = nativeKeychain;
      if (keychain == null) {
        throw UnsupportedError(
          'Native macOS Keychain access is unavailable in this process',
        );
      }
      await keychain.write(service: service, account: key, value: value);
      _cache[cacheKey] = value;
      _loaded.add(cacheKey);
      return;
    }
    final command = currentCredentialBackend.write(service, key);
    if (command == null) {
      throw UnsupportedError(
          'OS secure credential storage is unavailable on ${Platform.operatingSystem}');
    }
    final process = await Process.start(command.executable, command.arguments);
    process.stdin.write(value);
    await process.stdin.close();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw StateError('OS secure credential storage rejected the write');
    }
    _cache[cacheKey] = value;
    _loaded.add(cacheKey);
  }

  @override
  Future<void> delete(String key) async {
    if (key.isEmpty) return;
    final cacheKey = _cacheKey(key);
    _cache.remove(cacheKey);
    _loaded.remove(cacheKey);
    if (_effectivePlatform == 'macos') {
      final keychain = nativeKeychain;
      if (keychain != null) {
        try {
          await keychain.delete(service: service, account: key);
          return;
        } on Object {
          // Recovery must still be possible if the native channel is absent.
          // Fall through to macOS's OS credential helper below.
        }
      }
    }
    final command = currentCredentialBackend.delete(service, key);
    if (command == null) return;
    final result = await Process.run(command.executable, command.arguments);
    // Deleting a missing credential is idempotent. Other failures are not.
    final error = result.stderr.toString().toLowerCase();
    if (result.exitCode != 0 &&
        !error.contains('not found') &&
        !error.contains('could not be found')) {
      throw StateError('OS secure credential storage rejected the delete');
    }
  }
}

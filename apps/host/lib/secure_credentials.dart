import 'dart:io';

import 'credential_backend.dart';

/// OS-backed storage for credentials used by the Host.
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
    this.service = 'com.conclaveax.host',
    String? platform,
    this.nativeKeychain,
  }) : _platform = platform;

  static final Map<String, String?> _cache = {};
  static final Set<String> _loaded = {};

  final String service;
  final String? _platform;
  final NativeSecureCredentialBridge? nativeKeychain;

  String get _effectivePlatform => _platform ?? Platform.operatingSystem;
  bool _needsSynchronousCache(String key) => key.startsWith('runtime-');

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
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      return value.isEmpty ? null : value;
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
    if (_effectivePlatform == 'macos') {
      final keychain = nativeKeychain;
      if (keychain != null) {
        final value = await keychain.read(service: service, account: key);
        if (_needsSynchronousCache(key)) {
          final cacheKey = _cacheKey(key);
          _cache[cacheKey] = value;
          _loaded.add(cacheKey);
        }
        return value;
      }
    }
    return readSync(key);
  }

  /// Loads the runtime credential before [HostConfig.fromArgs] performs its
  /// synchronous read. This also supports older runtime IDs that do not use
  /// the current `runtime-` prefix.
  Future<String?> readForSynchronousConfig(String key) async {
    final value = await read(key);
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
    if (_effectivePlatform == 'macos') {
      final keychain = nativeKeychain;
      if (keychain == null) {
        throw UnsupportedError(
          'Native macOS Keychain access is unavailable in this process',
        );
      }
      await keychain.write(service: service, account: key, value: value);
      if (_needsSynchronousCache(key)) {
        final cacheKey = _cacheKey(key);
        _cache[cacheKey] = value;
        _loaded.add(cacheKey);
      }
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
    if (_needsSynchronousCache(key)) {
      final cacheKey = _cacheKey(key);
      _cache[cacheKey] = value;
      _loaded.add(cacheKey);
    }
  }

  @override
  Future<void> delete(String key) async {
    if (key.isEmpty) return;
    if (_effectivePlatform == 'macos') {
      final keychain = nativeKeychain;
      if (keychain != null) {
        await keychain.delete(service: service, account: key);
        if (_needsSynchronousCache(key)) {
          final cacheKey = _cacheKey(key);
          _cache.remove(cacheKey);
          _loaded.add(cacheKey);
        }
        return;
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
    if (_needsSynchronousCache(key)) {
      final cacheKey = _cacheKey(key);
      _cache.remove(cacheKey);
      _loaded.add(cacheKey);
    }
  }
}

import 'dart:io';

import 'credential_backend.dart';

/// OS-backed storage for credentials used by the Agent Engine.
abstract interface class SecureCredentialStore {
  String? readSync(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Uses the platform's native credential service rather than a plaintext file.
/// Unsupported platforms fail closed and return no credential.
class PlatformSecureCredentialStore implements SecureCredentialStore {
  const PlatformSecureCredentialStore({this.service = 'com.conclaveax.agent'});

  final String service;

  @override
  String? readSync(String key) {
    if (key.isEmpty) return null;
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
  Future<void> write(String key, String value) async {
    if (key.isEmpty || value.isEmpty) {
      throw ArgumentError('credential key and value are required');
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
  }

  @override
  Future<void> delete(String key) async {
    if (key.isEmpty) return;
    final command = currentCredentialBackend.delete(service, key);
    if (command == null) return;
    final result = await Process.run(command.executable, command.arguments);
    // Deleting a missing credential is idempotent. Other failures are not.
    if (result.exitCode != 0 &&
        !result.stderr.toString().contains('not found')) {
      throw StateError('OS secure credential storage rejected the delete');
    }
  }
}

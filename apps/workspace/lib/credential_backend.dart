import 'dart:io';

abstract interface class SecureCredentialBackend {
  SecureCommand? read(String service, String key);
  SecureCommand? write(String service, String key);
  SecureCommand? delete(String service, String key);
}

SecureCredentialBackend get currentCredentialBackend =>
    switch (Platform.operatingSystem) {
      'macos' => const _MacOsCredentialBackend(),
      'linux' => const _LinuxCredentialBackend(),
      _ => const _UnsupportedCredentialBackend(),
    };

final class _MacOsCredentialBackend implements SecureCredentialBackend {
  const _MacOsCredentialBackend();
  @override
  SecureCommand read(String service, String key) => SecureCommand(
      'security', ['find-generic-password', '-a', key, '-s', service, '-w']);
  @override
  SecureCommand write(String service, String key) => SecureCommand('security',
      ['add-generic-password', '-a', key, '-s', service, '-U', '-w']);
  @override
  SecureCommand delete(String service, String key) => SecureCommand(
      'security', ['delete-generic-password', '-a', key, '-s', service]);
}

final class _LinuxCredentialBackend implements SecureCredentialBackend {
  const _LinuxCredentialBackend();
  @override
  SecureCommand read(String service, String key) => SecureCommand(
      'secret-tool', ['lookup', 'service', service, 'account', key]);
  @override
  SecureCommand write(String service, String key) => SecureCommand(
      'secret-tool',
      ['store', '--label', service, 'service', service, 'account', key]);
  @override
  SecureCommand delete(String service, String key) => SecureCommand(
      'secret-tool', ['clear', 'service', service, 'account', key]);
}

final class _UnsupportedCredentialBackend implements SecureCredentialBackend {
  const _UnsupportedCredentialBackend();
  @override
  SecureCommand? read(String service, String key) => null;
  @override
  SecureCommand? write(String service, String key) => null;
  @override
  SecureCommand? delete(String service, String key) => null;
}

class SecureCommand {
  const SecureCommand(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

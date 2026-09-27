import 'package:flutter/services.dart';

import 'secure_credentials.dart';

/// Flutter MethodChannel transport for the native macOS Keychain bridge.
/// Kept separate from the portable runtime so Dart-only tools do not depend on
/// Flutter's dart:ui libraries.
class FlutterMacKeychainBridge implements NativeSecureCredentialBridge {
  const FlutterMacKeychainBridge();

  static const _channel = MethodChannel('com.conclave.workspace/keychain');

  @override
  Future<String?> read({required String service, required String account}) =>
      _channel.invokeMethod<String>(
        'read',
        {'service': service, 'account': account},
      );

  @override
  Future<void> write({
    required String service,
    required String account,
    required String value,
  }) =>
      _channel.invokeMethod<void>(
        'write',
        {'service': service, 'account': account, 'value': value},
      );

  @override
  Future<void> delete({required String service, required String account}) =>
      _channel.invokeMethod<void>(
        'delete',
        {'service': service, 'account': account},
      );
}

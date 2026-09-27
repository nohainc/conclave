import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/secure_credentials.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('macOS credentials use the native Keychain channel', () async {
    const channel = MethodChannel('com.conclave.workspace/keychain');
    final values = <String, String>{};
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = Map<String, Object?>.from(call.arguments as Map);
      final key = '${args['service']}/${args['account']}';
      switch (call.method) {
        case 'write':
          values[key] = args['value'] as String;
          return null;
        case 'read':
          return values[key];
        case 'delete':
          values.remove(key);
          return null;
        default:
          throw MissingPluginException();
      }
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    const store = PlatformSecureCredentialStore(platform: 'macos');
    const account = 'runtime-test';
    const token = 'test-only-runtime-secret';
    await store.write(account, token);

    expect(calls, ['write']);
    expect(store.readSync(account), token);
    expect(await store.read(account), token);

    await store.delete(account);
    expect(await store.read(account), isNull);
    expect(calls, ['write', 'read', 'delete', 'read']);
  });
}

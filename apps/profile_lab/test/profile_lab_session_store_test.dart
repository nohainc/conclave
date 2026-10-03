import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileLabSessionStore', () {
    test('persists session in Keychain and loads for its Cloud origin',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('profile_lab_session_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      final paths = ProfileLabPaths(homeDirectory: tempDir.path);
      final values = <String, String>{};
      const channel = MethodChannel('profile-lab-session-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final account = (call.arguments as Map)['account'] as String;
        switch (call.method) {
          case 'read':
            return values[account];
          case 'write':
            values[account] = (call.arguments as Map)['value'] as String;
            return null;
          case 'delete':
            values.remove(account);
            return null;
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final store = ProfileLabSessionStore.forTesting(paths, channel: channel);
      final session = ProfileLabSession(
        credential: 'conclave_dhs_sample_cred',
        sessionId: 'session-sample-1',
        userId: 'admin-1',
        displayName: 'Security Admin',
        email: 'admin@conclave.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      );

      const cloudOrigin = 'https://app.conclaveax.com';
      await store.save(session, cloudOrigin: cloudOrigin);
      expect(paths.sessionFile.existsSync(), isFalse);

      final loaded = await store.load(cloudOrigin: cloudOrigin);
      expect(loaded, isNotNull);
      expect(loaded!.credential, 'conclave_dhs_sample_cred');
      expect(loaded.sessionId, 'session-sample-1');
      expect(loaded.userId, 'admin-1');
      expect(loaded.audience, 'conclave.profile-lab.management');

      final wrongOrigin =
          await store.load(cloudOrigin: 'http://localhost:8787');
      expect(wrongOrigin, isNull);
      expect(values, isEmpty);

      await store.clear();
      expect(values, isEmpty);
    });

    test('discards legacy sessions that are not bound to a Cloud origin',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('profile_lab_legacy_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      final paths = ProfileLabPaths(homeDirectory: tempDir.path);
      await paths.sessionFile.parent.create(recursive: true);
      await paths.sessionFile.writeAsString(jsonEncode({
        'credential': 'legacy-secret',
        'sessionId': 'session-legacy',
        'userId': 'admin-1',
        'displayName': 'Legacy Admin',
        'email': 'admin@conclave.test',
        'audience': 'conclave.profile-lab.management',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 2))
            .toIso8601String(),
      }));
      final values = <String, String>{};
      const channel = MethodChannel('profile-lab-legacy-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final account = (call.arguments as Map)['account'] as String;
        if (call.method == 'read') {
          return values[account];
        }
        if (call.method == 'write') {
          values[account] = (call.arguments as Map)['value'] as String;
        }
        if (call.method == 'delete') {
          values.remove(account);
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final store = ProfileLabSessionStore.forTesting(paths, channel: channel);

      final loaded =
          await store.load(cloudOrigin: 'https://app.conclaveax.com');
      expect(loaded, isNull);
      expect(await paths.sessionFile.exists(), isFalse);
      expect(values, isEmpty);
    });
  });
}

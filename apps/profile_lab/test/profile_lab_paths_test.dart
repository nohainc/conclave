import 'dart:io';

import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileLabPaths', () {
    test('enforces segregated macOS directories', () {
      final paths = ProfileLabPaths(homeDirectory: '/Users/testuser');

      expect(
        paths.applicationSupportDirectory.path,
        '/Users/testuser/Library/Application Support/Conclave/Profile Lab',
      );
      expect(
        paths.draftsDirectory.path,
        '/Users/testuser/Library/Application Support/Conclave/Profile Lab/drafts',
      );
      expect(
        paths.enginesDirectory.path,
        '/Users/testuser/Library/Application Support/Conclave/Profile Lab/engines',
      );
      expect(
        paths.sandboxDirectory.path,
        '/Users/testuser/Library/Application Support/Conclave/Profile Lab/sandbox',
      );
      expect(
        paths.logsDirectory.path,
        '/Users/testuser/Library/Logs/conclave.profile_lab',
      );
      expect(
        paths.credentialsDirectory.path,
        '/Users/testuser/Library/Application Support/Conclave/Profile Lab/credentials',
      );
      expect(
        paths.sessionFile.path,
        '/Users/testuser/Library/Application Support/Conclave/Profile Lab/credentials/profile_lab_session.json',
      );
      expect(
        paths.cloudSettingsFile.path,
        '/Users/testuser/Library/Application Support/Conclave/Profile Lab/cloud_settings.json',
      );
      expect(
        ProfileLabPaths.bundleIdentifier,
        'com.conclaveax.profile-lab',
      );
    });

    test('ensureDirectoriesExist creates all segregated directories', () async {
      final temp = await Directory.systemTemp.createTemp('profile_lab_test_');
      try {
        final paths = ProfileLabPaths(homeDirectory: temp.path);
        await paths.ensureDirectoriesExist();

        expect(await paths.applicationSupportDirectory.exists(), isTrue);
        expect(await paths.draftsDirectory.exists(), isTrue);
        expect(await paths.enginesDirectory.exists(), isTrue);
        expect(await paths.sandboxDirectory.exists(), isTrue);
        expect(await paths.credentialsDirectory.exists(), isFalse);
        expect(await paths.logsDirectory.exists(), isTrue);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'profile_lab_auth.dart';
import 'profile_lab_cloud_config.dart';
import 'profile_lab_paths.dart';

/// Stores the Profile Lab bearer session in the macOS login Keychain.
class ProfileLabSessionStore {
  ProfileLabSessionStore(this.paths, {MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.conclaveax.profile-lab/keychain'),
        _isMacOS = Platform.isMacOS,
        _inMemoryForTesting = false;

  @visibleForTesting
  ProfileLabSessionStore.forTesting(
    this.paths, {
    required MethodChannel channel,
  })  : _channel = channel,
        _isMacOS = true,
        _inMemoryForTesting = false;

  @visibleForTesting
  ProfileLabSessionStore.inMemoryForTesting(this.paths)
      : _channel = const MethodChannel('com.conclaveax.profile-lab/keychain'),
        _isMacOS = true,
        _inMemoryForTesting = true;

  final ProfileLabPaths paths;
  final MethodChannel _channel;
  final bool _isMacOS;
  final bool _inMemoryForTesting;

  static const _account = 'profile-lab-human-session';

  Future<ProfileLabSession?> load({required String cloudOrigin}) async {
    if (_inMemoryForTesting) return null;
    if (!_isMacOS) {
      throw UnsupportedError(
          'Profile Lab sessions require the macOS Keychain.');
    }
    final raw =
        await _channel.invokeMethod<String>('read', {'account': _account});
    await _deleteLegacyFile();
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await clear();
        return null;
      }
      final normalizedOrigin =
          ProfileLabCloudConfig.normalizeOrigin(cloudOrigin);
      if (decoded['schemaVersion'] != 1 ||
          decoded['cloudOrigin'] != normalizedOrigin ||
          decoded['session'] is! Map) {
        await clear();
        return null;
      }
      final session = ProfileLabSession.fromStoredJson(
        Map<String, dynamic>.from(decoded['session'] as Map),
      );
      if (session.isExpired) {
        await clear();
        return null;
      }
      return session;
    } on FormatException {
      await clear();
      return null;
    } on TypeError {
      await clear();
      return null;
    }
  }

  Future<void> save(
    ProfileLabSession session, {
    required String cloudOrigin,
  }) async {
    if (_inMemoryForTesting) return;
    if (!_isMacOS) {
      throw UnsupportedError(
          'Profile Lab sessions require the macOS Keychain.');
    }
    await _channel.invokeMethod<void>('write', {
      'account': _account,
      'value': jsonEncode({
        'schemaVersion': 1,
        'cloudOrigin': ProfileLabCloudConfig.normalizeOrigin(cloudOrigin),
        'session': session.toStoredJson(),
      }),
    });
    await _deleteLegacyFile();
  }

  Future<void> clear() async {
    if (_inMemoryForTesting) return;
    if (!_isMacOS) {
      throw UnsupportedError(
          'Profile Lab sessions require the macOS Keychain.');
    }
    await _channel.invokeMethod<void>('delete', {'account': _account});
    await _deleteLegacyFile();
  }

  Future<void> _deleteLegacyFile() async {
    final file = paths.sessionFile;
    if (await file.exists()) await file.delete();
  }
}

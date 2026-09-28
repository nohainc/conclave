import 'dart:convert';
import 'dart:io';

import 'platform_runtime.dart';
import 'workspace_lifecycle.dart';

/// Persists non-secret local lifecycle intent and display-only owner metadata.
class WorkspaceLifecyclePreferencesStore {
  const WorkspaceLifecyclePreferencesStore(this.dataDirectory);

  static const currentSchemaVersion = 1;
  static int _temporaryFileCounter = 0;

  final Directory dataDirectory;

  File get file => File(
      '${dataDirectory.path}${Platform.pathSeparator}workspace-lifecycle.json');

  bool get needsRuntimeCredentialMigrationCheck {
    if (!file.existsSync()) return true;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return true;
      final version = decoded['schemaVersion'];
      if (version is int && version >= currentSchemaVersion) return false;
      return _parseDesiredRuntime(
            decoded['desiredRuntimeState'] ?? decoded['desiredRuntime'],
          ) ==
          null;
    } on Object {
      return true;
    }
  }

  WorkspaceLifecyclePreferences readSync() {
    if (!file.existsSync()) return _defaults;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return _defaults;
      final map = Map<String, dynamic>.from(decoded);
      return _preferencesFromMap(
        map,
        desiredRuntime: _parseDesiredRuntime(
              map['desiredRuntimeState'] ?? map['desiredRuntime'],
            ) ??
            DesiredRuntimeState.disconnected,
      );
    } on Object {
      return _defaults;
    }
  }

  /// Upgrades the unversioned lifecycle file once, preserving an explicit
  /// disconnected marker. Older installs without saved intent reconnect only
  /// when both the registration and its secure runtime credential exist.
  Future<bool> migrateLegacyIfNeeded({
    required bool hasRuntimeRegistrationAndCredential,
  }) async {
    if (!file.existsSync()) {
      if (!hasRuntimeRegistrationAndCredential) return false;
      await write(_defaults.copyWith(
        desiredRuntime: DesiredRuntimeState.connected,
      ));
      return true;
    }

    Map<String, dynamic> decoded = const {};
    try {
      final value = jsonDecode(file.readAsStringSync());
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } on Object {
      // A corrupt/unreadable legacy preference file has no trustworthy
      // disconnected marker. Recover connected intent only from a complete
      // local registration plus credential; otherwise use the safe default.
    }

    final version = decoded['schemaVersion'];
    if (version is int && version >= currentSchemaVersion) return false;

    final legacyDesired = _parseDesiredRuntime(
      decoded['desiredRuntimeState'] ?? decoded['desiredRuntime'],
    );
    final preferences = _preferencesFromMap(
      decoded,
      desiredRuntime: legacyDesired ??
          (hasRuntimeRegistrationAndCredential
              ? DesiredRuntimeState.connected
              : DesiredRuntimeState.disconnected),
    );
    await write(preferences);
    return true;
  }

  Future<void> write(WorkspaceLifecyclePreferences preferences) async {
    await dataDirectory.create(recursive: true);
    final temporary = File(
      '${file.path}.tmp.$pid.${++_temporaryFileCounter}',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({
          'schemaVersion': currentSchemaVersion,
          'desiredRuntimeState': preferences.desiredRuntime.name,
          'launchAtLogin': preferences.launchAtLogin,
          'managementLockPreference': preferences.managementLockPreference.name,
          if (preferences.autoLockTimeout != null)
            'autoLockTimeoutSeconds': preferences.autoLockTimeout!.inSeconds,
          if (preferences.ownerUserId != null)
            'ownerUserId': preferences.ownerUserId,
          if (preferences.ownerDisplayName != null)
            'ownerDisplayName': preferences.ownerDisplayName,
          if (preferences.customWorkspaceName != null)
            'customWorkspaceName': preferences.customWorkspaceName,
        }),
        flush: true,
      );
      await currentPlatformRuntime.restrictPermissions(temporary.path,
          directory: false);
      await temporary.rename(file.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  static WorkspaceLifecyclePreferences _preferencesFromMap(
    Map<String, dynamic> decoded, {
    required DesiredRuntimeState desiredRuntime,
  }) {
    final lock = ManagementLockState.values.firstWhere(
      (value) => value.name == decoded['managementLockPreference'],
      orElse: () => ManagementLockState.unlocked,
    );
    final timeoutSeconds = decoded['autoLockTimeoutSeconds'];
    return WorkspaceLifecyclePreferences(
      desiredRuntime: desiredRuntime,
      launchAtLogin: decoded['launchAtLogin'] == true,
      managementLockPreference: lock,
      autoLockTimeout: timeoutSeconds is int && timeoutSeconds > 0
          ? Duration(seconds: timeoutSeconds)
          : null,
      ownerUserId: decoded['ownerUserId'] is String
          ? decoded['ownerUserId'] as String
          : null,
      ownerDisplayName: decoded['ownerDisplayName'] is String
          ? decoded['ownerDisplayName'] as String
          : null,
      customWorkspaceName: decoded['customWorkspaceName'] is String
          ? decoded['customWorkspaceName'] as String
          : null,
    );
  }

  static DesiredRuntimeState? _parseDesiredRuntime(Object? value) {
    if (value is! String) return null;
    for (final state in DesiredRuntimeState.values) {
      if (state.name == value) return state;
    }
    return null;
  }

  static const _defaults = WorkspaceLifecyclePreferences(
    desiredRuntime: DesiredRuntimeState.disconnected,
    launchAtLogin: false,
    managementLockPreference: ManagementLockState.unlocked,
  );
}

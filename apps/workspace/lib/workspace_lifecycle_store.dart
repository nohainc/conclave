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

  WorkspaceLifecyclePreferences readSync() {
    if (!file.existsSync()) return _defaults;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return _defaults;
      final map = Map<String, dynamic>.from(decoded);
      return _preferencesFromMap(
        map,
        desiredRuntime: _parseDesiredRuntime(map['desiredCloudState']) ??
            DesiredRuntimeState.disconnected,
      );
    } on Object {
      return _defaults;
    }
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
          'desiredCloudState': preferences.desiredCloudState.name,
          'launchAtLogin': preferences.launchAtLogin,
          'preventSleep': preferences.preventSleep,
          'managementLockPreference': preferences.managementLockPreference.name,
          if (preferences.autoLockTimeout != null)
            'autoLockTimeoutSeconds': preferences.autoLockTimeout!.inSeconds,
          if (preferences.ownerUserId != null)
            'ownerUserId': preferences.ownerUserId,
          if (preferences.ownerDisplayName != null)
            'ownerDisplayName': preferences.ownerDisplayName,
          if (preferences.customWorkspaceName != null)
            'customWorkspaceName': preferences.customWorkspaceName,
          if (preferences.workRootPath != null)
            'workRootPath': preferences.workRootPath,
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
      preventSleep: decoded['preventSleep'] != false,
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
      workRootPath: decoded['workRootPath'] is String
          ? decoded['workRootPath'] as String
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

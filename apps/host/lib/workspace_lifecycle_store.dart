import 'dart:convert';
import 'dart:io';

import 'platform_runtime.dart';
import 'workspace_lifecycle.dart';

/// Persists non-secret local lifecycle intent and display-only owner metadata.
class WorkspaceLifecyclePreferencesStore {
  const WorkspaceLifecyclePreferencesStore(this.dataDirectory);

  final Directory dataDirectory;

  File get file => File(
      '${dataDirectory.path}${Platform.pathSeparator}workspace-lifecycle.json');

  WorkspaceLifecyclePreferences readSync() {
    if (!file.existsSync()) return _defaults;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return _defaults;
      final desired = DesiredRuntimeState.values
          .byName(decoded['desiredRuntime'] as String? ?? 'disconnected');
      final lock = ManagementLockState.values
          .byName(decoded['managementLockPreference'] as String? ?? 'unlocked');
      final timeoutSeconds = decoded['autoLockTimeoutSeconds'];
      return WorkspaceLifecyclePreferences(
        desiredRuntime: desired,
        launchAtLogin: decoded['launchAtLogin'] == true,
        managementLockPreference: lock,
        autoLockTimeout: timeoutSeconds is int && timeoutSeconds > 0
            ? Duration(seconds: timeoutSeconds)
            : null,
        ownerUserId: decoded['ownerUserId'] as String?,
        ownerDisplayName: decoded['ownerDisplayName'] as String?,
      );
    } on Object {
      return _defaults;
    }
  }

  Future<void> write(WorkspaceLifecyclePreferences preferences) async {
    await dataDirectory.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'desiredRuntime': preferences.desiredRuntime.name,
        'launchAtLogin': preferences.launchAtLogin,
        'managementLockPreference': preferences.managementLockPreference.name,
        if (preferences.autoLockTimeout != null)
          'autoLockTimeoutSeconds': preferences.autoLockTimeout!.inSeconds,
        if (preferences.ownerUserId != null)
          'ownerUserId': preferences.ownerUserId,
        if (preferences.ownerDisplayName != null)
          'ownerDisplayName': preferences.ownerDisplayName,
      }),
      flush: true,
    );
    await currentPlatformRuntime.restrictPermissions(file.path,
        directory: false);
  }

  static const _defaults = WorkspaceLifecyclePreferences(
    desiredRuntime: DesiredRuntimeState.disconnected,
    launchAtLogin: false,
    managementLockPreference: ManagementLockState.unlocked,
  );
}

import 'package:flutter/services.dart';

import 'workspace_lifecycle.dart';
import 'workspace_lifecycle_store.dart';

/// Native OS authentication for local management controls. No Conclave PIN is used.
abstract interface class LocalManagementAuthenticator {
  Future<bool> isAvailable();
  Future<bool> authenticate(String reason);
}

class MethodChannelLocalManagementAuthenticator
    implements LocalManagementAuthenticator {
  const MethodChannelLocalManagementAuthenticator();
  static const _channel = MethodChannel('com.conclave.workspace/desktop');

  @override
  Future<bool> isAvailable() async =>
      await _channel.invokeMethod<bool>('localManagementAuthAvailable') ??
      false;

  @override
  Future<bool> authenticate(String reason) async =>
      await _channel.invokeMethod<bool>(
          'authenticateLocalManagement', reason) ??
      false;
}

/// Owns only the local management-lock preference and OS authentication.
/// Runtime lifecycle and assignments are intentionally not dependencies.
class WorkspaceManagementLock {
  const WorkspaceManagementLock({
    required this.preferences,
    required this.authenticator,
  });

  final WorkspaceLifecyclePreferencesStore preferences;
  final LocalManagementAuthenticator authenticator;

  Future<bool> lock() async {
    if (!await authenticator.isAvailable()) return false;
    await _persist(ManagementLockState.locked);
    return true;
  }

  Future<bool> unlock(String reason) async {
    if (!await authenticator.authenticate(reason)) return false;
    await _persist(ManagementLockState.unlocked);
    return true;
  }

  Future<void> _persist(ManagementLockState state) async {
    final current = preferences.readSync();
    await preferences.write(WorkspaceLifecyclePreferences(
      desiredRuntime: current.desiredRuntime,
      launchAtLogin: current.launchAtLogin,
      managementLockPreference: state,
      autoLockTimeout: current.autoLockTimeout,
      ownerUserId: current.ownerUserId,
      ownerDisplayName: current.ownerDisplayName,
    ));
  }
}

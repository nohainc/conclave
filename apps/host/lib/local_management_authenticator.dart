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

/// Reuses a successful native prompt briefly across one deliberate action flow.
class RecentLocalAuthenticationGate {
  RecentLocalAuthenticationGate({
    required this.authenticator,
    this.validity = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LocalManagementAuthenticator authenticator;
  final Duration validity;
  final DateTime Function() _now;
  DateTime? _authenticatedAt;
  Future<bool>? _pending;

  bool get recentlyAuthenticated {
    final authenticatedAt = _authenticatedAt;
    if (authenticatedAt == null) return false;
    final age = _now().difference(authenticatedAt);
    return age >= Duration.zero && age <= validity;
  }

  Future<bool> require(String reason) {
    if (recentlyAuthenticated) return Future.value(true);
    final pending = _pending;
    if (pending != null) return pending;
    final authentication = _authenticate(reason);
    _pending = authentication;
    return authentication.whenComplete(() => _pending = null);
  }

  Future<bool> _authenticate(String reason) async {
    final success = await authenticator.authenticate(reason);
    if (success) _authenticatedAt = _now();
    return success;
  }

  void invalidate() => _authenticatedAt = null;
}

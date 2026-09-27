import 'dart:io';

import 'package:conclave_host/local_management_authenticator.dart';
import 'package:conclave_host/workspace_lifecycle.dart';
import 'package:conclave_host/workspace_lifecycle_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuthenticator implements LocalManagementAuthenticator {
  bool available = true;
  bool succeeds = true;
  int authenticationCount = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    authenticationCount++;
    return succeeds;
  }
}

void main() {
  test('locking and unlocking preserve runtime and account preferences',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-lock-');
    addTearDown(() => directory.delete(recursive: true));
    final store = WorkspaceLifecyclePreferencesStore(directory);
    await store.write(const WorkspaceLifecyclePreferences(
      desiredRuntime: DesiredRuntimeState.connected,
      launchAtLogin: true,
      managementLockPreference: ManagementLockState.unlocked,
      autoLockTimeout: Duration(minutes: 15),
      ownerUserId: 'owner-1',
      ownerDisplayName: 'Workspace Owner',
    ));
    final authenticator = _FakeAuthenticator();
    final lock = WorkspaceManagementLock(
      preferences: store,
      authenticator: authenticator,
    );

    expect(await lock.lock(), isTrue);
    var saved = store.readSync();
    expect(saved.managementLockPreference, ManagementLockState.locked);
    expect(saved.desiredRuntime, DesiredRuntimeState.connected);
    expect(saved.launchAtLogin, isTrue);
    expect(saved.autoLockTimeout, const Duration(minutes: 15));
    expect(saved.ownerUserId, 'owner-1');

    authenticator.succeeds = false;
    expect(await lock.unlock('Unlock test Workspace'), isFalse);
    expect(
        store.readSync().managementLockPreference, ManagementLockState.locked);

    authenticator.succeeds = true;
    expect(await lock.unlock('Unlock test Workspace'), isTrue);
    saved = store.readSync();
    expect(saved.managementLockPreference, ManagementLockState.unlocked);
    expect(saved.desiredRuntime, DesiredRuntimeState.connected);
    expect(saved.ownerUserId, 'owner-1');
  });

  test('locking is unavailable when the platform has no native authenticator',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-lock-');
    addTearDown(() => directory.delete(recursive: true));
    final store = WorkspaceLifecyclePreferencesStore(directory);
    final authenticator = _FakeAuthenticator()..available = false;
    final lock = WorkspaceManagementLock(
      preferences: store,
      authenticator: authenticator,
    );

    expect(await lock.lock(), isFalse);
    expect(store.readSync().managementLockPreference,
        ManagementLockState.unlocked);
  });

  test('step-up authentication is briefly reused and expires', () async {
    var now = DateTime.utc(2026, 9, 27);
    final authenticator = _FakeAuthenticator();
    final gate = RecentLocalAuthenticationGate(
      authenticator: authenticator,
      validity: const Duration(seconds: 30),
      now: () => now,
    );

    expect(await gate.require('Remove Worker'), isTrue);
    expect(await gate.require('Change permissions'), isTrue);
    expect(authenticator.authenticationCount, 1);

    now = now.add(const Duration(seconds: 31));
    authenticator.succeeds = false;
    expect(await gate.require('Replace credentials'), isFalse);
    expect(authenticator.authenticationCount, 2);
    expect(gate.recentlyAuthenticated, isFalse);

    authenticator.succeeds = true;
    expect(await gate.require('Release Workspace'), isTrue);
    expect(authenticator.authenticationCount, 3);
    gate.invalidate();
    expect(gate.recentlyAuthenticated, isFalse);
  });
}

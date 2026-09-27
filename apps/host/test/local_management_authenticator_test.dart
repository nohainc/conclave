import 'dart:io';

import 'package:conclave_host/local_management_authenticator.dart';
import 'package:conclave_host/workspace_lifecycle.dart';
import 'package:conclave_host/workspace_lifecycle_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuthenticator implements LocalManagementAuthenticator {
  bool available = true;
  bool succeeds = true;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async => succeeds;
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
}

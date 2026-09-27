import 'dart:io';

import 'package:conclave_host/workspace_lifecycle.dart';
import 'package:conclave_host/workspace_lifecycle_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every lifecycle dimension can be constructed independently', () {
    final states = [
      for (final auth in HumanAuthState.values)
        for (final participation in WorkspaceParticipationState.values)
          for (final lock in ManagementLockState.values)
            for (final desired in DesiredRuntimeState.values)
              WorkspaceLifecycleState(
                humanAuth: auth,
                participation: participation,
                managementLock: lock,
                desiredRuntime: desired,
              ),
    ];

    expect(states, hasLength(3 * 4 * 2 * 2));
    expect(
      states.any((state) =>
          state.humanAuth == HumanAuthState.signedOut &&
          state.participation == WorkspaceParticipationState.connected),
      isTrue,
    );
    expect(
      states.any((state) =>
          state.humanAuth == HumanAuthState.reauthRequired &&
          state.participation == WorkspaceParticipationState.connected &&
          state.managementLock == ManagementLockState.locked),
      isTrue,
    );
  });

  test('preferences contain non-secret lifecycle intent and owner cache only',
      () {
    const preferences = WorkspaceLifecyclePreferences(
      desiredRuntime: DesiredRuntimeState.connected,
      launchAtLogin: true,
      managementLockPreference: ManagementLockState.locked,
      autoLockTimeout: Duration(minutes: 10),
      ownerUserId: 'user-1',
      ownerDisplayName: 'Ada',
    );

    expect(preferences.desiredRuntime, DesiredRuntimeState.connected);
    expect(preferences.launchAtLogin, isTrue);
    expect(preferences.managementLockPreference, ManagementLockState.locked);
    expect(preferences.autoLockTimeout, const Duration(minutes: 10));
    expect(preferences.ownerUserId, 'user-1');
  });

  test('transport health remains independent of human and lock state', () {
    const lifecycle = WorkspaceLifecycleState(
      humanAuth: HumanAuthState.reauthRequired,
      participation: WorkspaceParticipationState.connected,
      managementLock: ManagementLockState.locked,
      desiredRuntime: DesiredRuntimeState.connected,
    );
    const transport = RuntimeTransportState.httpLongPoll;

    expect(lifecycle.humanAuth, HumanAuthState.reauthRequired);
    expect(lifecycle.managementLock, ManagementLockState.locked);
    expect(transport, RuntimeTransportState.httpLongPoll);
  });

  test('lifecycle preferences persist intent and owner cache without secrets',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('workspace-lifecycle-');
    addTearDown(() => directory.delete(recursive: true));
    final preferencesStore = WorkspaceLifecyclePreferencesStore(directory);
    await preferencesStore.write(const WorkspaceLifecyclePreferences(
      desiredRuntime: DesiredRuntimeState.connected,
      launchAtLogin: true,
      managementLockPreference: ManagementLockState.unlocked,
      autoLockTimeout: Duration(minutes: 5),
      ownerUserId: 'user-1',
      ownerDisplayName: 'Ada',
    ));

    final restored = preferencesStore.readSync();
    expect(restored.desiredRuntime, DesiredRuntimeState.connected);
    expect(restored.ownerUserId, 'user-1');
    expect(restored.autoLockTimeout, const Duration(minutes: 5));
    final raw = await preferencesStore.file.readAsString();
    expect(raw, isNot(contains('credential')));
    expect(raw, isNot(contains('secret')));
  });
}

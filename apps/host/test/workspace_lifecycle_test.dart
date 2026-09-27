import 'dart:convert';
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

  test('initial window hides only for enabled macOS login startup', () {
    expect(
      shouldHideManagementWindowOnStartup(
        isMacOS: true,
        launchAtLogin: true,
      ),
      isTrue,
    );
    expect(
      shouldHideManagementWindowOnStartup(
        isMacOS: true,
        launchAtLogin: false,
      ),
      isFalse,
    );
    expect(
      shouldHideManagementWindowOnStartup(
        isMacOS: false,
        launchAtLogin: true,
      ),
      isFalse,
    );
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
    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect(json['schemaVersion'],
        WorkspaceLifecyclePreferencesStore.currentSchemaVersion);
    expect(json['desiredRuntimeState'], 'connected');
    expect(json.containsKey('desiredRuntime'), isFalse);
    expect(raw, isNot(contains('credential')));
    expect(raw, isNot(contains('secret')));
    expect(
      directory.listSync().where((entity) => entity.path.contains('.tmp.')),
      isEmpty,
    );
  });

  test('legacy intent migrates connected only when intent is absent', () async {
    final directory =
        await Directory.systemTemp.createTemp('workspace-lifecycle-migration-');
    addTearDown(() => directory.delete(recursive: true));
    final store = WorkspaceLifecyclePreferencesStore(directory);

    await store.migrateLegacyIfNeeded(
      hasRuntimeRegistrationAndCredential: true,
    );
    expect(store.readSync().desiredRuntime, DesiredRuntimeState.connected);

    await store.file.writeAsString(jsonEncode({
      'desiredRuntime': 'disconnected',
      'launchAtLogin': true,
      'managementLockPreference': 'locked',
      'ownerUserId': 'owner-1',
    }));
    expect(store.needsRuntimeCredentialMigrationCheck, isFalse);
    await store.migrateLegacyIfNeeded(
      hasRuntimeRegistrationAndCredential: true,
    );
    final migrated = store.readSync();
    expect(migrated.desiredRuntime, DesiredRuntimeState.disconnected);
    expect(migrated.launchAtLogin, isTrue);
    expect(migrated.managementLockPreference, ManagementLockState.locked);
    expect(migrated.ownerUserId, 'owner-1');
  });

  test('legacy install without a runtime credential defaults disconnected',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('workspace-lifecycle-safe-');
    addTearDown(() => directory.delete(recursive: true));
    final store = WorkspaceLifecyclePreferencesStore(directory);

    await store.migrateLegacyIfNeeded(
      hasRuntimeRegistrationAndCredential: false,
    );

    expect(store.readSync().desiredRuntime, DesiredRuntimeState.disconnected);
    expect(store.file.existsSync(), isFalse);
  });

  test('local Workspace reset marks disconnected and retains chosen settings',
      () {
    const before = WorkspaceLifecyclePreferences(
      desiredRuntime: DesiredRuntimeState.connected,
      launchAtLogin: true,
      managementLockPreference: ManagementLockState.locked,
      autoLockTimeout: Duration(minutes: 15),
      ownerUserId: 'cached-owner',
      ownerDisplayName: 'Cached owner',
    );

    final reset =
        WorkspaceLifecyclePreferences.afterLocalWorkspaceReset(before);

    expect(reset.desiredRuntime, DesiredRuntimeState.disconnected);
    expect(reset.launchAtLogin, isTrue);
    expect(reset.managementLockPreference, ManagementLockState.locked);
    expect(reset.autoLockTimeout, const Duration(minutes: 15));
    expect(reset.ownerUserId, 'cached-owner');
    expect(reset.ownerDisplayName, 'Cached owner');
  });
}

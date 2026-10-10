import 'dart:io';

import 'package:conclave_workspace/assignment_journal.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_lifecycle.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_workspace/main.dart';
import 'package:conclave_workspace/workspace_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('runtime readiness uses the same catalog as Profile downloads',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('runtime-readiness-wiring-');
    final runtime = await buildWorkspaceRuntime(WorkspaceConfig(
      dataDirectory: directory,
      cloudUri: Uri.parse('https://cloud.example.test'),
      workspaceRuntimeId: 'runtime-test',
      workspaceId: 'workspace-test',
      authToken: 'test-only-credential',
      workRootPath: '${directory.path}/Work',
    ));
    try {
      expect(runtime.workerCatalogCoordinator, isNotNull);
      expect(runtime.workerReadinessMonitor?.workerCatalogCoordinator,
          same(runtime.workerCatalogCoordinator));
    } finally {
      await runtime.stop();
      await directory.delete(recursive: true);
    }
  });
  test(
      'intentional disconnect keeps registration but suppresses runtime config',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workspace-');
    const registration = WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-owned',
      workspaceId: 'workspace-owned',
      cloudUrl: 'https://cloud.example.test',
      name: 'Owned Workspace',
      hostname: 'owned-mac.local',
      ownerUserId: 'user-owner',
      installationId: 'install-owned',
    );
    await WorkspaceRegistrationStore(directory).write(registration);

    final config = WorkspaceConfig.fromArgs(
      ['--data-dir', directory.path],
      ignoreSavedRegistration: true,
    );

    expect(config.workspaceRuntimeId, isNull);
    expect(config.workspaceId, isNull);
    expect(config.authToken, isNull);
    // Keep the saved Cloud endpoint available for local Worker-catalog cache
    // loading without restoring runtime identity or reconnecting.
    expect(config.cloudUri, isNotNull);
    expect(WorkspaceRegistrationStore(directory).readSync()?.ownerUserId,
        'user-owner');
  });

  test('IPC snapshot projects registered disconnected Workspace state',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workspace-');
    await WorkspaceRegistrationStore(directory)
        .write(const WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-owned',
      workspaceId: 'workspace-owned',
      cloudUrl: 'https://cloud.example.test',
      name: 'Owned Workspace',
      hostname: 'owned-mac.local',
      ownerUserId: 'user-owner',
      installationId: 'install-owned',
    ));
    await WorkspaceLifecyclePreferencesStore(directory).write(
      const WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: false,
        managementLockPreference: ManagementLockState.unlocked,
        ownerUserId: 'user-owner',
      ),
    );
    final lifecycle = WorkspaceLifecycleController(
      WorkspaceConfig.fromArgs(['--data-dir', directory.path]),
      credentialStore: const PlatformSecureCredentialStore(),
      initialManagerSnapshot: {
        'service': {'processState': 'ready', 'installationId': 'install-owned'},
        'cloud': {'state': 'disconnected', 'connected': false},
        'workspace': {
          'workspaceId': 'workspace-owned',
          'workspaceRuntimeId': 'runtime-owned',
          'name': 'Owned Workspace',
          'cloudUrl': 'https://cloud.example.test',
        },
        'assignments': {'activeCount': 0, 'activeIds': <String>[]},
      },
    );

    final snapshot = lifecycle.uiSnapshot;
    expect(snapshot.registered, isTrue);
    expect(snapshot.ownerUserId, 'user-owner');
    expect(snapshot.workspaceName, 'Owned Workspace');
    expect(snapshot.desiredRuntimeConnected, isFalse);
    expect(snapshot.workspaceReady, isFalse);
    expect(snapshot.cloudConnected, isFalse);
    expect(lifecycle.running, isTrue);
    await lifecycle.quit();
    await directory.delete(recursive: true);
  });

  test('manager saves and displays Work Root while service is stopped',
      () async {
    final root = await Directory.systemTemp.createTemp('manager-work-root-');
    addTearDown(() => root.delete(recursive: true));
    final lifecycle = WorkspaceLifecycleController(
      WorkspaceConfig(dataDirectory: Directory('${root.path}/state')),
      credentialStore: const PlatformSecureCredentialStore(),
    );
    addTearDown(lifecycle.quit);
    await lifecycle.changeWorkRoot('${root.path}/work');
    expect(lifecycle.uiSnapshot.workRootPath,
        await Directory('${root.path}/work').resolveSymbolicLinks());
    expect(lifecycle.uiSnapshot.serviceRunning, isFalse);
  });

  test('running service protects Work Root even when Cloud is offline',
      () async {
    final root = await Directory.systemTemp.createTemp('running-work-root-');
    addTearDown(() => root.delete(recursive: true));
    final lifecycle = WorkspaceLifecycleController(
      WorkspaceConfig(dataDirectory: root),
      credentialStore: const PlatformSecureCredentialStore(),
      initialManagerSnapshot: {
        'service': {'processState': 'ready'},
        'cloud': {'connected': false},
      },
    );
    addTearDown(lifecycle.quit);
    await expectLater(lifecycle.changeWorkRoot('${root.path}/work'),
        throwsA(isA<StateError>()));
    expect(await Directory('${root.path}/work').exists(), isFalse);
  });

  test('stopped service cannot display a stale connected Cloud snapshot',
      () async {
    final directory = await Directory.systemTemp.createTemp('stopped-service-');
    addTearDown(() => directory.delete(recursive: true));
    final lifecycle = WorkspaceLifecycleController(
      WorkspaceConfig(dataDirectory: directory),
      credentialStore: const PlatformSecureCredentialStore(),
      initialManagerSnapshot: {
        'service': {'processState': 'stopped'},
        'cloud': {'state': 'connected', 'connected': true},
      },
    );
    addTearDown(lifecycle.quit);
    expect(lifecycle.uiSnapshot.serviceRunning, isFalse);
    expect(lifecycle.uiSnapshot.cloudConnected, isFalse);
    expect(
        lifecycle.uiSnapshot.connectionStage, WorkspaceConnectionStage.offline);
  });

  test('management UI reports service state from IPC without owning runtime',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-ipc-ui-');
    await WorkspaceRegistrationStore(directory)
        .write(const WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      cloudUrl: 'https://cloud.example.test',
      name: 'Development Mac',
      hostname: 'development-mac.local',
      installationId: 'install-ui-test',
    ));
    final lifecycle = WorkspaceLifecycleController(
      WorkspaceConfig.fromArgs(['--data-dir', directory.path]),
      credentialStore: const PlatformSecureCredentialStore(),
      initialManagerSnapshot: {
        'service': {'processState': 'ready'},
        'cloud': {
          'state': 'connected',
          'connected': true,
          'acceptingNewWork': true,
          'reconnectCount': 2,
        },
        'workspace': {
          'workspaceId': 'workspace-1',
          'workspaceRuntimeId': 'runtime-1',
          'name': 'Development Mac',
          'cloudUrl': 'https://cloud.example.test',
          'workRoot': '${directory.path}/Work',
        },
        'assignments': {
          'activeCount': 1,
          'activeIds': ['assignment-1'],
        },
      },
    );

    expect(lifecycle.uiSnapshot.mode, WorkspaceUiMode.active);
    expect(lifecycle.uiSnapshot.statusLabel, 'Connected');
    expect(lifecycle.uiSnapshot.activeAssignments, 1);
    expect(lifecycle.uiSnapshot.activeAssignmentIds, ['assignment-1']);
    expect(lifecycle.acceptingNewWork, isTrue);
    await lifecycle.quit();
    await directory.delete(recursive: true);
  });

  test('launch and quit only attach and detach the management client',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-ui-client-');
    final lifecycle = WorkspaceLifecycleController(
      WorkspaceConfig(dataDirectory: directory),
      credentialStore: const PlatformSecureCredentialStore(),
    );

    await lifecycle.launch();
    expect(lifecycle.running, isFalse,
        reason: 'the management UI must not start an in-process runtime');
    expect(
      File('${directory.path}/installation-unidentified.lock').existsSync(),
      isFalse,
    );
    lifecycle.minimize();
    expect(lifecycle.hidden, isTrue);
    lifecycle.restore();
    expect(lifecycle.hidden, isFalse);
    await lifecycle.quit();
    expect(lifecycle.quitting, isTrue);
    expect(lifecycle.running, isFalse);
    await directory.delete(recursive: true);
  });

  test('Workspace shutdown invokes the Worker process-tree shutdown hook',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-stop-');
    var shutdownCalls = 0;
    final workspace = Workspace(
      config: WorkspaceConfig(dataDirectory: directory),
      workerShutdownHandler: () async {
        shutdownCalls++;
      },
    );

    await workspace.start();
    await workspace.stop();
    await workspace.stop();

    expect(shutdownCalls, 1);
  });

  test('assignment journal recovers interrupted work after restart', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final now = DateTime.now().toUtc();
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: now,
      workspaceRuntimeId: 'workspace-1',
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.interrupted,
      updatedAt: now.add(const Duration(seconds: 1)),
      workspaceRuntimeId: 'workspace-1',
    ));

    final recovered = await AssignmentJournal(journal.file).reconcile();
    expect(recovered['assignment-1']?.status, AssignmentStatus.interrupted);
  });
}

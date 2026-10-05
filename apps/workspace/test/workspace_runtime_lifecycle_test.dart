import 'dart:io';
import 'dart:async';

import 'package:conclave_workspace/assignment_journal.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_lifecycle.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:conclave_workspace/workspace_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_workspace/main.dart';
import 'package:conclave_workspace/workspace_runtime.dart';

class _SilentWorkspaceSocket implements WorkspaceTransport {
  final _messages = StreamController<Object?>.broadcast();

  @override
  Stream<Object?> get messages => _messages.stream;

  @override
  void send(Object message) {}

  @override
  Future<void> close() => _messages.close();
}

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
    expect(WorkspaceRegistrationStore(directory).readSync()?.ownerUserId,
        'user-owner');
  });

  test('disconnected registration remains visible as owned but not connected',
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
    final workspace = Workspace(
      config: WorkspaceConfig.fromArgs(
        ['--data-dir', directory.path],
        ignoreSavedRegistration: true,
      ),
    );
    final snapshot = WorkspaceLifecycleController(workspace).uiSnapshot;

    expect(snapshot.registered, isTrue);
    expect(snapshot.ownerUserId, 'user-owner');
    expect(snapshot.desiredRuntimeConnected, isFalse);
    expect(snapshot.workspaceReady, isFalse);
    expect(snapshot.cloudConnected, isFalse);
  });

  test('connection failure keeps saved Workspace registration registered',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workspace-');
    const workspaceId = 'workspace-1';
    const runtimeId = 'runtime-1';
    await WorkspaceRegistrationStore(directory)
        .write(const WorkspaceRegistration(
      workspaceRuntimeId: runtimeId,
      workspaceId: workspaceId,
      cloudUrl: 'https://cloud.example.test',
      name: 'Development Mac',
      hostname: 'development-mac.local',
      installationId: 'install_12345678-1234-4234-8234-123456789abc',
    ));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.example.test/api/workspace-gateway/connect?workspaceRuntimeId=$runtimeId'),
      workspaceRuntimeId: runtimeId,
      workspaceId: workspaceId,
      // The platform's WebSocket error text is not stable across macOS/Linux
      // and may omit the HTTP status. Missing saved credentials are enough to
      // offer the explicit recovery action.
      factory: (_) async => throw const WebSocketException(
        'Connection failed',
      ),
    );
    final lifecycle = WorkspaceLifecycleController(
      Workspace(
        config: WorkspaceConfig(
          dataDirectory: directory,
          workspaceRuntimeId: runtimeId,
          workspaceId: workspaceId,
          authToken: 'revoked-runtime-token',
        ),
        cloudConnection: connection,
      ),
    );

    await expectLater(lifecycle.launch(), throwsA(isA<WebSocketException>()));
    expect(lifecycle.uiSnapshot.mode, WorkspaceUiMode.offline);
    expect(lifecycle.uiSnapshot.registered, isTrue);
    expect(lifecycle.uiSnapshot.workspaceName, 'Development Mac');

    await lifecycle.quit();
  });

  test('registered runtime without an authenticated session is shown offline',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workspace-');
    const workspaceId = 'workspace-2';
    const runtimeId = 'runtime-2';
    await WorkspaceRegistrationStore(directory)
        .write(const WorkspaceRegistration(
      workspaceRuntimeId: runtimeId,
      workspaceId: workspaceId,
      cloudUrl: 'https://cloud.example.test',
      name: 'Offline Mac',
      hostname: 'offline-mac.local',
      installationId: 'install_12345678-1234-4234-8234-123456789def',
    ));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.example.test/api/workspace-gateway/connect?workspaceRuntimeId=$runtimeId'),
      workspaceRuntimeId: runtimeId,
      workspaceId: workspaceId,
      factory: (_) async => _SilentWorkspaceSocket(),
    );
    final lifecycle = WorkspaceLifecycleController(
      Workspace(
        config: WorkspaceConfig(
          dataDirectory: directory,
          workspaceRuntimeId: runtimeId,
          workspaceId: workspaceId,
          authToken: 'possibly-revoked-token',
        ),
        cloudConnection: connection,
      ),
    );

    await lifecycle.launch();
    expect(connection.isConnected, isFalse);
    expect(lifecycle.uiSnapshot.mode, WorkspaceUiMode.starting);
    expect(lifecycle.uiSnapshot.statusLabel, 'Connecting');
    expect(lifecycle.uiSnapshot.cloudConnected, isFalse);
    await connection.close();
    expect(lifecycle.uiSnapshot.mode, WorkspaceUiMode.offline);
    expect(lifecycle.uiSnapshot.statusLabel, 'Offline');
    await lifecycle.quit();
  });

  test('Workspace launches, minimizes/restores, and quits cleanly', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-workspace-');
    final lifecycle = WorkspaceLifecycleController(
      Workspace(config: WorkspaceConfig(dataDirectory: directory)),
    );

    await lifecycle.launch();
    expect(lifecycle.running, isTrue);
    lifecycle.minimize();
    expect(lifecycle.hidden, isTrue);
    expect(lifecycle.running, isTrue,
        reason: 'hiding the window must leave the runtime alive');
    lifecycle.restore();
    expect(lifecycle.hidden, isFalse);
    expect(lifecycle.running, isTrue);
    await lifecycle.quit();
    expect(lifecycle.quitting, isTrue);
    expect(lifecycle.running, isFalse);
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

  test('pause and resume affect assignment intake, not runtime lifecycle',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-pause-');
    final registration = const WorkspaceRegistration(
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      cloudUrl: 'https://cloud.example.test',
      name: 'Test Workspace',
      hostname: 'test-machine',
      ownerUserId: 'owner-1',
      installationId: 'installation-1',
    );
    await WorkspaceRegistrationStore(directory).write(registration);
    await WorkspaceLifecyclePreferencesStore(directory).write(
      const WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.connected,
        launchAtLogin: false,
        managementLockPreference: ManagementLockState.unlocked,
      ),
    );
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.example.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => _SilentWorkspaceSocket(),
    );
    final lifecycle = WorkspaceLifecycleController(Workspace(
      config: WorkspaceConfig(
        dataDirectory: directory,
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        authToken: 'runtime-credential',
      ),
      cloudConnection: connection,
    ));

    await lifecycle.handleDesktopAction('pause');
    expect(connection.acceptingNewWork, isFalse);
    expect(connection.isDraining, isFalse);
    expect(lifecycle.quitting, isFalse);
    expect(
      WorkspaceLifecyclePreferencesStore(directory).readSync().desiredRuntime,
      DesiredRuntimeState.connected,
    );

    await lifecycle.handleDesktopAction('resume');
    expect(connection.acceptingNewWork, isTrue);
    await lifecycle.quit();
  });

  test('quit drain waits for work and restores intake if the timeout expires',
      () async {
    var now = DateTime.utc(2026, 9, 27);
    var active = 2;
    var drainStarted = false;
    var restored = false;
    final drained = await drainWorkspaceAssignments(
      activeAssignmentCount: () => active,
      beginDrain: () => drainStarted = true,
      restoreNewWorkState: () => restored = true,
      timeout: const Duration(seconds: 3),
      pollInterval: const Duration(seconds: 1),
      now: () => now,
      wait: (duration) async {
        now = now.add(duration);
        active--;
      },
    );
    expect(drained, isTrue);
    expect(drainStarted, isTrue);
    expect(restored, isFalse);

    now = DateTime.utc(2026, 9, 27);
    active = 1;
    restored = false;
    final timedOut = await drainWorkspaceAssignments(
      activeAssignmentCount: () => active,
      beginDrain: () {},
      restoreNewWorkState: () => restored = true,
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(seconds: 1),
      now: () => now,
      wait: (duration) async => now = now.add(duration),
    );
    expect(timedOut, isFalse);
    expect(restored, isTrue);
    expect(active, 1);
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

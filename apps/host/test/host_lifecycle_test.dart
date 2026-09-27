import 'dart:io';
import 'dart:async';

import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/host.dart';
import 'package:conclave_host/host_configuration.dart';
import 'package:conclave_host/workspace_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/main.dart';

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
  test('connection failure keeps saved Workspace registration paired',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-host-');
    const workspaceId = 'workspace-1';
    const runtimeId = 'runtime-1';
    await HostRegistrationStore(directory).write(const HostRegistration(
      hostId: runtimeId,
      workspaceId: workspaceId,
      cloudUrl: 'https://cloud.example.test',
      name: 'Development Mac',
      hostname: 'development-mac.local',
      credentialRef: 'workspace-runtime:runtime-1',
    ));
    final connection = HostCloudConnection(
      uri: Uri.parse(
          'wss://cloud.example.test/api/workspace-gateway/connect?workspaceRuntimeId=$runtimeId'),
      hostId: runtimeId,
      workspaceId: workspaceId,
      // The platform's WebSocket error text is not stable across macOS/Linux
      // and may omit the HTTP status. Missing saved credentials are enough to
      // offer the explicit recovery action.
      factory: (_) async => throw const WebSocketException(
        'Connection failed',
      ),
    );
    final lifecycle = HostLifecycleController(
      Host(
        config: HostConfig(
          dataDirectory: directory,
          hostId: runtimeId,
          workspaceId: workspaceId,
          authToken: 'revoked-runtime-token',
        ),
        cloudConnection: connection,
      ),
    );

    await expectLater(lifecycle.launch(), throwsA(isA<WebSocketException>()));
    expect(lifecycle.uiSnapshot.mode, HostUiMode.offline);
    expect(lifecycle.uiSnapshot.paired, isTrue);
    expect(lifecycle.uiSnapshot.workspaceName, 'Development Mac');

    await lifecycle.quit();
  });

  test('paired runtime without an authenticated session is shown offline',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-host-');
    const workspaceId = 'workspace-2';
    const runtimeId = 'runtime-2';
    await HostRegistrationStore(directory).write(const HostRegistration(
      hostId: runtimeId,
      workspaceId: workspaceId,
      cloudUrl: 'https://cloud.example.test',
      name: 'Offline Mac',
      hostname: 'offline-mac.local',
      credentialRef: 'workspace-runtime:runtime-2',
    ));
    final connection = HostCloudConnection(
      uri: Uri.parse(
          'wss://cloud.example.test/api/workspace-gateway/connect?workspaceRuntimeId=$runtimeId'),
      hostId: runtimeId,
      workspaceId: workspaceId,
      factory: (_) async => _SilentWorkspaceSocket(),
    );
    final lifecycle = HostLifecycleController(
      Host(
        config: HostConfig(
          dataDirectory: directory,
          hostId: runtimeId,
          workspaceId: workspaceId,
          authToken: 'possibly-revoked-token',
        ),
        cloudConnection: connection,
      ),
    );

    await lifecycle.launch();
    expect(connection.isConnected, isFalse);
    expect(lifecycle.uiSnapshot.mode, HostUiMode.offline);
    expect(lifecycle.uiSnapshot.statusLabel, 'Offline');
    expect(lifecycle.uiSnapshot.cloudConnected, isFalse);
    await lifecycle.quit();
  });

  test('Host launches, minimizes/restores, and quits cleanly', () async {
    final directory = await Directory.systemTemp.createTemp('conclave-host-');
    final lifecycle = HostLifecycleController(
      Host(config: HostConfig(dataDirectory: directory)),
    );

    await lifecycle.launch();
    expect(lifecycle.running, isTrue);
    lifecycle.minimize();
    expect(lifecycle.hidden, isTrue);
    lifecycle.restore();
    expect(lifecycle.hidden, isFalse);
    await lifecycle.quit();
    expect(lifecycle.quitting, isTrue);
    expect(lifecycle.running, isFalse);
  });

  test('assignment journal recovers interrupted work after restart', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-host-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final now = DateTime.now().toUtc();
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: now,
      hostId: 'host-1',
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.interrupted,
      updatedAt: now.add(const Duration(seconds: 1)),
      hostId: 'host-1',
    ));

    final recovered = await AssignmentJournal(journal.file).reconcile();
    expect(recovered['assignment-1']?.status, AssignmentStatus.interrupted);
  });
}

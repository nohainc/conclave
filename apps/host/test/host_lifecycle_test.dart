import 'dart:io';

import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/host.dart';
import 'package:conclave_host/host_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/main.dart';

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
      factory: (_) async => throw const WebSocketException(
        'HTTP status code: 401',
      ),
    );
    final lifecycle = HostLifecycleController(
      Host(
        config: HostConfig(
          dataDirectory: directory,
          hostId: runtimeId,
          workspaceId: workspaceId,
        ),
        cloudConnection: connection,
      ),
    );

    await expectLater(lifecycle.launch(), throwsA(isA<WebSocketException>()));
    expect(lifecycle.uiSnapshot.mode, HostUiMode.offline);
    expect(lifecycle.uiSnapshot.paired, isTrue);
    expect(lifecycle.uiSnapshot.canRecoverPairing, isTrue);
    expect(lifecycle.uiSnapshot.workspaceName, 'Development Mac');

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

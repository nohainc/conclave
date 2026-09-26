import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/worker_protocol.dart';
import 'package:test/test.dart';
import 'fixture_copy.dart';

class FakeSocket implements HostCloudSocket {
  final controller = StreamController<Object?>();
  final sent = <Object>[];

  @override
  Stream<Object?> get messages => controller.stream;

  @override
  void send(Object message) => sent.add(message);

  @override
  Future<void> close() => controller.close();
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('connects outbound and sends hello', () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    expect(hello['protocol'], 'conclave.host-protocol');
    expect(hello['protocolVersion'], '4.0');
    expect(hello['type'], 'host.hello');
    final payload = hello['payload'] as Map<String, dynamic>;
    expect(payload['hostId'], 'host-1');
    expect(payload['workspaceId'], 'workspace-1');
    expect(payload['capabilities'], isA<Map<String, dynamic>>());
    await connection.close();
  });

  test('reports Workstream readiness without a local path', () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace-gateway'),
      hostId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-hello-ack',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await waitFor(() => connection.isConnected);

    connection.reportWorkstreamStatus(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      workingDirectoryState: 'ready',
    );
    final status = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workstream.status');
    final payload = status['payload'] as Map<String, dynamic>;
    expect(payload['projectId'], 'project-1');
    expect(payload['workstreamId'], 'workstream-1');
    expect(payload.containsKey('path'), isFalse);
    expect(payload.containsKey('relativePath'), isFalse);
    await connection.close();
  });

  test('uses the Gateway session for protocol heartbeats', () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(milliseconds: 10),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'correlationId': 'client-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {
        'sessionId': 'session-1',
        'heartbeatIntervalMs': 1000,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
        'serverVersion': '2.0.0',
        'activeWorkspaceBindings': ['workspace-1', 'workspace-2'],
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final heartbeats = socket.sent
        .skip(1)
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'host.heartbeat')
        .toList();
    expect(heartbeats, isNotEmpty);
    expect(
      (heartbeats.first['payload'] as Map<String, dynamic>)['sessionId'],
      'session-1',
    );
    expect(connection.authorizedWorkspaceIds, contains('workspace-2'));
    final sync = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'host.sync.request');
    expect(
      (sync['payload'] as Map<String, dynamic>)['hostId'],
      'host-1',
    );
    await connection.close();
  });

  test('accepts a compatible newer minor protocol version', () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(connection.isConnected, isTrue);
    await connection.close();
  });

  test('delivers validated Cloud update announcements to the Host', () async {
    final socket = FakeSocket();
    Map<String, Object?>? received;
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      hostUpdateAvailableHandler: (payload) async {
        received = payload;
      },
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-update-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.update',
      'payload': {
        'version': '0.2.0',
        'channel': 'stable',
        'packageR2Key': 'hosts/0.2.0/macos-arm64.tar.gz',
        'packageDigest': 'sha256:abc123',
        'signature': 'sig-1',
        'releaseNotes': 'Security fixes',
        'minSupportedHostVersion': '0.1.0',
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(received?['version'], '0.2.0');
    expect(received?['packageR2Key'], 'hosts/0.2.0/macos-arm64.tar.gz');
    await connection.close();
  });

  test('ignores an incompatible protocol major version', () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '3.0',
      'messageId': 'server-incompatible',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {'sessionId': 'should-not-be-accepted'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(connection.sessionId, isNull);
    expect(
      socket.sent.where((message) =>
          (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
          'host.sync.request'),
      isEmpty,
    );
    await connection.close();
  });

  test('reports Workspace-owned Worker inventory over runtime protocol',
      () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connection.reportWorkerInventory([
      {
        'workerId': 'worker-1',
        'workerTypeId': 'codex',
        'status': 'ready',
        'revision': 2,
      },
    ]);
    final messages = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .toList();
    final inventory = messages.firstWhere(
      (message) => message['type'] == 'worker.inventory',
    );
    final payload = inventory['payload'] as Map<String, dynamic>;
    expect(payload['fullSnapshot'], isTrue);
    expect((payload['workers'] as List).single['workerId'], 'worker-1');
    expect(jsonEncode(payload), isNot(contains('credentialRef')));
    await connection.close();
  });

  test('forwards Worker progress with trusted correlation and redacted output',
      () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    const context = HostAssignmentContext(
      workspaceId: 'workspace-1',
      hostId: 'host-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-1',
      idempotencyKey: 'idem-1',
      payload: {},
    );
    connection.reportWorkerNotification(
      context,
      const WorkerRpcNotification(
        method: 'output_delta',
        params: {
          'assignmentId': 'assignment-1',
          'delta': '[REDACTED]',
          'timestamp': '2026-09-23T00:00:00Z',
        },
      ),
    );
    connection.reportWorkerNotification(
      context,
      const WorkerRpcNotification(
        method: 'progress',
        params: {
          'assignmentId': 'forged-assignment',
          'percentage': 20,
          'timestamp': '2026-09-23T00:00:00Z',
        },
      ),
    );
    final messages = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'assignment.progress')
        .toList();
    expect(messages, hasLength(1));
    expect(messages.single['assignmentId'], 'assignment-1');
    expect(
      (messages.single['payload'] as Map<String, dynamic>)['message'],
      '[REDACTED]',
    );
    await connection.close();
  });

  test('reconnects when Gateway heartbeat acknowledgements stop', () async {
    var socketCount = 0;
    final sockets = <FakeSocket>[];
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async {
        final socket = FakeSocket();
        sockets.add(socket);
        socketCount += 1;
        return socket;
      },
      heartbeat: const Duration(milliseconds: 10),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 5),
    );

    await connection.connect();
    sockets.first.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-ack',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(socketCount, greaterThan(1));
    expect(connection.reconnectCount, greaterThan(0));
    await connection.close();
  });

  test('includes recovered non-terminal assignments in sync', () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('host-sync-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'recovered-running',
      status: AssignmentStatus.running,
      updatedAt: DateTime.now().toUtc(),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'already-completed',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.now().toUtc(),
    ));
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final sync = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'host.sync.request');
    expect(
      (sync['payload'] as Map<String, dynamic>)['unreconciledAssignmentIds'],
      ['already-completed', 'recovered-running'],
    );
    await connection.close();
  });

  test('executes correlated assignments through the injected handler',
      () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('host-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        expect(context.runId, 'run-1');
        expect(context.taskId, 'task-1');
        return const HostAssignmentResult(summary: 'completed by host');
      },
      assignmentJournal: journal,
    );
    await connection.connect();

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-assignment-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'hostId': 'host-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'conclave.echo',
        'resolvedWorkerVersion': '1.0.0',
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.result';
        }));

    final messages = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .toList();
    expect(
        messages.any((message) => message['type'] == 'assignment.ack'), isTrue);
    final result = messages.firstWhere(
      (message) => message['type'] == 'assignment.result',
    );
    expect(result['assignmentId'], 'assignment-1');
    expect((result['payload'] as Map<String, dynamic>)['summary'],
        'completed by host');
    final records = await journal.reconcile();
    expect(records['assignment-1']!.status, AssignmentStatus.completed);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('allows stateful Work without checkout provisioning', () async {
    final socket = FakeSocket();
    var executed = false;
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        executed = true;
        expect(context.payload['projectId'], 'project-1');
        expect(context.payload['workstreamId'], 'workstream-1');
        return const HostAssignmentResult(summary: 'empty directory work');
      },
    );
    await connection.connect();

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-empty-work-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'hostId': 'host-1',
      'workerId': 'worker-1',
      'runId': 'run-empty-1',
      'taskId': 'task-empty-1',
      'attemptId': 'attempt-empty-1',
      'assignmentId': 'assignment-empty-1',
      'idempotencyKey': 'idem-empty-1',
      'payload': {
        'objective': 'work without a repository',
        'role': 'implementer',
        'workerId': 'worker-1',
        'resolvedWorkerVersion': '1.0.0',
        'projectId': 'project-1',
        'workstreamId': 'workstream-1',
        'executionClass': 'stateful_workstream',
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.result';
        }));

    expect(executed, isTrue);
    await connection.close();
  });

  test('replays a terminal journal result when Cloud still has it active',
      () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('host-replay-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.now().toUtc(),
      workspaceId: 'workspace-1',
      hostId: 'host-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      idempotencyKey: 'idem-1',
      result: {'summary': 'recovered', 'artifactIds': <String>[]},
    ));
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-sync-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'host.sync.result',
      'payload': {
        'desiredWorkers': [],
        'activeAssignmentIds': ['assignment-1'],
        'assignmentStates': [
          {
            'assignmentId': 'assignment-1',
            'attemptId': 'attempt-1',
            'idempotencyKey': 'idem-1',
            'status': 'running',
          },
        ],
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final replay = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.result');
    expect((replay['payload'] as Map<String, dynamic>)['summary'], 'recovered');
    expect(
      (await journal.reconcile())['assignment-1']!.status,
      AssignmentStatus.reconciled,
    );
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('rejects assignments addressed to another workspace', () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-assignment-2',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-2',
      'hostId': 'host-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-2',
      'idempotencyKey': 'idem-2',
      'payload': {},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    expect((error['payload'] as Map<String, dynamic>)['error']['code'],
        'assignment_context_mismatch');
    await connection.close();
  });

  test('rejects malformed assignment payloads before worker execution',
      () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        fail('malformed assignment reached the handler');
      },
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-assignment-3',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'hostId': 'host-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-3',
      'idempotencyKey': 'idem-3',
      'payload': {'workerId': 'conclave.echo'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    expect((error['payload'] as Map<String, dynamic>)['error']['code'],
        'malformed_assignment');
    await connection.close();
  });

  test('replays a completed assignment without rerunning the handler',
      () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('host-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    var executions = 0;
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentHandler: (_) async {
        executions += 1;
        return const HostAssignmentResult(summary: 'once');
      },
    );
    await connection.connect();

    Map<String, Object?> assignment() => {
          'protocol': 'conclave.host-protocol',
          'protocolVersion': '4.1',
          'messageId': 'server-replay-${executions + 1}',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'workspaceId': 'workspace-1',
          'hostId': 'host-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'assignmentId': 'assignment-replay',
          'idempotencyKey': 'idem-replay',
          'payload': {
            'objective': 'inspect',
            'role': 'research',
            'workerId': 'conclave.echo',
            'resolvedWorkerVersion': '1.0.0',
            'input': {},
            'contextArtifactIds': [],
            'timeoutMs': 1000,
          },
        };

    socket.controller.add(jsonEncode(assignment()));
    await waitFor(() => executions == 1);
    await waitFor(() =>
        socket.sent
            .where((message) =>
                (jsonDecode(message as String)
                    as Map<String, dynamic>)['type'] ==
                'assignment.result')
            .length ==
        1);
    socket.controller.add(jsonEncode(assignment()));
    await waitFor(() =>
        socket.sent
            .where((message) =>
                (jsonDecode(message as String)
                    as Map<String, dynamic>)['type'] ==
                'assignment.result')
            .length ==
        2);

    expect(executions, 1);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('does not rerun a non-terminal assignment on duplicate delivery',
      () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('host-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final release = Completer<void>();
    var executions = 0;
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentHandler: (_) async {
        executions += 1;
        await release.future;
        return const HostAssignmentResult(summary: 'once');
      },
    );
    await connection.connect();

    final assignment = <String, Object?>{
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-running-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'hostId': 'host-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-running',
      'idempotencyKey': 'idem-running',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'conclave.echo',
        'resolvedWorkerVersion': '1.0.0',
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    };
    socket.controller.add(jsonEncode(assignment));
    await waitFor(() => executions == 1);
    socket.controller
        .add(jsonEncode({...assignment, 'messageId': 'server-running-2'}));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.ack' &&
              (decoded['payload'] as Map<String, dynamic>)['accepted'] == false;
        }));

    expect(executions, 1);
    final duplicateAck = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) =>
            message['type'] == 'assignment.ack' &&
            (message['payload'] as Map<String, dynamic>)['accepted'] == false);
    expect((duplicateAck['payload'] as Map<String, dynamic>)['reason'],
        contains('already exists'));
    release.complete();
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.result';
        }));
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('acknowledges cancellation for an already completed assignment',
      () async {
    final socket = FakeSocket();
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.host-protocol',
      'protocolVersion': '4.1',
      'messageId': 'cancel-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.cancel',
      'workspaceId': 'workspace-1',
      'hostId': 'host-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-done',
      'idempotencyKey': 'idem-done',
      'payload': {'reason': 'user cancelled', 'gracePeriodMs': 1000},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ack = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.cancel.ack');
    expect((ack['payload'] as Map<String, dynamic>)['cancelled'], isFalse);
    expect(
        (ack['payload'] as Map<String, dynamic>)['alreadyTerminated'], isTrue);
    await connection.close();
  });

  test('runs Forge through Cloud assignment, worker, and journal boundaries',
      () async {
    final repository = Directory.current.parent.parent;
    final fixture = await copyForgeFixture();
    final socket = FakeSocket();
    final journalDirectory =
        await Directory.systemTemp.createTemp('host-journal-');
    final journal =
        AssignmentJournal(File('${journalDirectory.path}/assignments.jsonl'));
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) => WorkerProcessSpec(
        workerId: 'conclave.forge',
        executable: 'dart',
        arguments: ['--disable-analytics', 'run', 'bin/forge_worker.dart'],
        workingDirectory: '${repository.path}/workers/forge',
      ),
    );
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: handler.call,
      assignmentJournal: journal,
    );
    await connection.connect();
    try {
      socket.controller.add(jsonEncode({
        'protocol': 'conclave.host-protocol',
        'protocolVersion': '4.1',
        'messageId': 'forge-assignment-1',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'assignment.start',
        'workspaceId': 'workspace-1',
        'hostId': 'host-1',
        'workerId': 'forge-worker',
        'runId': 'run-forge-1',
        'taskId': 'task-forge-1',
        'attemptId': 'attempt-forge-1',
        'assignmentId': 'assignment-forge-1',
        'idempotencyKey': 'idem-forge-1',
        'payload': {
          'objective': 'Fix add and verify the implementation',
          'role': 'implementer',
          'workerId': 'conclave.forge',
          'resolvedWorkerVersion': '0.1.0',
          'input': {'repositoryPath': fixture.path},
          'contextArtifactIds': [],
          'timeoutMs': 60000,
        },
      }));
      Map<String, dynamic>? result;
      Map<String, dynamic>? assignmentError;
      for (var attempt = 0; attempt < 120 && result == null; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        for (final message in socket.sent) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          if (decoded['type'] == 'assignment.result') result = decoded;
          if (decoded['type'] == 'assignment.error') assignmentError = decoded;
        }
        if (assignmentError != null) break;
      }
      expect(assignmentError, isNull,
          reason: assignmentError == null ? null : jsonEncode(assignmentError));
      expect(result, isNotNull);
      final completedResult = result!;
      final payload = completedResult['payload'] as Map<String, dynamic>;
      expect(payload['status'], 'completed');
      final output = payload['output'] as Map<String, dynamic>;
      expect(output['accepted'], isTrue);
      expect(output['input'], {'repositoryPath': fixture.path});
      final machineTests = await Process.run(
        'node',
        ['--test'],
        workingDirectory: fixture.path,
      );
      expect(machineTests.exitCode, 0,
          reason: '${machineTests.stdout}\n${machineTests.stderr}');
      expect((await journal.reconcile())['assignment-forge-1']!.status,
          AssignmentStatus.completed);
    } finally {
      await connection.close();
      await fixture.parent.delete(recursive: true);
      await journalDirectory.delete(recursive: true);
    }
  });

  test('reconnects after a dropped socket', () async {
    final sockets = <FakeSocket>[FakeSocket(), FakeSocket()];
    final first = sockets.first;
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async => sockets.removeAt(0),
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    await first.controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(connection.reconnectCount, 1);
    await connection.close();
  });

  test('retries a failed reconnect with backoff', () async {
    final first = FakeSocket();
    final recovered = FakeSocket();
    var factoryCalls = 0;
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/host'),
      hostId: 'host-1',
      workspaceId: 'workspace-1',
      factory: (_) async {
        factoryCalls += 1;
        if (factoryCalls == 2) throw const SocketException('temporary loss');
        return factoryCalls == 1 ? first : recovered;
      },
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      reconnectMaxDelay: const Duration(milliseconds: 20),
    );
    await connection.connect();
    await first.controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(factoryCalls, greaterThanOrEqualTo(3));
    expect(connection.reconnectCount, greaterThanOrEqualTo(2));
    await connection.close();
  });

  test('applies Cloud cancellation delivered on the reconnected socket',
      () async {
    final first = FakeSocket();
    final recovered = FakeSocket();
    final cancelled = Completer<String>();
    var factoryCalls = 0;
    final connection = HostCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace-gateway'),
      hostId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => ++factoryCalls == 1 ? first : recovered,
      assignmentCancellationHandler: (assignmentId, reason) async {
        cancelled.complete('$assignmentId:$reason');
        return true;
      },
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 5),
    );
    await connection.connect();
    await first.controller.close();
    await waitFor(() => connection.reconnectCount > 0);
    recovered.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cancel-after-reconnect',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.cancel',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
      'assignmentId': 'assignment-still-running',
      'payload': {'reason': 'cancelled after reconnect', 'gracePeriodMs': 100},
    }));
    expect(await cancelled.future.timeout(const Duration(seconds: 2)),
        'assignment-still-running:cancelled after reconnect');
    await waitFor(() => recovered.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
            'assignment.cancel.ack'));
    await connection.close();
  });
}

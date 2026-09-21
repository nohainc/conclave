import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_agent_engine/assignment_journal.dart';
import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:test/test.dart';

class FakeSocket implements AgentCloudSocket {
  final controller = StreamController<Object?>();
  final sent = <Object>[];

  @override
  Stream<Object?> get messages => controller.stream;

  @override
  void send(Object message) => sent.add(message);

  @override
  Future<void> close() => controller.close();
}

void main() {
  test('connects outbound and sends hello', () async {
    final socket = FakeSocket();
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    expect(hello['protocol'], 'conclave.agent-protocol');
    expect(hello['protocolVersion'], '2.0');
    expect(hello['type'], 'agent.hello');
    final payload = hello['payload'] as Map<String, dynamic>;
    expect(payload['agentId'], 'agent-1');
    expect(payload['workspaceId'], 'workspace-1');
    expect(payload['capabilities'], isA<Map<String, dynamic>>());
    await connection.close();
  });

  test('uses the Gateway session for protocol heartbeats', () async {
    final socket = FakeSocket();
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(milliseconds: 10),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.agent-protocol',
      'protocolVersion': '2.0',
      'messageId': 'server-1',
      'correlationId': 'client-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'agent.hello.ack',
      'payload': {
        'sessionId': 'session-1',
        'heartbeatIntervalMs': 1000,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
        'serverVersion': '2.0.0',
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final heartbeats = socket.sent
        .skip(1)
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'agent.heartbeat')
        .toList();
    expect(heartbeats, isNotEmpty);
    expect(
      (heartbeats.first['payload'] as Map<String, dynamic>)['sessionId'],
      'session-1',
    );
    final sync = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'agent.sync.request');
    expect(
      (sync['payload'] as Map<String, dynamic>)['agentId'],
      'agent-1',
    );
    await connection.close();
  });

  test('executes correlated assignments through the injected handler',
      () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('agent-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        expect(context.runId, 'run-1');
        expect(context.taskId, 'task-1');
        return const AgentAssignmentResult(summary: 'completed by agent');
      },
      assignmentJournal: journal,
    );
    await connection.connect();

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.agent-protocol',
      'protocolVersion': '2.0',
      'messageId': 'server-assignment-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'agentId': 'agent-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'pluginId': 'conclave.echo',
        'resolvedPluginVersion': '1.0.0',
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

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
        'completed by agent');
    final records = await journal.reconcile();
    expect(records['assignment-1']!.status, AssignmentStatus.completed);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('rejects assignments addressed to another workspace', () async {
    final socket = FakeSocket();
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.agent-protocol',
      'protocolVersion': '2.0',
      'messageId': 'server-assignment-2',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-2',
      'agentId': 'agent-1',
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

  test('rejects malformed assignment payloads before plugin execution',
      () async {
    final socket = FakeSocket();
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        fail('malformed assignment reached the handler');
      },
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.agent-protocol',
      'protocolVersion': '2.0',
      'messageId': 'server-assignment-3',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'agentId': 'agent-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-3',
      'idempotencyKey': 'idem-3',
      'payload': {'pluginId': 'conclave.echo'},
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
    final directory = await Directory.systemTemp.createTemp('agent-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    var executions = 0;
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentHandler: (_) async {
        executions += 1;
        return const AgentAssignmentResult(summary: 'once');
      },
    );
    await connection.connect();

    Map<String, Object?> assignment() => {
          'protocol': 'conclave.agent-protocol',
          'protocolVersion': '2.0',
          'messageId': 'server-replay-${executions + 1}',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'workspaceId': 'workspace-1',
          'agentId': 'agent-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'assignmentId': 'assignment-replay',
          'idempotencyKey': 'idem-replay',
          'payload': {
            'objective': 'inspect',
            'role': 'research',
            'pluginId': 'conclave.echo',
            'resolvedPluginVersion': '1.0.0',
            'input': {},
            'contextArtifactIds': [],
            'timeoutMs': 1000,
          },
        };

    socket.controller.add(jsonEncode(assignment()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    socket.controller.add(jsonEncode(assignment()));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(executions, 1);
    expect(
      socket.sent
          .where((message) =>
              (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
              'assignment.result')
          .length,
      2,
    );
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('reconnects after a dropped socket', () async {
    final sockets = <FakeSocket>[FakeSocket(), FakeSocket()];
    final first = sockets.first;
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
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
}

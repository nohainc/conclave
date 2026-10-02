import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/assignment_journal.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_workspace/workspace_transport.dart';
import 'package:test/test.dart';

class FakeSocket implements WorkspaceTransport {
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

Future<void> completeHandshake(
  WorkspaceCloudConnection connection,
  FakeSocket socket, {
  String sessionId = 'test-session',
}) async {
  Map<String, dynamic> sentMessage(String type) => socket.sent
      .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
      .firstWhere((message) => message['type'] == type);

  final legacy = connection.uri.path.contains('/workspace') &&
      !connection.uri.path.contains('workspace-gateway');
  final protocol = legacy
      ? 'conclave.workspace-runtime-protocol'
      : 'conclave.workspace-runtime-protocol';
  final version = legacy ? '4.1' : workspaceRuntimeProtocolVersion;
  final helloType = legacy ? 'workspace.hello' : 'workspace.hello';
  await waitFor(() => socket.sent.any((message) =>
      (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
      helloType));
  final hello = sentMessage(helloType);
  socket.controller.add(jsonEncode({
    'protocol': protocol,
    'protocolVersion': version,
    'messageId': 'test-hello-ack',
    if (!legacy) 'correlationId': hello['messageId'],
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'type': legacy ? 'workspace.hello.ack' : 'workspace.hello.ack',
    if (legacy) 'workspaceRuntimeId': connection.workspaceRuntimeId,
    if (legacy) 'workspaceId': connection.workspaceId,
    if (!legacy) 'workspaceRuntimeId': connection.workspaceRuntimeId,
    if (!legacy) 'executionWorkspaceId': connection.workspaceId,
    'payload': {'sessionId': sessionId},
  }));

  final syncType = legacy ? 'workspace.sync.request' : 'workspace.sync.request';
  await waitFor(() => socket.sent.any((message) =>
      (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
      syncType));
  final sync = sentMessage(syncType);
  socket.controller.add(jsonEncode({
    'protocol': protocol,
    'protocolVersion': version,
    'messageId': 'test-sync-result',
    if (!legacy) 'correlationId': sync['messageId'],
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'type': legacy ? 'workspace.sync.response' : 'workspace.sync.result',
    if (legacy) 'workspaceRuntimeId': connection.workspaceRuntimeId,
    if (legacy) 'workspaceId': connection.workspaceId,
    if (!legacy) 'workspaceRuntimeId': connection.workspaceRuntimeId,
    if (!legacy) 'executionWorkspaceId': connection.workspaceId,
    'payload': {'assignmentStates': []},
  }));
  await waitFor(
      () => connection.connectionStage == WorkspaceConnectionStage.ready);
}

void main() {
  test('connects outbound and sends hello', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    expect(hello['protocol'], 'conclave.workspace-runtime-protocol');
    expect(hello['protocolVersion'], '4.0');
    expect(hello['type'], 'workspace.hello');
    final payload = hello['payload'] as Map<String, dynamic>;
    expect(payload['workspaceRuntimeId'], 'workspace-1');
    expect(payload['workspaceId'], 'workspace-1');
    expect(payload['capabilities'], isA<Map<String, dynamic>>());
    await connection.close();
  });

  test('hands fallback back to WSS only after sync reconciliation', () async {
    final fallback = FakeSocket();
    final recovered = FakeSocket();
    var socketAttempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-handover'),
      workspaceRuntimeId: 'runtime-handover',
      workspaceId: 'workspace-handover',
      factory: (_) async {
        socketAttempts++;
        if (socketAttempts <= 2) throw const SocketException('offline');
        return recovered;
      },
      fallbackFactory: (_) async => fallback,
      workerInventoryProvider: () async => const [],
      heartbeat: const Duration(hours: 1),
      webSocketFailureLimit: 2,
      webSocketProbeInterval: const Duration(milliseconds: 20),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 2),
    );

    Future<void> acknowledge(FakeSocket socket, String id) async {
      final messages = socket.sent
          .map((item) => jsonDecode(item as String) as Map<String, dynamic>);
      final hello =
          messages.firstWhere((item) => item['type'] == 'workspace.hello');
      socket.controller.add(jsonEncode({
        'protocol': 'conclave.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': '$id-hello-ack',
        'correlationId': hello['messageId'],
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.hello.ack',
        'workspaceRuntimeId': 'runtime-handover',
        'executionWorkspaceId': 'workspace-handover',
        'payload': {'sessionId': '$id-session'},
      }));
      await waitFor(() => socket.sent.any((item) =>
          (jsonDecode(item as String) as Map<String, dynamic>)['type'] ==
          'workspace.sync.request'));
      final sync = socket.sent
          .map((item) => jsonDecode(item as String) as Map<String, dynamic>)
          .firstWhere((item) => item['type'] == 'workspace.sync.request');
      socket.controller.add(jsonEncode({
        'protocol': 'conclave.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': '$id-sync-result',
        'correlationId': sync['messageId'],
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.sync.result',
        'workspaceRuntimeId': 'runtime-handover',
        'executionWorkspaceId': 'workspace-handover',
        'payload': {'assignmentStates': []},
      }));
      await waitFor(
          () => connection.connectionStage == WorkspaceConnectionStage.ready);
    }

    await connection.connect();
    expect(connection.activeTransportMode, 'http_long_poll');
    await acknowledge(fallback, 'fallback');
    await waitFor(() => socketAttempts == 3);
    expect(fallback.controller.isClosed, isTrue);
    await waitFor(
        () => connection.activeTransportMode == 'switching_to_websocket');
    expect(connection.connectionStage, WorkspaceConnectionStage.authenticating);
    await acknowledge(recovered, 'recovered');
    expect(connection.activeTransportMode, 'websocket');
    await connection.close();
  });

  test('reports Workstream readiness without a local path', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-hello-ack',
      'correlationId': hello['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'workspaceRuntimeId': 'runtime-1',
      'executionWorkspaceId': 'workspace-1',
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

  test('tracks authentication and synchronization stages before Ready',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-stage'),
      workspaceRuntimeId: 'runtime-stage',
      workspaceId: 'workspace-stage',
      factory: (_) async => socket,
      workerInventoryProvider: () async => const [],
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    expect(connection.connectionStage, WorkspaceConnectionStage.authenticating);
    expect(connection.isConnected, isFalse);
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'stage-hello-ack',
      'correlationId': hello['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'workspaceRuntimeId': 'runtime-stage',
      'executionWorkspaceId': 'workspace-stage',
      'payload': {'sessionId': 'session-stage'},
    }));
    await waitFor(() =>
        connection.connectionStage == WorkspaceConnectionStage.synchronizing);
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'worker.inventory'));
    expect(connection.isConnected, isTrue);
    final syncRequest = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.sync.request');

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'stage-sync-result',
      'correlationId': syncRequest['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.sync.result',
      'workspaceRuntimeId': 'runtime-stage',
      'executionWorkspaceId': 'workspace-stage',
      'payload': {'assignmentStates': []},
    }));
    await waitFor(
        () => connection.connectionStage == WorkspaceConnectionStage.ready);
    expect(connection.lastReadyAt, isNotNull);
    await connection.close();
  });

  test('classifies a failed WebSocket upgrade by HTTP status', () async {
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-400'),
      workspaceRuntimeId: 'runtime-400',
      workspaceId: 'workspace-400',
      factory: (_) async => throw const WebSocketException(
        'upgrade rejected',
        HttpStatus.badRequest,
      ),
    );

    await expectLater(connection.connect(), throwsA(isA<WebSocketException>()));
    expect(connection.connectionStage, WorkspaceConnectionStage.offline);
    expect(connection.lastHttpStatusCode, HttpStatus.badRequest);
    expect(connection.lastConnectionError,
        'Cloud rejected the WebSocket upgrade with HTTP 400.');
    await connection.close();
  });

  test('preflight rejects a missing runtime credential before opening socket',
      () async {
    var opened = false;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-no-credential'),
      workspaceRuntimeId: 'runtime-no-credential',
      workspaceId: 'workspace-no-credential',
      credentialAvailable: false,
      factory: (_) async {
        opened = true;
        return FakeSocket();
      },
    );

    await expectLater(
      connection.connect(),
      throwsA(isA<WorkspaceConnectionPreflightException>()),
    );
    expect(opened, isFalse);
    expect(connection.connectionStage, WorkspaceConnectionStage.offline);
    expect(connection.lastConnectionError, contains('credential is missing'));
    await connection.close();
  });

  test('manual retry opens a fresh socket without replacing the runtime',
      () async {
    final first = FakeSocket();
    final second = FakeSocket();
    var calls = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-retry'),
      workspaceRuntimeId: 'runtime-retry',
      workspaceId: 'workspace-retry',
      factory: (_) async => ++calls == 1 ? first : second,
    );

    await connection.connect();
    await connection.retryNow();

    expect(calls, 2);
    expect(connection.connectionStage, WorkspaceConnectionStage.authenticating);
    expect(connection.isConnected, isFalse);
    await connection.close();
  });

  test('hello acknowledgement timeout differs from upgrade failure', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-no-hello'),
      workspaceRuntimeId: 'runtime-no-hello',
      workspaceId: 'workspace-no-hello',
      factory: (_) async => socket,
      protocolHandshakeTimeout: const Duration(milliseconds: 20),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    await waitFor(() => connection.lastConnectionError != null);
    expect(connection.lastConnectionError,
        contains('did not acknowledge workspace.hello'));
    expect(connection.lastHttpStatusCode, isNull);
    await connection.close();
  });

  test('Cloud sync timeout is distinct from the hello handshake timeout',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-no-sync'),
      workspaceRuntimeId: 'runtime-no-sync',
      workspaceId: 'workspace-no-sync',
      factory: (_) async => socket,
      protocolHandshakeTimeout: const Duration(seconds: 1),
      syncTimeout: const Duration(milliseconds: 30),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'sync-timeout-hello-ack',
      'correlationId': hello['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'workspaceRuntimeId': 'runtime-no-sync',
      'executionWorkspaceId': 'workspace-no-sync',
      'payload': {'sessionId': 'session-no-sync'},
    }));
    await waitFor(() => connection.lastConnectionError != null);

    expect(connection.lastConnectionError,
        contains('Cloud synchronization did not complete'));
    expect(connection.connectionStage, WorkspaceConnectionStage.reconnecting);
    await connection.close();
  });

  test('uses the Gateway session for protocol heartbeats', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(milliseconds: 10),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'correlationId': 'client-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
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
        .where((message) => message['type'] == 'workspace.heartbeat')
        .toList();
    expect(heartbeats, isNotEmpty);
    expect(
      (heartbeats.first['payload'] as Map<String, dynamic>)['sessionId'],
      'session-1',
    );
    expect(connection.authorizedWorkspaceIds, contains('workspace-2'));
    final sync = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.sync.request');
    expect(
      (sync['payload'] as Map<String, dynamic>)['workspaceRuntimeId'],
      'workspace-1',
    );
    await connection.close();
  });

  test('accepts a compatible newer minor protocol version', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(connection.isConnected, isTrue);
    await connection.close();
  });

  test('delivers validated Cloud update announcements to the Workspace',
      () async {
    final socket = FakeSocket();
    Map<String, Object?>? received;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      workspaceUpdateAvailableHandler: (payload) async {
        received = payload;
      },
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-update-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.update',
      'payload': {
        'version': '0.2.0',
        'channel': 'stable',
        'packageR2Key': 'workspace/releases/0.2.0/macos-arm64.tar.gz',
        'packageDigest': 'sha256:abc123',
        'signature': 'sig-1',
        'releaseNotes': 'Security fixes',
        'minSupportedWorkspaceVersion': '0.1.0',
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(received?['version'], '0.2.0');
    expect(received?['packageR2Key'],
        'workspace/releases/0.2.0/macos-arm64.tar.gz');
    await connection.close();
  });

  test('ignores an incompatible protocol major version', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '3.0',
      'messageId': 'server-incompatible',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'should-not-be-accepted'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(connection.sessionId, isNull);
    expect(
      socket.sent.where((message) =>
          (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
          'workspace.sync.request'),
      isEmpty,
    );
    await connection.close();
  });

  test('reports Workspace-owned Worker inventory over runtime protocol',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connection.reportWorkerInventory([
      {
        'workerId': 'worker-1',
        'workerTypeId': 'chatgpt',
        'activationState': 'enabled',
        'readinessState': 'ready',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'providerToolName': 'codex',
        'providerToolVersion': '1.0.0',
        'capabilities': ['text', 'workstream_read'],
        'localConcurrencyLimit': 1,
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
    expect((payload['workers'] as List).single['engineVersion'], '1.0.0');
    expect(
      (payload['workers'] as List).single['profileDefinitionId'],
      'chatgpt-codex',
    );
    expect(jsonEncode(payload), isNot(contains('credentialRef')));
    expect(jsonEncode(payload), isNot(contains('providerToolPath')));
    await connection.close();
  });

  test('forwards Worker progress with trusted correlation and redacted output',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    const context = WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-1',
      idempotencyKey: 'idem-1',
      payload: {},
    );
    connection.reportWorkerProgress(
      context,
      WorkerProgress(
        requestId: 'request-1',
        assignmentId: 'assignment-1',
        percentage: 20,
        message: '[REDACTED]',
      ),
    );
    connection.reportWorkerProgress(
      context,
      WorkerProgress(
        requestId: 'request-2',
        assignmentId: 'forged-assignment',
        percentage: 20,
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
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
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
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-ack',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(socketCount, greaterThan(1));
    expect(connection.reconnectCount, greaterThan(0));
    await connection.close();
  });

  test('includes recovered non-terminal assignments in sync', () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('workspace-sync-');
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
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final sync = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.sync.request');
    expect(
      (sync['payload'] as Map<String, dynamic>)['unreconciledAssignmentIds'],
      ['already-completed', 'recovered-running'],
    );
    await connection.close();
  });

  test('executes correlated assignments through the injected handler',
      () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        expect(context.runId, 'run-1');
        expect(context.taskId, 'task-1');
        return const WorkspaceAssignmentResult(
            summary: 'completed by workspace');
      },
      assignmentJournal: journal,
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-assignment-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
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
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
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
        'completed by workspace');
    final records = await journal.reconcile();
    expect(records['assignment-1']!.status, AssignmentStatus.completed);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('reports normalized assignment failures to Cloud without changing codes',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async => throw const AssignmentExecutionFailure(
        code: 'quota_exhausted',
        message:
            'The provider rejected this request because a usage limit was reached.',
        retryable: false,
      ),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-normalized-engine-error',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-error',
      'taskId': 'task-error',
      'attemptId': 'attempt-error',
      'assignmentId': 'assignment-error',
      'idempotencyKey': 'idem-error',
      'payload': {
        'objective': 'test normalized error',
        'role': 'implementer',
        'workerId': 'chatgpt',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.error';
        }));
    final errorMessage = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    final error = (errorMessage['payload'] as Map<String, dynamic>)['error']
        as Map<String, dynamic>;
    expect(error['code'], 'quota_exhausted');
    expect(error['retryable'], isFalse);
    expect(error['message'], contains('usage limit'));
    await connection.close();
  });

  test('paused or draining Workspace rejects new assignments', () async {
    final socket = FakeSocket();
    var executions = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        executions++;
        return const WorkspaceAssignmentResult(summary: 'unexpected');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    connection.beginDrain();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-paused',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-paused',
      'taskId': 'task-paused',
      'attemptId': 'attempt-paused',
      'assignmentId': 'assignment-paused',
      'idempotencyKey': 'idem-paused',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'worker-1',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.ack' &&
              (decoded['payload'] as Map?)?['accepted'] == false;
        }));
    expect(executions, 0);
    expect(connection.isDraining, isTrue);
    await connection.close();
  });

  test('allows stateful Work through ID-derived Workstream directories',
      () async {
    final socket = FakeSocket();
    var executed = false;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        executed = true;
        expect(context.payload['projectId'], 'project-1');
        expect(context.payload['workstreamId'], 'workstream-1');
        return const WorkspaceAssignmentResult(summary: 'empty directory work');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-empty-work-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
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
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
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
    final directory =
        await Directory.systemTemp.createTemp('workspace-replay-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.now().toUtc(),
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      idempotencyKey: 'idem-1',
      result: {'summary': 'recovered', 'artifactIds': <String>[]},
    ));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-sync-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.sync.result',
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
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-assignment-2',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-2',
      'workspaceRuntimeId': 'workspace-1',
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
        'worker_not_ready');
    await connection.close();
  });

  test('rejects malformed assignment payloads before worker execution',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        fail('malformed assignment reached the handler');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-assignment-3',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
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
        'execution_failed');
    await connection.close();
  });

  test('replays a completed assignment without rerunning the handler',
      () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    var executions = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentHandler: (_) async {
        executions += 1;
        return const WorkspaceAssignmentResult(summary: 'once');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    Map<String, Object?> assignment() => {
          'protocol': 'conclave.workspace-runtime-protocol',
          'protocolVersion': '4.1',
          'messageId': 'server-replay-${executions + 1}',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'workspaceId': 'workspace-1',
          'workspaceRuntimeId': 'workspace-1',
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
            'engineVersion': '1.0.0',
            'profileDefinitionId': 'chatgpt-codex',
            'profileReleaseVersion': 1,
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
    final directory =
        await Directory.systemTemp.createTemp('workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final release = Completer<void>();
    var executions = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentHandler: (_) async {
        executions += 1;
        await release.future;
        return const WorkspaceAssignmentResult(summary: 'once');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    final assignment = <String, Object?>{
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': '4.1',
      'messageId': 'server-running-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
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
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
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
    final directory = await Directory.systemTemp.createTemp('cancelled-run-');
    addTearDown(() => directory.delete(recursive: true));
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-done',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.now().toUtc(),
    ));
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cancel-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.cancel',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
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

  test('reconnects after a dropped socket', () async {
    final sockets = <FakeSocket>[FakeSocket(), FakeSocket()];
    final first = sockets.first;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
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
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse('wss://cloud.test/workspace'),
      workspaceRuntimeId: 'workspace-1',
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
    final cancellationRequests = <String>[];
    final assignmentStarted = Completer<void>();
    final finishAssignment = Completer<WorkspaceAssignmentResult>();
    var factoryCalls = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => ++factoryCalls == 1 ? first : recovered,
      assignmentHandler: (_) {
        assignmentStarted.complete();
        return finishAssignment.future;
      },
      assignmentCancellationHandler: (assignmentId, reason) async {
        cancellationRequests.add('$assignmentId:$reason');
        return true;
      },
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 5),
    );
    await connection.connect();
    await completeHandshake(connection, first);
    first.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'assignment-before-reconnect',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-still-running',
      'idempotencyKey': 'idempotency-cancel-after-reconnect',
      'payload': {
        'workerId': 'worker-1',
        'objective': 'keep running until Cloud cancels',
        'role': 'implementer',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': <String, Object?>{},
        'contextArtifactIds': <String>[],
        'timeoutMs': 60000,
      },
    }));
    await assignmentStarted.future.timeout(const Duration(seconds: 2));
    await first.controller.close();
    await waitFor(() => connection.reconnectCount > 0);
    // reconnectCount increments before the retry delay. Wait for the recovered
    // socket's hello to prove _open attached its message listener before send.
    await waitFor(() => recovered.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'workspace.hello';
        }));
    await completeHandshake(connection, recovered, sessionId: 'recovered');
    recovered.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cancel-after-reconnect',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.cancel',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-still-running',
      'idempotencyKey': 'idempotency-cancel-after-reconnect',
      'payload': {'reason': 'cancelled after reconnect', 'gracePeriodMs': 100},
    }));
    await waitFor(() => cancellationRequests.isNotEmpty);
    expect(cancellationRequests.first,
        'assignment-still-running:cancelled after reconnect');
    await waitFor(() => recovered.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'assignment.cancel.ack'));
    finishAssignment.complete(
        const WorkspaceAssignmentResult(summary: 'cancelled by test'));
    await connection.close();
  });
}

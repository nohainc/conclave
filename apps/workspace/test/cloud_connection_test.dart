import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/assignment_journal.dart';
import 'package:conclave_workspace/assignment_trace.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart'
    show CliWorkerEngineProbeException;
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_workspace/workspace_transport.dart';
import 'package:conclave_workspace/worker_diagnostic_store.dart';
import 'package:test/test.dart';

class FakeSocket implements WorkspaceTransport {
  final controller = StreamController<Object?>();
  final sent = <Object>[];

  @override
  Stream<Object?> get messages => controller.stream.map((raw) {
        if (raw is! String) return raw;
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) return raw;
        final type = decoded['type'];
        if (type == 'assignment.start') {
          decoded['executionWorkspaceId'] ??= decoded.remove('workspaceId');
          final payload = decoded['payload'];
          if (payload is Map<String, dynamic> && payload['snapshot'] == null) {
            final snapshot = Map<String, dynamic>.from(payload)
              ..remove('input');
            final workerId = snapshot['workerId'];
            snapshot['workerTypeId'] ??=
                workerId == 'gemini' ? 'gemini' : 'chatgpt';
            decoded['payload'] = {
              'snapshot': snapshot,
              if (payload['input'] is Map) 'input': payload['input'],
            };
          }
          return jsonEncode(decoded);
        }
        if (type == 'workspace.hello.ack' || type == 'workspace.sync.result') {
          final requestType = type == 'workspace.hello.ack'
              ? 'workspace.hello'
              : 'workspace.sync.request';
          final requests = sent
              .whereType<String>()
              .map((message) => jsonDecode(message) as Map<String, dynamic>)
              .where((message) => message['type'] == requestType)
              .toList();
          final request = requests.isEmpty ? null : requests.last;
          final payload = request?['payload'];
          if (request != null && payload is Map<String, dynamic>) {
            decoded['correlationId'] = request['messageId'];
            decoded['workspaceRuntimeId'] ??= payload['workspaceRuntimeId'];
            decoded['executionWorkspaceId'] ??= payload['executionWorkspaceId'];
            return jsonEncode(decoded);
          }
        }
        return raw;
      });

  @override
  void send(Object message) => sent.add(message);

  @override
  Future<void> sendAndWait(Object message) {
    send(message);
    return Future<void>.value();
  }

  @override
  Future<void> close() => controller.close();
}

/// Rejects the first terminal sends while the connection itself stays up.
class FlakyTerminalSocket extends FakeSocket {
  FlakyTerminalSocket(this.failures);
  int failures;

  @override
  Future<void> sendAndWait(Object message) {
    final decoded = jsonDecode(message as String) as Map<String, dynamic>;
    if (decoded['type'] == 'assignment.result' && failures > 0) {
      failures--;
      return Future<void>.error(TimeoutException('terminal send timed out'));
    }
    return super.sendAndWait(message);
  }
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
  bool announceReadiness = false,
  List<Map<String, Object?>> assignmentStates = const [],
  Future<void> Function()? beforeSyncResult,
  DateTime? serverTime,
}) async {
  Map<String, dynamic> sentMessage(String type) => socket.sent
      .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
      .firstWhere((message) => message['type'] == type);

  final legacy = connection.uri.path.contains('/workspace') &&
      !connection.uri.path.contains('workspace-gateway');
  final protocol = legacy
      ? 'conclave.workspace-runtime-protocol'
      : 'conclave.workspace-runtime-protocol';
  final version = workspaceRuntimeProtocolVersion;
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
    'workspaceRuntimeId': connection.workspaceRuntimeId,
    'executionWorkspaceId': connection.workspaceId,
    'payload': {
      'sessionId': sessionId,
      if (serverTime != null)
        'serverTime': serverTime.toUtc().toIso8601String(),
      if (announceReadiness) 'cloudCapabilities': [serviceReadinessCapability],
    },
  }));

  const syncType = 'workspace.sync.request';
  await waitFor(() => socket.sent.any((message) =>
      (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
      syncType));
  final sync = sentMessage(syncType);
  if (beforeSyncResult != null) await beforeSyncResult();
  socket.controller.add(jsonEncode({
    'protocol': protocol,
    'protocolVersion': version,
    'messageId': 'test-sync-result',
    if (!legacy) 'correlationId': sync['messageId'],
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'type': legacy ? 'workspace.sync.response' : 'workspace.sync.result',
    'workspaceRuntimeId': connection.workspaceRuntimeId,
    'executionWorkspaceId': connection.workspaceId,
    'payload': {'assignmentStates': assignmentStates},
  }));
  await waitFor(
      () => connection.connectionStage == WorkspaceConnectionStage.ready);
}

void main() {
  test('connects outbound and sends hello', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    expect(hello['protocol'], 'conclave.workspace-runtime-protocol');
    expect(hello['protocolVersion'], workspaceRuntimeProtocolVersion);
    expect(hello['type'], 'workspace.hello');
    final payload = hello['payload'] as Map<String, dynamic>;
    expect(payload['workspaceRuntimeId'], 'workspace-1');
    expect(payload['executionWorkspaceId'], 'workspace-1');
    expect(payload['capabilities'], isA<Map<String, dynamic>>());
    await connection.close();
  });

  test('refreshes catalog after initial sync and each recovered session',
      () async {
    final firstSocket = FakeSocket();
    final secondSocket = FakeSocket();
    final sockets = [firstSocket, secondSocket];
    var refreshes = 0;
    late final WorkspaceCloudConnection connection;
    connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-refresh'),
      workspaceRuntimeId: 'runtime-refresh',
      workspaceId: 'workspace-refresh',
      factory: (_) async => sockets.removeAt(0),
      workerInventoryProvider: () async => const [],
      onSessionReady: () async {
        refreshes++;
        await connection.refreshWorkerInventory();
      },
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 2),
    );

    await connection.connect();
    await completeHandshake(connection, firstSocket,
        sessionId: 'first-session');
    await waitFor(() => refreshes == 1);

    await firstSocket.controller.close();
    await waitFor(() => secondSocket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'workspace.hello'));
    await completeHandshake(connection, secondSocket,
        sessionId: 'second-session');
    await waitFor(() => refreshes == 2);

    expect(refreshes, 2);
    await connection.close();
  });

  test('hands fallback back to WSS only after sync reconciliation', () async {
    final fallback = FakeSocket();
    final recovered = FakeSocket();
    final pendingUpgrade = Completer<WorkspaceTransport>();
    var socketAttempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-handover'),
      workspaceRuntimeId: 'runtime-handover',
      workspaceId: 'workspace-handover',
      factory: (_) async {
        socketAttempts++;
        if (socketAttempts <= 2) throw const SocketException('offline');
        return pendingUpgrade.future;
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
    expect(fallback.controller.isClosed, isFalse);
    expect(connection.activeTransportMode, 'http_long_poll');
    pendingUpgrade.complete(recovered);
    await waitFor(() => fallback.controller.isClosed);
    await waitFor(
        () => connection.activeTransportMode == 'switching_to_websocket');
    expect(connection.connectionStage, WorkspaceConnectionStage.authenticating);
    await acknowledge(recovered, 'recovered');
    expect(connection.activeTransportMode, 'websocket');
    await connection.close();
  });

  test('failed background probes preserve HTTPS and back off to an hour',
      () async {
    final fallback = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => throw const SocketException('WSS unavailable'),
      fallbackFactory: (_) async => fallback,
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(minutes: 5),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    final session = connection.sessionId;
    expect(connection.nextWebSocketProbeDelay, const Duration(minutes: 5));
    // Immediate wake retry resets backoff, then a failure doubles it.
    await connection.retryWebSocketNow();
    expect(connection.nextWebSocketProbeDelay, const Duration(minutes: 10));
    expect(connection.sessionId, session);
    expect(connection.connectionStage, WorkspaceConnectionStage.ready);
    expect(connection.activeTransportMode, 'http_long_poll');
    expect(fallback.controller.isClosed, isFalse);
    await connection.close();
  });

  test('a fresh network client keeps an upgraded WebSocket usable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upgraded = Completer<WebSocket>();
    final listener = server.listen((request) async {
      upgraded.complete(await WebSocketTransformer.upgrade(request));
    });
    final transport = await connectWebSocketWorkspaceTransport(
      Uri.parse('ws://127.0.0.1:${server.port}/'),
    );
    final socket = await upgraded.future;
    final response = transport.messages.first;
    socket.add('alive');
    expect(await response, 'alive');
    await transport.close();
    await socket.close();
    await listener.cancel();
    await server.close(force: true);
  });

  test('timed-out probe leaves HTTPS ready and disposes a late result',
      () async {
    final fallback = FakeSocket();
    final lateSocket = FakeSocket();
    final pending = Completer<WorkspaceTransport>();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) {
        attempts++;
        if (attempts == 1) throw const SocketException('offline');
        return pending.future;
      },
      fallbackFactory: (_) async => fallback,
      protocolHandshakeTimeout: const Duration(milliseconds: 100),
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(hours: 1),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    await connection.retryWebSocketNow();
    expect(connection.connectionStage, WorkspaceConnectionStage.ready);
    expect(fallback.controller.isClosed, isFalse);
    pending.complete(lateSocket);
    await waitFor(() => lateSocket.controller.isClosed);
    expect(lateSocket.sent, isEmpty);
    await connection.close();
  });

  test('periodic failures reach the maximum retry interval', () async {
    final fallback = FakeSocket();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async {
        attempts++;
        throw const SocketException('offline');
      },
      fallbackFactory: (_) async => fallback,
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(milliseconds: 10),
      webSocketProbeMaxInterval: const Duration(milliseconds: 40),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    await waitFor(() => attempts >= 4);
    expect(
        connection.nextWebSocketProbeDelay, const Duration(milliseconds: 40));
    expect(fallback.controller.isClosed, isFalse);
    await connection.close();
  });

  test('disconnect fences a pending probe and closes its late socket',
      () async {
    final fallback = FakeSocket();
    final candidate = FakeSocket();
    final pending = Completer<WorkspaceTransport>();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) {
        attempts++;
        if (attempts == 1) throw const SocketException('offline');
        return pending.future;
      },
      fallbackFactory: (_) async => fallback,
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(hours: 1),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    final probe = connection.retryWebSocketNow();
    expect(fallback.controller.isClosed, isFalse);
    await connection.close();
    pending.complete(candidate);
    await probe;
    await waitFor(() => candidate.controller.isClosed);
    expect(connection.connectionStage, WorkspaceConnectionStage.offline);
    expect(candidate.sent, isEmpty);
  });

  test('reports Thread readiness without a local path', () async {
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

    connection.reportThreadStatus(
      spaceId: 'space-1',
      threadId: 'thread-1',
      workingDirectoryState: 'ready',
    );
    final status = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'thread.status');
    final payload = status['payload'] as Map<String, dynamic>;
    expect(payload['spaceId'], 'space-1');
    expect(payload['threadId'], 'thread-1');
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(milliseconds: 10),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'correlationId': 'client-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
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
        .where((message) => message['type'] == 'workspace.heartbeat')
        .toList();
    expect(heartbeats, isNotEmpty);
    expect(
      (heartbeats.first['payload'] as Map<String, dynamic>)['sessionId'],
      'session-1',
    );
    expect(connection.authorizedWorkspaceIds, contains('workspace-1'));
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connection.reportWorkerInventory([
      {
        'workerId': 'workspace-worker-dynamic',
        'workerTypeId': 'dynamic-test-worker',
        'activationState': 'enabled',
        'readinessState': 'ready',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'dynamic-test-cli',
        'profileReleaseVersion': 1,
        'providerToolName': 'Fixture CLI',
        'providerToolVersion': '1.0.0',
        'capabilities': ['text', 'thread_read'],
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
    expect((payload['workers'] as List).single['workerId'],
        'workspace-worker-dynamic');
    expect((payload['workers'] as List).single['engineVersion'], '1.0.0');
    expect(
      (payload['workers'] as List).single['profileDefinitionId'],
      'dynamic-test-cli',
    );
    expect(
      (payload['workers'] as List).single['workerTypeId'],
      'dynamic-test-worker',
    );
    expect(
      (payload['workers'] as List).single['providerToolName'],
      'Fixture CLI',
    );
    expect(jsonEncode(payload), isNot(contains('credentialRef')));
    expect(jsonEncode(payload), isNot(contains('providerToolPath')));
    await connection.close();
  });

  test('forwards every Worker activity with ordering and safe details',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-activity',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-activity'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    const context = WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-activity',
      idempotencyKey: 'idem-activity',
      payload: {},
    );
    for (final entry in [
      ('tool-call-1', 'tool.started', 'running', 1),
      ('tool-call-1', 'tool.completed', 'completed', 2),
      ('tool-call-2', 'tool.started', 'running', 3),
    ]) {
      await connection.reportWorkerActivity(
        context,
        WorkerActivity(
          requestId: 'request-activity',
          assignmentId: context.assignmentId,
          executionId: 'execution-activity',
          workerId: 'chatgpt',
          eventId: 'event-${entry.$4}',
          sequence: entry.$4,
          timestamp: '2026-10-12T18:00:0${entry.$4}Z',
          eventType: entry.$2,
          status: entry.$3,
          title: 'Tool',
          activityId: entry.$1,
          details: const {'toolName': 'shell'},
        ),
      );
    }
    await waitFor(() =>
        socket.sent.where((item) {
          final value = jsonDecode(item as String) as Map<String, dynamic>;
          return value['type'] == 'assignment.activity';
        }).length ==
        3);
    final messages = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'assignment.activity')
        .toList();
    expect(
        messages.map((message) =>
            (message['payload'] as Map<String, dynamic>)['sequence']),
        [1, 2, 3]);
    expect(
        messages.map((message) =>
            (message['payload'] as Map<String, dynamic>)['activityId']),
        ['tool-call-1', 'tool-call-1', 'tool-call-2']);
    expect(jsonEncode(messages), isNot(contains('prompt')));
    await connection.close();
  });

  test('retains activity generated while disconnected until reconnect',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    const context = WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-disconnected',
      idempotencyKey: 'idem-disconnected',
      payload: {},
    );

    await connection.reportWorkerActivity(
      context,
      WorkerActivity(
        requestId: 'request-disconnected',
        assignmentId: 'assignment-disconnected',
        executionId: 'execution-disconnected',
        workerId: 'worker-1',
        eventId: 'event-disconnected',
        sequence: 1,
        timestamp: '2026-10-12T18:00:01Z',
        eventType: 'execution.started',
        status: 'running',
        title: 'Worker started',
      ),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-disconnected-activity',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-disconnected-activity'},
    }));

    await waitFor(() => socket.sent.any((item) {
          final value = jsonDecode(item as String) as Map<String, dynamic>;
          return value['type'] == 'assignment.activity' &&
              value['assignmentId'] == 'assignment-disconnected';
        }));
    await connection.close();
  });

  test('reconnects when Gateway heartbeat acknowledgements stop', () async {
    var socketCount = 0;
    final sockets = <FakeSocket>[];
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        expect(context.runId, 'run-1');
        expect(context.taskId, 'task-1');
        return const WorkspaceAssignmentResult(
          summary: 'completed by workspace',
          output: {'text': 'durable result payload'},
        );
      },
      assignmentJournal: journal,
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
    expect((records['assignment-1']!.result?['output'] as Map)['text'],
        'durable result payload');
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('reconciles a handler that exceeds the assignment deadline', () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-timeout-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    var cancellationRequested = false;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentCancellationHandler: (assignmentId, reason) async {
        cancellationRequested = assignmentId == 'assignment-timeout' &&
            reason == 'Assignment deadline exceeded';
        return cancellationRequested;
      },
      assignmentHandler: (_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return const WorkspaceAssignmentResult(summary: 'too late');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-timeout',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-timeout',
      'taskId': 'task-timeout',
      'attemptId': 'attempt-timeout',
      'assignmentId': 'assignment-timeout',
      'idempotencyKey': 'idem-timeout',
      'payload': {
        'objective': 'deadline test',
        'role': 'implementer',
        'workerId': 'worker-1',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
        'queueWaitTimeoutMs': 1000,
      },
    }));

    await waitFor(
        () => socket.sent.any((message) {
              final decoded =
                  jsonDecode(message as String) as Map<String, dynamic>;
              return decoded['type'] == 'assignment.error';
            }),
        timeout: const Duration(seconds: 3));
    final errorMessage = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    final payload = errorMessage['payload'] as Map<String, dynamic>;
    expect(payload['executionId'], 'assignment-timeout');
    expect((payload['error'] as Map)['code'], 'timeout');
    expect(cancellationRequested, isTrue);
    expect(connection.activeAssignmentCount, 0);
    expect((await journal.reconcile())['assignment-timeout']!.status,
        AssignmentStatus.failed);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('reports normalized assignment failures to Cloud without changing codes',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      'protocolVersion': workspaceRuntimeProtocolVersion,
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

  test(
      'normalizes Engine provider failures instead of hiding them as generic execution errors',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async => throw const CliWorkerEngineProbeException(
        'provider_tool_unavailable',
        'CLI Worker Engine could not be started.',
        localDiagnostics: 'provider launch failed',
      ),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'engine-provider-error',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-engine-error',
      'taskId': 'task-engine-error',
      'attemptId': 'attempt-engine-error',
      'assignmentId': 'assignment-engine-error',
      'idempotencyKey': 'idem-engine-error',
      'payload': {
        'objective': 'test engine error normalization',
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
    expect(error['code'], 'cli_not_found');
    expect(error['retryable'], isFalse);
    expect(error['message'], contains('CLI'));
    expect(
      (error['details'] as Map<String, dynamic>)['diagnostic'],
      'provider launch failed',
    );
    await connection.close();
  });

  test('retains unexpected runtime exception detail for private reports', () {
    final normalized = normalizeAssignmentExecutionFailure(
      const FormatException(
          'Engine response was malformed at /Users/tester/run'),
    );
    expect(normalized.code, 'execution_failed');
    expect(normalized.message, 'The assignment could not be completed.');
    expect(normalized.retryable, isTrue);
    expect(normalized.localDiagnostic, contains('FormatException'));
    expect(normalized.localDiagnostic, contains('[PATH]'));
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

  test('allows stateful Work through ID-derived Thread directories', () async {
    final socket = FakeSocket();
    var executed = false;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        executed = true;
        expect(context.payload['spaceId'], 'space-1');
        expect(context.payload['threadId'], 'thread-1');
        return const WorkspaceAssignmentResult(summary: 'empty directory work');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
        'spaceId': 'space-1',
        'threadId': 'thread-1',
        'executionClass': 'stateful_thread',
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

  test('redelivers a terminal result on a timer after a failed send',
      () async {
    final socket = FlakyTerminalSocket(1);
    final directory =
        await Directory.systemTemp.createTemp('workspace-redeliver-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async => const WorkspaceAssignmentResult(
        summary: 'completed by workspace',
        output: {'text': 'durable result payload'},
      ),
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
      terminalRedeliveryInterval: const Duration(milliseconds: 40),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
    int results() => socket.sent
        .where((message) =>
            (jsonDecode(message as String) as Map)['type'] ==
            'assignment.result')
        .length;

    // The first send is rejected; the timer, not a reconnect, redelivers it.
    await waitFor(() => results() == 1);
    expect(socket.failures, 0);
    final redelivered = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.result');
    expect((redelivered['payload'] as Map)['summary'], isNotNull);
    expect((await journal.reconcile())['assignment-1']!.status,
        AssignmentStatus.completed);

    // Until Cloud acknowledges, delivery keeps being retried.
    await waitFor(() => results() >= 2);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'terminal-ack-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.ack',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {'accepted': true, 'terminal': true, 'status': 'completed'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect((await journal.reconcile())['assignment-1']!.status,
        AssignmentStatus.reconciled);
    final settled = results();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(results(), settled);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test(
      'delivers a result on the new session when the Service reconnected mid-run',
      () async {
    final first = FakeSocket();
    final second = FakeSocket();
    final sockets = [first, second];
    final release = Completer<void>();
    final directory =
        await Directory.systemTemp.createTemp('workspace-reconnect-run-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => sockets.removeAt(0),
      assignmentHandler: (context) async {
        await release.future;
        return const WorkspaceAssignmentResult(
          summary: 'completed after reconnect',
          output: {'text': 'durable result payload'},
        );
      },
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      reconnectMaxDelay: const Duration(milliseconds: 10),
      terminalRedeliveryInterval: const Duration(milliseconds: 40),
    );
    await connection.connect();
    await completeHandshake(connection, first);
    first.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
        'timeoutMs': 5000,
      },
    }));
    await waitFor(() => first.sent.any((message) =>
        (jsonDecode(message as String) as Map)['type'] == 'assignment.ack'));

    // The connection drops while the Worker is still running.
    await first.close();
    await completeHandshake(connection, second, sessionId: 'session-2');

    release.complete();
    await waitFor(
      () => second.sent.any((message) =>
          (jsonDecode(message as String) as Map)['type'] ==
          'assignment.result'),
      timeout: const Duration(seconds: 5),
    );
    await connection.close();
    await directory.delete(recursive: true);
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
      result: {
        'summary': 'recovered',
        'output': {'text': 'saved output'},
        'artifactIds': <String>[],
      },
    ));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
        ((replay['payload'] as Map<String, dynamic>)['output'] as Map)['text'],
        'saved output');
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'terminal-ack-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.ack',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {'accepted': true, 'terminal': true, 'status': 'completed'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
    final payload = error['payload'] as Map<String, dynamic>;
    expect(payload['error']['code'], 'execution_failed');
    expect(
      jsonDecode(
        (payload['error']['details'] as Map<String, dynamic>)['diagnostic']
            as String,
      ),
      containsPair('stage', 'assignment_payload_validation'),
    );
    await connection.close();
  });

  test('rejects cross-worker Worker Session metadata', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
      'payload': {
        'workerId': 'worker-1',
        'objective': 'Hello',
        'role': 'assistant',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': <String, Object?>{},
        'contextArtifactIds': <String>[],
        'timeoutMs': 1000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'scope-A',
        'workerSession': {
          'schemaVersion': 1,
          'id': 'session-A',
          'conversationId': 'conversation-A',
          'workerId': 'worker-B',
          'baseContextRevision': 0,
        },
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    expect((error['payload'] as Map<String, dynamic>)['error']['code'],
        'execution_failed');
    await connection.close();
  });

  test('rejects provider-native Worker Session metadata', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
      'payload': {
        'workerId': 'worker-1',
        'objective': 'Hello',
        'role': 'assistant',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': <String, Object?>{},
        'contextArtifactIds': <String>[],
        'timeoutMs': 1000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'scope-A',
        'workerSession': {
          'schemaVersion': 1,
          'id': 'session-A',
          'conversationId': 'conversation-A',
          'workerId': 'worker-1',
          'nativeSessionId': 'private-handle',
          'baseContextRevision': 0,
        },
      },
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
          'protocolVersion': workspaceRuntimeProtocolVersion,
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

  test(
      'does not rerun a non-terminal assignment on duplicate delivery and re-asserts admission',
      () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final release = Completer<void>();
    var executions = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      'protocolVersion': workspaceRuntimeProtocolVersion,
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
    List<Map<String, dynamic>> acks() => socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'assignment.ack')
        .toList();
    // A duplicate for a live assignment re-asserts admission evidence (a
    // second accepted ack) instead of being rejected, and never re-executes.
    await waitFor(() => acks().length >= 2);

    expect(executions, 1);
    expect(
      acks().every((ack) => (ack['payload'] as Map)['accepted'] == true),
      isTrue,
    );
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

  group('Service readiness', () {
    List<Map<String, dynamic>> sentOfType(FakeSocket socket, String type) =>
        socket.sent
            .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
            .where((m) => m['type'] == type)
            .toList();

    WorkspaceCloudConnection newConnection(FakeSocket socket,
            {Duration heartbeat = const Duration(hours: 1),
            WorkspaceAssignmentHandler? handler}) =>
        WorkspaceCloudConnection(
          uri: Uri.parse(
              'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
          workspaceRuntimeId: 'runtime-1',
          workspaceId: 'workspace-1',
          factory: (_) async => socket,
          heartbeat: heartbeat,
          assignmentHandler: handler,
        );

    test('is disconnected until connected and advertises the capability',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      expect(connection.serviceState, ServiceConnectionState.disconnected);
      expect(connection.readyForAssignments, isFalse);
      await connection.connect();
      final hello = sentOfType(socket, 'workspace.hello').first;
      final capabilities =
          (hello['payload'] as Map)['capabilities'] as Map<String, dynamic>;
      expect(capabilities['customCapabilities'],
          contains(serviceReadinessCapability));
      await connection.close();
    });

    test(
        'is not ready while synchronizing, then publishes ready with a generation',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(
        connection,
        socket,
        announceReadiness: true,
        beforeSyncResult: () async {
          expect(connection.serviceState, ServiceConnectionState.synchronizing);
          expect(connection.readyForAssignments, isFalse);
          // Nothing is published as ready before synchronization completes.
          expect(
              sentOfType(socket, 'workspace.readiness').where(
                  (m) => (m['payload'] as Map)['readyForAssignments'] == true),
              isEmpty);
        },
      );
      expect(connection.serviceState, ServiceConnectionState.ready);
      final published = sentOfType(socket, 'workspace.readiness');
      expect(published, hasLength(1));
      expect(published.single['payload'], containsPair('state', 'ready'));
      expect(published.single['payload'],
          containsPair('readyForAssignments', true));
      expect(published.single['payload'], containsPair('syncGeneration', 1));
      expect(published.single['workspaceRuntimeId'], 'runtime-1');
      await connection.close();
    });

    test(
        'does not send the dedicated message to a Cloud that did not announce it',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(connection, socket);
      connection.pauseNewWork();
      expect(sentOfType(socket, 'workspace.readiness'), isEmpty);
      await connection.close();
    });

    test('publishes immediately when new work is paused, resumed or drained',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(connection, socket, announceReadiness: true);
      connection.pauseNewWork();
      expect(connection.serviceState, ServiceConnectionState.paused);
      expect(connection.readyForAssignments, isFalse);
      var last =
          sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'paused');
      expect(last['readyForAssignments'], isFalse);
      connection.resumeNewWork();
      last = sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'ready');
      expect(last['readyForAssignments'], isTrue);
      connection.beginDrain();
      expect(connection.serviceState, ServiceConnectionState.draining);
      last = sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'draining');
      expect(last['readyForAssignments'], isFalse);
      await connection.close();
    });

    test('announces shutdown before the connection is torn down', () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(connection, socket, announceReadiness: true);
      await connection.close();
      final last =
          sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'draining');
      expect(last['readyForAssignments'], isFalse);
      expect(last['reason'], 'shutdown');
    });

    test('repeats readiness on every heartbeat', () async {
      final socket = FakeSocket();
      final connection =
          newConnection(socket, heartbeat: const Duration(milliseconds: 150));
      await connection.connect();
      await completeHandshake(connection, socket);
      await waitFor(() => sentOfType(socket, 'workspace.heartbeat').isNotEmpty);
      final readiness = (sentOfType(socket, 'workspace.heartbeat')
          .last['payload'] as Map)['readiness'] as Map;
      expect(readiness['state'], 'ready');
      expect(readiness['readyForAssignments'], isTrue);
      expect(readiness['syncGeneration'], 1);
      await connection.close();
    });
  });

  group('assignments received while synchronizing', () {
    Map<String, Object?> startMessage(String assignmentId) => {
          'protocol': 'conclave.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'start-$assignmentId',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'executionWorkspaceId': 'workspace-1',
          'workspaceRuntimeId': 'runtime-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'assignmentId': assignmentId,
          'idempotencyKey': 'idem-$assignmentId',
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

    WorkspaceCloudConnection newConnection(
        FakeSocket socket, List<String> executed) {
      return WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        heartbeat: const Duration(hours: 1),
        assignmentHandler: (context) async {
          executed.add(context.assignmentId);
          return const WorkspaceAssignmentResult(summary: 'done');
        },
      );
    }

    test('runs a buffered command once synchronization completes', () async {
      final socket = FakeSocket();
      final executed = <String>[];
      final connection = newConnection(socket, executed);
      await connection.connect();
      await completeHandshake(
        connection,
        socket,
        assignmentStates: [
          {'assignmentId': 'buffered-ok', 'status': 'dispatched'},
        ],
        beforeSyncResult: () async {
          socket.controller.add(jsonEncode(startMessage('buffered-ok')));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(executed, isEmpty);
        },
      );
      await waitFor(() => executed.contains('buffered-ok'));
      expect(executed, ['buffered-ok']);
      await connection.close();
    });

    test('drops a buffered command Cloud has already revoked or finished',
        () async {
      final socket = FakeSocket();
      final executed = <String>[];
      final connection = newConnection(socket, executed);
      await connection.connect();
      await completeHandshake(
        connection,
        socket,
        assignmentStates: [
          {'assignmentId': 'buffered-revoked', 'status': 'revocation_pending'},
          {'assignmentId': 'buffered-done', 'status': 'timed_out'},
        ],
        beforeSyncResult: () async {
          socket.controller.add(jsonEncode(startMessage('buffered-revoked')));
          socket.controller.add(jsonEncode(startMessage('buffered-done')));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(executed, isEmpty);
      await connection.close();
    });

    test('rejects buffered commands explicitly when the connection ends first',
        () async {
      final socket = FakeSocket();
      final executed = <String>[];
      final connection = newConnection(socket, executed);
      await connection.connect();
      // Hello is acknowledged but the sync result never arrives.
      Map<String, dynamic> hello() => socket.sent
          .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
          .firstWhere((m) => m['type'] == 'workspace.hello');
      await waitFor(() => socket.sent.any((m) =>
          (jsonDecode(m as String) as Map<String, dynamic>)['type'] ==
          'workspace.hello'));
      socket.controller.add(jsonEncode({
        'protocol': 'conclave.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'hello-ack',
        'correlationId': hello()['messageId'],
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.hello.ack',
        'workspaceRuntimeId': 'runtime-1',
        'executionWorkspaceId': 'workspace-1',
        'payload': {'sessionId': 'session-x'},
      }));
      await waitFor(() => socket.sent.any((m) =>
          (jsonDecode(m as String) as Map<String, dynamic>)['type'] ==
          'workspace.sync.request'));
      socket.controller.add(jsonEncode(startMessage('buffered-lost')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await connection.close();
      final acks = socket.sent
          .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
          .where((m) =>
              m['type'] == 'assignment.ack' &&
              m['assignmentId'] == 'buffered-lost')
          .toList();
      expect(acks, hasLength(1));
      expect((acks.single['payload'] as Map)['accepted'], isFalse);
      expect(executed, isEmpty);
    });
  });

  group('start permit and durable cancellation', () {
    Map<String, Object?> envelope(
            String type, String assignmentId, Map<String, Object?> payload,
            {String attemptId = 'attempt-1'}) =>
        {
          'protocol': 'conclave.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'm-$type-$assignmentId',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': type,
          'executionWorkspaceId': 'workspace-1',
          'workspaceRuntimeId': 'runtime-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': attemptId,
          'assignmentId': assignmentId,
          'idempotencyKey': 'idem-$assignmentId',
          'payload': payload,
        };

    WorkspaceAssignmentContext contextFor(String assignmentId,
            {bool required = true, String attemptId = 'attempt-1'}) =>
        WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker-1',
          runId: 'run-1',
          taskId: 'task-1',
          attemptId: attemptId,
          assignmentId: assignmentId,
          idempotencyKey: 'idem-$assignmentId',
          payload: {
            if (required) 'startPermit': {'required': true},
          },
        );

    Future<(WorkspaceCloudConnection, FakeSocket)> connected(
        {AssignmentJournal? journal,
        WorkspaceAssignmentHandler? handler,
        bool withClockSample = true,
        MonotonicCloudClock? startPermitClock}) async {
      final socket = FakeSocket();
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        assignmentJournal: journal,
        assignmentHandler: handler,
        startPermitClock: startPermitClock,
      );
      await connection.connect();
      await completeHandshake(connection, socket,
          serverTime: withClockSample ? DateTime.now().toUtc() : null);
      return (connection, socket);
    }

    List<Map<String, dynamic>> sentOfType(FakeSocket socket, String type) =>
        socket.sent
            .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
            .where((m) => m['type'] == type)
            .toList();

    test('advertises the start permit capability', () async {
      final (connection, socket) = await connected();
      final hello = sentOfType(socket, 'workspace.hello').first;
      final capabilities =
          (hello['payload'] as Map)['capabilities'] as Map<String, dynamic>;
      expect(capabilities['customCapabilities'],
          contains(WorkspaceCloudConnection.startPermitCapability));
      await connection.close();
    });

    test('does not request a permit when Cloud does not require one', () async {
      final (connection, socket) = await connected();
      expect(
          await connection
              .requestStartPermit(contextFor('legacy', required: false)),
          isTrue);
      expect(sentOfType(socket, 'assignment.start.permit.request'), isEmpty);
      await connection.close();
    });

    test('grants launch only after Cloud returns a matching grant', () async {
      final (connection, socket) = await connected();
      final context = contextFor('assignment-permit');
      final result = connection.requestStartPermit(context);
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'assignment-permit',
        {
          'granted': true,
          'permitId': 'permit-1',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 30))
              .toIso8601String(),
        },
      )));
      expect(await result, isTrue);
      await connection.close();
    });

    test('a denied permit blocks launch', () async {
      final (connection, socket) = await connected();
      final result = connection.requestStartPermit(contextFor('revoked-one'));
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'revoked-one',
        {'granted': false, 'reason': 'revoked'},
      )));
      expect(await result, isFalse);
      await connection.close();
    });

    test('repeated stale runtime grants cannot authorize a replacement runtime',
        () async {
      final (connection, socket) = await connected();
      addTearDown(connection.close);
      for (var iteration = 0; iteration < 20; iteration++) {
        final id = 'replacement-$iteration';
        final result = connection.requestStartPermit(contextFor(id));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request')
                .any((message) => message['assignmentId'] == id));
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          id,
          {
            'granted': true,
            'permitId': 'stale-$iteration',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 30))
                .toIso8601String(),
          },
        )..['workspaceRuntimeId'] = 'replaced-runtime'));
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          id,
          {'granted': false, 'reason': 'revoked'},
        )));
        expect(await result, isFalse, reason: 'iteration $iteration');
      }
    });

    test('expired and malformed grants fail closed', () async {
      final (connection, socket) = await connected();
      addTearDown(connection.close);
      for (final expiry in [
        DateTime.utc(2000).toIso8601String(),
        'invalid',
        null,
      ]) {
        final id = 'expiry-$expiry';
        final result = connection.requestStartPermit(contextFor(id));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request')
                .any((message) => message['assignmentId'] == id));
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          id,
          {'granted': true, 'permitId': 'expired', 'expiresAt': expiry},
        )));
        expect(await result, isFalse);
      }
    });

    test('permit expiry uses conservative Cloud time for either clock skew',
        () async {
      for (final skewSeconds in [-120, 120]) {
        for (final remainingSeconds in [-1, 30]) {
          final (connection, socket) = await connected(withClockSample: false);
          try {
            final now = DateTime.now().toUtc();
            connection.clockOffset.addSample(
              sentAtUtc: now,
              roundTrip: const Duration(milliseconds: 100),
              serverTimeUtc:
                  now.add(Duration(seconds: skewSeconds, milliseconds: 50)),
            );
            connection.startPermitClock.addSample(
              serverTimeUtc:
                  now.add(Duration(seconds: skewSeconds, milliseconds: 50)),
              roundTrip: const Duration(milliseconds: 100),
            );
            final id = 'skew-$skewSeconds-$remainingSeconds';
            final result = connection.requestStartPermit(contextFor(id));
            await waitFor(() =>
                sentOfType(socket, 'assignment.start.permit.request')
                    .isNotEmpty);
            socket.controller.add(jsonEncode(envelope(
              'assignment.start.permit.grant',
              id,
              {
                'granted': true,
                'permitId': 'skew-permit',
                'expiresAt': now
                    .add(Duration(seconds: skewSeconds + remainingSeconds))
                    .toIso8601String(),
              },
            )));
            expect(await result, remainingSeconds > 0,
                reason: 'Cloud offset $skewSeconds, TTL $remainingSeconds');
          } finally {
            await connection.close();
          }
        }
      }
    });

    test('missing clock sample or expiry within RTT uncertainty denies launch',
        () async {
      for (final sampled in [false, true]) {
        final (connection, socket) = await connected(withClockSample: false);
        try {
          final now = DateTime.now().toUtc();
          if (sampled) {
            connection.clockOffset.addSample(
              sentAtUtc: now,
              roundTrip: const Duration(seconds: 10),
              serverTimeUtc: now.add(const Duration(seconds: 5)),
            );
            connection.startPermitClock.addSample(
              serverTimeUtc: now.add(const Duration(seconds: 5)),
              roundTrip: const Duration(seconds: 10),
            );
          }
          final id = 'uncertain-$sampled';
          final result = connection.requestStartPermit(contextFor(id));
          await waitFor(() =>
              sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
          socket.controller.add(jsonEncode(envelope(
            'assignment.start.permit.grant',
            id,
            {
              'granted': true,
              'permitId': 'uncertain',
              'expiresAt':
                  now.add(const Duration(seconds: 2)).toIso8601String(),
            },
          )));
          expect(await result, isFalse);
        } finally {
          await connection.close();
        }
      }
    });

    test('clock corrections between sampling and grant cannot change expiry',
        () async {
      for (final correction in [-120, 120]) {
        for (final ttl in [5, 20]) {
          var monotonic = Duration.zero;
          final clock = MonotonicCloudClock(monotonicNow: () => monotonic);
          final (connection, socket) =
              await connected(withClockSample: false, startPermitClock: clock);
          try {
            final serverNow = DateTime.now().toUtc();
            // The telemetry offset retains the local wall clock from sampling.
            // Relative to the wall clock at grant receipt, this models a step
            // in either direction. Permit validation must never read it.
            connection.clockOffset.addSample(
              sentAtUtc: serverNow.subtract(Duration(seconds: correction)),
              serverTimeUtc: serverNow,
              roundTrip: Duration.zero,
            );
            clock.addSample(serverTimeUtc: serverNow, roundTrip: Duration.zero);
            final id = 'correction-$correction-$ttl';
            final result = connection.requestStartPermit(contextFor(id));
            await waitFor(() =>
                sentOfType(socket, 'assignment.start.permit.request')
                    .isNotEmpty);
            // Ten seconds pass while the grant is in flight, independent of
            // the local wall-clock correction represented above.
            monotonic = const Duration(seconds: 10);
            socket.controller.add(jsonEncode(envelope(
              'assignment.start.permit.grant',
              id,
              {
                'granted': true,
                'permitId': 'corrected-clock',
                'expiresAt':
                    serverNow.add(Duration(seconds: ttl)).toIso8601String(),
              },
            )));
            expect(await result, ttl > 10,
                reason: 'wall correction $correction, TTL $ttl');
          } finally {
            await connection.close();
          }
        }
      }
    });

    test('aged clock estimate cannot authorize an otherwise valid grant',
        () async {
      var monotonic = Duration.zero;
      final clock = MonotonicCloudClock(monotonicNow: () => monotonic);
      final (connection, socket) = await connected(startPermitClock: clock);
      try {
        final result = connection.requestStartPermit(contextFor('aged-clock'));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
        monotonic = MonotonicCloudClock.maxSampleAge;
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          'aged-clock',
          {
            'granted': true,
            'permitId': 'aged',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
          },
        )));
        expect(await result, isFalse);
      } finally {
        await connection.close();
      }
    });

    test('transport replacement and close invalidate permit time authority',
        () async {
      var socket = FakeSocket();
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
      );
      try {
        await connection.connect();
        await completeHandshake(connection, socket,
            serverTime: DateTime.now().toUtc());
        expect(connection.startPermitClock.latestServerTime, isNotNull);
        socket = FakeSocket();
        await connection.retryNow();
        expect(connection.startPermitClock.latestServerTime, isNull);
        await completeHandshake(connection, socket);
        final result =
            connection.requestStartPermit(contextFor('new-transport'));
        await waitFor(() =>
            sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
        socket.controller.add(jsonEncode(envelope(
          'assignment.start.permit.grant',
          'new-transport',
          {
            'granted': true,
            'permitId': 'old-sample',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 30))
                .toIso8601String(),
          },
        )));
        expect(await result, isFalse);
        connection.startPermitClock.addSample(
            serverTimeUtc: DateTime.now().toUtc(), roundTrip: Duration.zero);
      } finally {
        await connection.close();
      }
      expect(connection.startPermitClock.latestServerTime, isNull);
    });

    test('ignores a grant issued for a different attempt', () async {
      final (connection, socket) = await connected();
      final result = connection.requestStartPermit(contextFor('stale-attempt'));
      await waitFor(() =>
          sentOfType(socket, 'assignment.start.permit.request').isNotEmpty);
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'stale-attempt',
        {
          'granted': true,
          'permitId': 'permit-old',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 30))
              .toIso8601String(),
        },
        attemptId: 'attempt-0',
      )));
      socket.controller.add(jsonEncode(envelope(
        'assignment.start.permit.grant',
        'stale-attempt',
        {'granted': false, 'reason': 'stale'},
      )));
      expect(await result, isFalse);
      await connection.close();
    });

    test('persists a cancel tombstone so a later start never executes',
        () async {
      final directory = await Directory.systemTemp.createTemp('tombstone-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/assignments.jsonl');
      var executions = 0;
      final (connection, socket) = await connected(
        journal: AssignmentJournal(file),
        handler: (_) async {
          executions += 1;
          return const WorkspaceAssignmentResult(summary: 'must not run');
        },
      );
      socket.controller.add(jsonEncode(envelope(
        'assignment.cancel',
        'assignment-early',
        {'reason': 'startup deadline', 'gracePeriodMs': 1000},
      )));
      await waitFor(
          () => sentOfType(socket, 'assignment.cancel.ack').isNotEmpty);
      final record =
          (await AssignmentJournal(file).reconcile())['assignment-early'];
      expect(record?.status, AssignmentStatus.cancelled);
      expect(record?.attemptId, 'attempt-1');
      expect(record?.workspaceId, 'workspace-1');

      socket.controller.add(jsonEncode(envelope(
        'assignment.start',
        'assignment-early',
        {
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
      )));
      await waitFor(
          () => sentOfType(socket, 'assignment.cancel.ack').length >= 2);
      expect(executions, 0);
      final replay = sentOfType(socket, 'assignment.cancel.ack').last;
      expect((replay['payload'] as Map)['cancelled'], isTrue);
      await connection.close();
    });

    test('repeated restarts replay lost results and preserve cancellation',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('restart-replay-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/assignments.jsonl');
      var executions = 0;
      final journal = AssignmentJournal(file);
      for (final status in [
        AssignmentStatus.completed,
        AssignmentStatus.cancelled,
        AssignmentStatus.running
      ]) {
        await journal.append(AssignmentRecord(
          assignmentId: status.name,
          status: status,
          updatedAt: DateTime.now().toUtc(),
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker-1',
          runId: 'run-1',
          taskId: 'task-1',
          attemptId: 'attempt-1',
          idempotencyKey: 'idem-${status.name}',
          result: status == AssignmentStatus.completed
              ? {
                  'summary': 'durable result',
                  'output': {'text': 'saved'},
                  'artifactIds': <String>[]
                }
              : null,
        ));
      }
      for (var iteration = 0; iteration < 10; iteration++) {
        final reopened = AssignmentJournal(file);
        await reopened.recoverAfterRestart();
        final (connection, socket) = await connected(
          journal: reopened,
          handler: (_) async {
            executions++;
            return const WorkspaceAssignmentResult(summary: 'unexpected');
          },
        );
        try {
          for (final id in ['completed', 'cancelled', 'running']) {
            socket.controller.add(jsonEncode(envelope('assignment.start', id, {
              'objective': 'inspect',
              'role': 'research',
              'workerId': 'conclave.echo',
              'engineVersion': '1.0.0',
              'profileDefinitionId': 'chatgpt-codex',
              'profileReleaseVersion': 1,
              'input': {},
              'contextArtifactIds': [],
              'timeoutMs': 1000,
            })));
          }
          await waitFor(() =>
              sentOfType(socket, 'assignment.result').isNotEmpty &&
              sentOfType(socket, 'assignment.cancel.ack').isNotEmpty &&
              sentOfType(socket, 'assignment.ack')
                  .any((message) => message['assignmentId'] == 'running'));
          final result = sentOfType(socket, 'assignment.result').single;
          expect((result['payload'] as Map)['summary'], 'durable result');
          expect((result['payload'] as Map)['output'], {'text': 'saved'});
          final rejected = sentOfType(socket, 'assignment.ack')
              .singleWhere((message) => message['assignmentId'] == 'running');
          expect((rejected['payload'] as Map)['accepted'], isFalse);
          expect(executions, 0, reason: 'restart $iteration');
          final records = await reopened.reconcile();
          expect(records['completed']!.status, AssignmentStatus.completed);
          expect(records['cancelled']!.status, AssignmentStatus.cancelled);
          expect(
              records['running']!.result?['recoveryState'], 'outcome_unknown');
        } finally {
          // No terminal receipt: the next Service must replay the same result.
          await connection.close();
        }
      }
    });
  });

  test('reconnects after a dropped socket', () async {
    final sockets = <FakeSocket>[FakeSocket(), FakeSocket()];
    final first = sockets.first;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
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

  test('retryNow tears down dead transport and reconnects cleanly', () async {
    final first = FakeSocket();
    final second = FakeSocket();
    final sockets = <FakeSocket>[first, second];
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://gateway.conclave.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => sockets.removeAt(0),
    );
    await connection.connect();
    await completeHandshake(connection, first, sessionId: 'session-1');
    expect(connection.isConnected, isTrue);

    // Simulate dead connection / sleep wake-up where retryNow is triggered
    await connection.retryNow();
    expect(connection.isConnected, isFalse);
    await completeHandshake(connection, second, sessionId: 'session-2');
    expect(connection.isConnected, isTrue);
    expect(connection.sessionId, 'session-2');
    await connection.close();
  });

  test('recovers when factory throws TimeoutException', () async {
    final recovered = FakeSocket();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://gateway.conclave.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 5),
      factory: (_) async {
        attempts++;
        if (attempts == 1) {
          throw TimeoutException('Simulated connect timeout on wake');
        }
        return recovered;
      },
    );
    try {
      await connection.connect();
    } on Object catch (error) {
      expect(error, isA<TimeoutException>());
    }
    expect(connection.connectionStage, WorkspaceConnectionStage.reconnecting);
    expect(connection.lastConnectionError, contains('Connection timed out'));

    await connection.retryNow();
    await waitFor(() => recovered.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'workspace.hello';
        }));
    await completeHandshake(connection, recovered, sessionId: 'recovered');
    expect(connection.isConnected, isTrue);
    await connection.close();
  });

  test('acknowledges a Cloud delivery probe without any assignment', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      localQueueLengthProvider: () => 3,
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-probe-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'diagnostic.probe',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {
        'probeId': 'probe-1',
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      },
    }));
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'diagnostic.probe.ack'));

    final ack = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'diagnostic.probe.ack');
    final payload = ack['payload'] as Map<String, dynamic>;
    expect(ack['correlationId'], 'cloud-probe-1');
    expect(payload['probeId'], 'probe-1');
    expect(DateTime.parse(payload['receivedAt'] as String).isUtc, isTrue);
    expect(
      DateTime.parse(payload['ackedAt'] as String)
          .isBefore(DateTime.parse(payload['receivedAt'] as String)),
      isFalse,
    );
    expect(payload['syncState'], 'ready');
    expect(payload['localQueueLength'], 3);
    expect(payload['activeAssignments'], 0);
    expect(connection.activeAssignmentCount, 0);
    await connection.close();
  });

  test('ignores a probe that has no usable probe ID', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-probe-bad',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'diagnostic.probe',
      'payload': {'sentAt': DateTime.now().toUtc().toIso8601String()},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      socket.sent.any((message) =>
          (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
          'diagnostic.probe.ack'),
      isFalse,
    );
    await connection.close();
  });

  test('traces admission and attaches Service facts to assignment.ack',
      () async {
    final directory = await Directory.systemTemp.createTemp('trace-epoch-');
    addTearDown(() => directory.delete(recursive: true));
    final store = WorkerDiagnosticStore(directory: directory);
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      diagnosticStoreForWorkerType: (_) => store,
      assignmentHandler: (context) async => const WorkspaceAssignmentResult(
        summary: 'done',
        output: {'text': 'ok'},
      ),
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-trace',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-trace-1',
      'idempotencyKey': 'idem-trace-1',
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
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'assignment.result'));

    final ack = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.ack');
    final payload = ack['payload'] as Map<String, dynamic>;
    expect(payload['accepted'], isTrue);
    final serviceTrace = payload['serviceTrace'] as Map<String, dynamic>;
    expect(serviceTrace['syncState'], 'ready');
    expect(serviceTrace['traceEpochId'],
        connection.latencySummary()['traceEpochId']);
    expect(serviceTrace['traceEpochId'],
        matches(RegExp(r'^[A-Za-z0-9._:-]{1,128}$')));
    expect(serviceTrace['activeAssignments'], 1);
    expect(serviceTrace['receiveToAckMs'], isA<int>());

    final intervals = connection.latencySummary()['intervals'] as Map;
    expect(intervals.keys, contains('service_received->service_accepted'));
    // The terminal path releases the open trace.
    expect(connection.traceRecorder.isTracking('assignment-trace-1'), isFalse);
    final records = await store.readSafeRecords();
    final traces =
        records.where((record) => record['stage'] == 'trace').toList();
    expect(traces.length, greaterThanOrEqualTo(2));
    expect(
        traces
            .map((record) => (record['context'] as Map)['traceEpochId'])
            .toSet(),
        {serviceTrace['traceEpochId']});
    await connection.close();
  });

  test('records a heartbeat acknowledgement as a clock-offset sample',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(milliseconds: 100),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'workspace.heartbeat'));
    final heartbeat = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.heartbeat');

    // Cloud clock runs 2 seconds ahead of this machine.
    socket.controller.add(jsonEncode({
      'protocol': 'conclave.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-heartbeat-ack',
      'correlationId': heartbeat['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.heartbeat.ack',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {
        'acknowledged': true,
        'serverTime': DateTime.now()
            .toUtc()
            .add(const Duration(seconds: 2))
            .toIso8601String(),
      },
    }));
    await waitFor(() => connection.clockOffset.hasEstimate);
    expect(connection.clockOffset.offsetMs, inInclusiveRange(1900, 2100));
    await connection.close();
  });

  group('live assignment convergence', () {
    Map<String, dynamic> assignmentStart() => {
          'protocol': 'conclave.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'server-assignment-live',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'workspaceId': 'workspace-1',
          'workspaceRuntimeId': 'workspace-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'assignmentId': 'assignment-live-1',
          'idempotencyKey': 'idem-live-1',
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

    List<Map<String, dynamic>> sentOfType(FakeSocket socket, String type) =>
        socket.sent
            .map((message) =>
                jsonDecode(message as String) as Map<String, dynamic>)
            .where((message) => message['type'] == type)
            .toList();

    Map<String, dynamic> syncStates(String syncRequestId, String status) => {
          'protocol': 'conclave.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'server-sync-$status',
          'correlationId': syncRequestId,
          'workspaceRuntimeId': 'workspace-1',
          'executionWorkspaceId': 'workspace-1',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'workspace.sync.result',
          'payload': {
            'desiredWorkers': [],
            'activeAssignmentIds': ['assignment-live-1'],
            'assignmentStates': [
              {'assignmentId': 'assignment-live-1', 'status': status},
            ],
          },
        };

    Future<
        ({
          WorkspaceCloudConnection connection,
          FakeSocket socket,
          Completer<void> finish,
          String syncRequestId,
        })> liveAssignment() async {
      final socket = FakeSocket();
      final directory =
          await Directory.systemTemp.createTemp('workspace-live-');
      final journal =
          AssignmentJournal(File('${directory.path}/assignments.jsonl'));
      final finish = Completer<void>();
      late WorkspaceCloudConnection connection;
      connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
        workspaceRuntimeId: 'workspace-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        assignmentJournal: journal,
        heartbeat: const Duration(hours: 1),
        assignmentHandler: (context) async {
          await connection.reportWorkerStarted(context);
          await finish.future;
          return const WorkspaceAssignmentResult(
            summary: 'done',
            output: {'text': 'ok'},
          );
        },
      );
      await connection.connect();
      await completeHandshake(connection, socket);
      socket.controller.add(jsonEncode(assignmentStart()));
      await waitFor(
          () => sentOfType(socket, 'assignment.start.ack').isNotEmpty);
      final syncRequestId = sentOfType(socket, 'workspace.sync.request')
          .first['messageId'] as String;
      return (
        connection: connection,
        socket: socket,
        finish: finish,
        syncRequestId: syncRequestId,
      );
    }

    test(
        'a replayed command for a running assignment re-asserts evidence '
        'instead of rejecting it', () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller.add(jsonEncode(assignmentStart()));
      await waitFor(
          () => sentOfType(live.socket, 'assignment.start.ack').isNotEmpty);

      final acks = sentOfType(live.socket, 'assignment.ack');
      expect(acks, hasLength(1));
      expect((acks.single['payload'] as Map)['accepted'], isTrue);
      expect(
        sentOfType(live.socket, 'assignment.start.ack').single['payload'],
        containsPair('providerStarted', true),
      );
      live.finish.complete();
      await live.connection.close();
    });

    test('sync shows Cloud behind: Dispatched needs admission and start',
        () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller
          .add(jsonEncode(syncStates(live.syncRequestId, 'dispatched')));
      await waitFor(
          () => sentOfType(live.socket, 'assignment.start.ack').isNotEmpty);

      expect(sentOfType(live.socket, 'assignment.ack'), hasLength(1));
      live.finish.complete();
      await live.connection.close();
    });

    test('sync shows Cloud Acknowledged: only the start evidence is re-sent',
        () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller
          .add(jsonEncode(syncStates(live.syncRequestId, 'acknowledged')));
      await waitFor(
          () => sentOfType(live.socket, 'assignment.start.ack').isNotEmpty);

      expect(sentOfType(live.socket, 'assignment.ack'), isEmpty);
      live.finish.complete();
      await live.connection.close();
    });

    test('sync never re-asserts when Cloud is already Running', () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller
          .add(jsonEncode(syncStates(live.syncRequestId, 'running')));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(sentOfType(live.socket, 'assignment.ack'), isEmpty);
      expect(sentOfType(live.socket, 'assignment.start.ack'), isEmpty);
      live.finish.complete();
      await live.connection.close();
    });
  });
}

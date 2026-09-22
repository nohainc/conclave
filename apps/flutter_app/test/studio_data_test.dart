import 'dart:convert';

import 'package:conclave_app/src/studio/studio_data.dart';
import 'package:conclave_app/src/studio/studio_models.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

import 'demo_studio_data.dart';
import 'package:conclave_app/src/studio/studio_stores.dart';

class _JsonClient extends http.BaseClient {
  _JsonClient(this.body, {this.statusCode = 201});

  final Map<String, dynamic> body;
  final int statusCode;
  http.BaseRequest? lastRequest;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      statusCode,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

void main() {
  test('loads and clears the Cloud session boundary', () async {
    final client = _JsonClient({
      'authenticated': true,
      'workspaceId': 'workspace-1',
      'workspaceRole': 'member',
      'user': {
        'id': 'user-1',
        'displayName': 'User One',
        'email': 'user@example.test',
      },
    }, statusCode: 200);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    final session = await api.loadSession();
    expect(session.authenticated, isTrue);
    expect(session.viewer?.email, 'user@example.test');
    expect(client.lastRequest?.url.path, '/api/session');

    await api.logout();
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/session/logout');
  });

  test('populates focused stores from the Cloud read model', () async {
    final store = StudioStore(const DemoStudioDataSource());
    final snapshot = await store.reload();

    expect(snapshot.workspaceId, isNull);
    expect(store.projects.items.first.id, 'forge');
    expect(store.chats.items, hasLength(3));
    expect(store.runs.current?.id, 'run-demo');
    expect(store.agents.items.single.id, 'agent-macbook');
    expect(store.workers.items, hasLength(3));
    expect(store.plugins.items, hasLength(6));
    expect(store.usage.tokens, 32500);
    expect(store.usage.costMicros, 650000);
  });

  test('preserves a session viewer when a snapshot omits viewer data',
      () async {
    final store = StudioStore(const DemoStudioDataSource());
    store.auth.viewer = const StudioViewer(
      id: 'user-1',
      displayName: 'User One',
      email: 'user@example.test',
    );

    store.auth.replace(null);

    expect(store.auth.viewer?.id, 'user-1');
  });

  test('normalizes the Cloud chat message envelope', () async {
    final client = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: _JsonClient({
        'message': {
          'id': 'message-1',
          'senderType': 'user',
          'content': 'Fix the bug',
          'createdAt': '2026-09-22T00:00:00Z',
          'metadata': {},
        },
      }),
    );

    final message = await client.sendChatMessage(
      projectId: 'project-1',
      chatId: 'chat-1',
      text: 'Fix the bug',
    );

    expect(message.sender, StudioMessageSender.user);
    expect(message.text, 'Fix the bug');
  });

  test('loads workspaces and scopes Studio snapshots', () async {
    final client = _JsonClient({
      'workspaceId': 'workspace-1',
      'projects': [],
      'workers': [],
      'agents': [],
      'plugins': [],
      'tasks': [],
      'findings': [],
      'events': [],
      'artifacts': [],
      'modelCalls': [],
    }, statusCode: 200);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    // Use separate clients because each response represents a different API.
    final workspaceApi = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: _JsonClient({
        'workspaces': [
          {
            'id': 'workspace-1',
            'name': 'Workspace One',
            'slug': 'workspace-one',
            'status': 'active',
            'role': 'owner',
          },
        ],
      }, statusCode: 200),
    );
    final workspaces = await workspaceApi.loadWorkspaces();
    expect(workspaces.single.name, 'Workspace One');

    await api.loadSnapshot(
      projectId: 'project-1',
      workspaceId: 'workspace-1',
    );
    expect(client.lastRequest?.url.queryParameters, {
      'projectId': 'project-1',
      'workspaceId': 'workspace-1',
    });
  });

  test('normalizes the Cloud chat creation wrapper', () async {
    final client = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: _JsonClient({
        'chat': {
          'id': 'chat-1',
          'projectId': 'project-1',
          'title': 'Auth',
          'status': 'active',
          'updatedAt': '2026-09-22T00:00:00Z',
        },
      }),
    );

    final chat = await client.createChat(
      projectId: 'project-1',
      title: 'Auth',
    );

    expect(chat.id, 'chat-1');
    expect(chat.lastActivity, '2026-09-22T00:00:00Z');
  });

  test('creates a Worker with explicit Agent and Plugin bindings', () async {
    final client = _JsonClient({}, statusCode: 201);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await api.saveWorker(
      workspaceId: 'workspace-1',
      name: 'Codex Main',
      agentId: 'agent-1',
      pluginId: 'plugin-codex',
      roles: const ['implementation'],
      capabilities: const ['repository_write'],
      enabled: true,
      pluginVersionPolicy: 'compatible',
      config: const {'model': 'codex', 'temperature': 0.1},
      sessionPolicy: 'persistent',
      concurrencyLimit: 3,
      billingMode: 'subscription',
      independenceKey: 'codex-main',
    );

    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/workspaces/workspace-1/workers');
    expect(jsonDecode(client.lastBody!)['agentId'], 'agent-1');
    expect(jsonDecode(client.lastBody!)['pluginId'], 'plugin-codex');
    expect(jsonDecode(client.lastBody!)['pluginVersionPolicy'], 'compatible');
    expect(jsonDecode(client.lastBody!)['config']['model'], 'codex');
    expect(jsonDecode(client.lastBody!)['sessionPolicy'], 'persistent');
    expect(jsonDecode(client.lastBody!)['concurrencyLimit'], 3);
    expect(jsonDecode(client.lastBody!)['billingMode'], 'subscription');
    expect(jsonDecode(client.lastBody!)['independenceKey'], 'codex-main');
  });

  test('updates Worker configuration and bindings', () async {
    final client = _JsonClient({}, statusCode: 200);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await api.saveWorker(
      workspaceId: 'workspace-1',
      workerId: 'worker-1',
      name: 'Codex Main',
      agentId: 'agent-1',
      pluginId: 'plugin-codex',
      roles: const ['reviewer'],
      capabilities: const ['code_review'],
      enabled: false,
      config: const {'model': 'claude'},
    );

    expect(client.lastRequest?.method, 'PUT');
    expect(client.lastRequest?.url.path,
        '/api/workspaces/workspace-1/workers/worker-1');
    expect(jsonDecode(client.lastBody!)['enabled'], false);
    expect(jsonDecode(client.lastBody!)['roles'], ['reviewer']);
    expect(jsonDecode(client.lastBody!)['agentId'], 'agent-1');
    expect(jsonDecode(client.lastBody!)['pluginId'], 'plugin-codex');
    expect(jsonDecode(client.lastBody!)['config']['model'], 'claude');
  });

  test('parses full Worker desired state from the Cloud read model', () {
    final worker = StudioWorker.fromJson({
      'id': 'worker-1',
      'name': 'Codex Main',
      'pluginVersionPolicy': 'compatible',
      'config': {'model': 'codex'},
      'sessionPolicy': 'persistent',
      'concurrencyLimit': 4,
      'billingMode': 'subscription',
      'independenceKey': 'codex-main',
      'costMetadata': {'estimatedCostMicrosPerAttempt': null},
    });

    expect(worker.pluginVersionPolicy, 'compatible');
    expect(worker.config['model'], 'codex');
    expect(worker.sessionPolicy, 'persistent');
    expect(worker.concurrencyLimit, 4);
    expect(worker.billingMode, 'subscription');
    expect(worker.independenceKey, 'codex-main');
  });
}

import 'dart:convert';

import 'package:conclave_app/src/studio/studio_data.dart';
import 'package:conclave_app/src/studio/studio_models.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

import 'studio_fixture_data.dart';
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

class _ReadModelClient extends http.BaseClient {
  _ReadModelClient(this.responses);

  final Map<String, Map<String, dynamic>> responses;
  final requests = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url.path);
    final body = responses[request.url.path] ?? const <String, dynamic>{};
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
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
      'pendingInvitations': [
        {
          'id': 'inv-1',
          'workspaceId': 'workspace-team',
          'role': 'member',
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      ],
    }, statusCode: 200);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    final session = await api.loadSession();
    expect(session.authenticated, isTrue);
    expect(session.viewer?.email, 'user@example.test');
    expect(session.pendingInvitations.single.id, 'inv-1');
    expect(client.lastRequest?.url.path, '/api/session');

    await api.logout();
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/auth/sign-out');
  });

  test('populates focused stores from the Cloud read model', () async {
    final store = StudioStore(const StudioFixtureDataSource());
    final snapshot = await store.reload();

    expect(snapshot.workspaceId, isNull);
    expect(store.projects.items.first.id, 'forge');
    expect(store.chats.items, hasLength(3));
    expect(store.runs.current?.id, 'run-fixture');
    expect(store.agents.items.single.id, 'agent-macbook');
    expect(store.workers.items, hasLength(3));
    expect(store.plugins.items, hasLength(6));
    expect(store.usage.tokens, 32500);
    expect(store.usage.costMicros, 650000);
  });

  test('preserves a session viewer when a snapshot omits viewer data',
      () async {
    final store = StudioStore(const StudioFixtureDataSource());
    store.auth.viewer = const StudioViewer(
      id: 'user-1',
      displayName: 'User One',
      email: 'user@example.test',
    );

    store.auth.replace(null);

    expect(store.auth.viewer?.id, 'user-1');
  });

  test('normalizes the Cloud chat message envelope', () async {
    final requestClient = _JsonClient({
      'message': {
        'id': 'message-1',
        'senderType': 'user',
        'content': 'Fix the bug',
        'createdAt': '2026-09-22T00:00:00Z',
        'metadata': {},
      },
    });
    final client = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: requestClient,
    );

    final message = await client.sendChatMessage(
      projectId: 'project-1',
      chatId: 'chat-1',
      text: 'Fix the bug',
    );

    expect(message.sender, StudioMessageSender.user);
    expect(message.text, 'Fix the bug');
    expect(requestClient.lastRequest?.url.path, '/api/chats/chat-1/messages');
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

  test('composes focused read models without the workspace snapshot', () async {
    final client = _ReadModelClient({
      '/api/projects': {
        'projects': [
          {
            'id': 'project-1',
            'name': 'Project One',
            'repository': 'repo',
            'activeGoals': 0,
            'lastActivity': 'today',
          },
        ],
      },
      '/api/workspaces/workspace-1/hosts': {'hosts': []},
      '/api/workspaces/workspace-1/workers': {'workers': []},
      '/api/workspaces/workspace-1/accounts': {'accounts': []},
      '/api/workspaces/workspace-1/usage': {'usage': []},
      '/api/projects/project-1/read-model': {
        'workspaceId': 'workspace-1',
        'project': {
          'id': 'project-1',
          'name': 'Project One',
          'repository': 'repo',
          'activeGoals': 0,
          'lastActivity': 'today',
          'chats': [
            {
              'id': 'chat-1',
              'projectId': 'project-1',
              'title': 'Chat',
              'lastActivity': 'today',
              'messages': [],
            },
          ],
        },
        'tasks': [],
        'findings': [],
        'events': [],
        'artifacts': [],
        'modelCalls': [],
      },
    });
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    )..setActiveWorkspace('workspace-1');

    final readModel = await api.loadReadModels();

    expect(readModel.projects.single.chats.single.id, 'chat-1');
    expect(client.requests, isNot(contains('/api/studio/snapshot')));
    expect(client.requests, contains('/api/projects/project-1/read-model'));
    expect(client.requests, contains('/api/workspaces/workspace-1/usage'));
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

  test('returns the created Project from the Cloud response', () async {
    final client = _JsonClient({
      'project': {
        'id': 'project-created',
        'workspaceId': 'workspace-1',
        'name': 'Authentication redesign',
        'description': 'Improve the sign-in flow',
        'repositoryId': 'repo-1',
        'updatedAt': '2026-09-23T00:00:00Z',
      },
    });
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    final project = await api.createProject(
      name: 'Authentication redesign',
      description: 'Improve the sign-in flow',
    );

    expect(project.id, 'project-created');
    expect(project.name, 'Authentication redesign');
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/projects');
  });

  test('rejects removed configured Worker writes', () async {
    final client = _JsonClient({}, statusCode: 200);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await expectLater(
      api.saveWorker(
        workspaceId: 'workspace-1',
        name: 'Codex Main',
        agentId: 'agent-1',
        workerCatalogId: 'worker-codex',
        roles: const ['reviewer'],
        capabilities: const ['code_review'],
        enabled: false,
      ),
      throwsA(isA<StudioApiException>().having(
        (error) => error.message,
        'message',
        contains('Configured Worker instances were removed'),
      )),
    );
    expect(client.lastRequest, isNull);
  });

  test('parses full Worker desired state from the Cloud read model', () {
    final worker = StudioWorker.fromJson({
      'id': 'worker-1',
      'name': 'Codex Main',
      'workerVersionPolicy': 'compatible',
      'config': {'model': 'codex'},
      'sessionPolicy': 'persistent',
      'concurrencyLimit': 4,
      'billingMode': 'subscription',
      'independenceKey': 'codex-main',
      'costMetadata': {'estimatedCostMicrosPerAttempt': null},
    });

    expect(worker.workerVersionPolicy, 'compatible');
    expect(worker.config['model'], 'codex');
    expect(worker.sessionPolicy, 'persistent');
    expect(worker.concurrencyLimit, 4);
    expect(worker.billingMode, 'subscription');
    expect(worker.independenceKey, 'codex-main');
  });

  test('parses v4 Hosts and Credential Profiles from the read model', () {
    final snapshot = StudioSnapshot.fromJson({
      'workspaceId': 'workspace-1',
      'hosts': [
        {
          'id': 'host-1',
          'name': 'Mac Host',
          'hostname': 'mac.local',
          'status': 'online',
          'version': '4.0.0',
          'workerCount': 2,
          'workspaceBindings': ['workspace-1', 'workspace-2'],
        },
      ],
      'accounts': [
        {
          'id': 'profile-1',
          'displayName': 'Personal Codex',
          'owner': 'user-1',
          'worker': 'codex',
          'host': 'host-1',
          'sharingPolicy': 'private_only',
          'status': 'ready',
          'usage': '1.2k tokens',
        },
      ],
    });

    expect(snapshot.agents.single.name, 'Mac Host');
    expect(snapshot.agents.single.workspaceBindings,
        ['workspace-1', 'workspace-2']);
    expect(snapshot.accounts.single.displayName, 'Personal Codex');
    expect(snapshot.accounts.single.sharing, 'private_only');
  });

  test('announces an Agent update through the Cloud management endpoint',
      () async {
    final client = _JsonClient({}, statusCode: 200);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await api.announceAgentUpdate(
      workspaceId: 'workspace-1',
      agentId: 'agent-1',
      channel: 'stable',
    );

    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path,
        '/api/workspaces/workspace-1/hosts/agent-1/update');
    expect(jsonDecode(client.lastBody!)['channel'], 'stable');
  });

  test('uses Host paths for enrollment and revocation', () async {
    final client = _JsonClient({
      'enrollment': {
        'id': 'enrollment-1',
        'token': 'token-1',
        'workspaceId': 'workspace-1',
        'expiresAt': '2099-01-01T00:00:00Z',
      },
    }, statusCode: 200);
    final api = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await api.createHostEnrollment(workspaceId: 'workspace-1');
    expect(client.lastRequest?.url.path,
        '/api/workspaces/workspace-1/host-enrollments');

    await api.revokeAgent(workspaceId: 'workspace-1', agentId: 'host-1');
    expect(client.lastRequest?.method, 'DELETE');
    expect(client.lastRequest?.url.path,
        '/api/workspaces/workspace-1/hosts/host-1');
  });

  test('sends the explicitly selected Workspace on scoped requests', () async {
    final client = _JsonClient({
      'workspaceId': 'workspace-2',
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
    )..setActiveWorkspace('workspace-2');

    await api.loadSnapshot();

    expect(
        client.lastRequest?.headers['x-conclave-workspace-id'], 'workspace-2');
  });
}

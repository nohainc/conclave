import 'dart:convert';

import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';

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

class _ApiResponseClient extends http.BaseClient {
  _ApiResponseClient(this.responses);

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
  test('reads canonical execution error details for Ax tasks', () {
    final task = AxTask.fromJson({
      'id': 'task-error',
      'title': 'Implement feature',
      'phase': 'Execution',
      'status': 'failed',
      'worker': 'ChatGPT',
      'detail': 'Implement feature',
      'progress': 0,
      'dependencies': <String>[],
      'errorCode': 'authentication_required',
      'errorMessage': 'Sign in to the configured provider on this computer.',
    });

    expect(task.status, TaskStatus.failed);
    expect(task.errorCode, 'authentication_required');
    expect(task.errorMessage,
        'Sign in to the configured provider on this computer.');
  });

  test('approves desktop sign-in without a comparison code', () async {
    final client = _JsonClient(const <String, dynamic>{}, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await api.approveDesktopAuthIntent(intentId: 'intent-a');

    expect(client.lastRequest?.method, 'POST');
    expect(
      client.lastRequest?.url.path,
      '/api/desktop-auth/intents/intent-a/approve',
    );
    expect(jsonDecode(client.lastBody!), isEmpty);
  });

  test('reads non-secret desktop sign-in status for browser cleanup', () async {
    final client = _JsonClient({'status': 'denied'}, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    expect(
      await api.loadDesktopAuthIntentStatus(intentId: 'intent-a'),
      'denied',
    );
    expect(
      client.lastRequest?.url.path,
      '/api/desktop-auth/intents/intent-a/browser-status',
    );
  });

  test('cancels desktop sign-in from the authenticated browser', () async {
    final client = _JsonClient(const <String, dynamic>{}, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await api.denyDesktopAuthIntent(intentId: 'intent-a');
    expect(client.lastRequest?.method, 'POST');
    expect(
      client.lastRequest?.url.path,
      '/api/desktop-auth/intents/intent-a/deny',
    );
  });

  test('loads and clears the Cloud session boundary', () async {
    final client = _JsonClient({
      'authenticated': true,
      'user': {
        'id': 'user-1',
        'displayName': 'User One',
        'email': 'user@example.test',
      },
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    final session = await api.loadSession();
    expect(session.authenticated, isTrue);
    expect(session.viewer?.email, 'user@example.test');
    expect(client.lastRequest?.url.path, '/api/session');

    await api.logout();
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/auth/sign-out');
  });

  test('populates focused stores from the Cloud read model', () async {
    final store = AxStore(const AxFixtureDataSource());
    final snapshot = await store.reload();

    expect(snapshot.workspaceId, isNull);
    expect(store.projects.items.first.id, 'project-auth');
    expect(store.runs.current?.id, 'run-fixture');
    expect(store.workspaces.items.single.id, 'workspace-macbook');
    expect(store.workspaces.items, hasLength(1));
  });

  test('preserves a session viewer when a snapshot omits viewer data',
      () async {
    final store = AxStore(const AxFixtureDataSource());
    store.auth.viewer = const AxViewer(
      id: 'user-1',
      displayName: 'User One',
      email: 'user@example.test',
    );

    store.auth.replace(null);

    expect(store.auth.viewer?.id, 'user-1');
  });

  test('returns the created Project from the Cloud response', () async {
    final client = _JsonClient({
      'project': {
        'id': 'project-created',
        'workspaceId': 'workspace-1',
        'name': 'Authentication redesign',
        'description': 'Improve the sign-in flow',
        'updatedAt': '2026-09-23T00:00:00Z',
      },
    });
    final api = AxApiClient(
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

  test('persists Project instructions through the explicit update field',
      () async {
    final client = _JsonClient({
      'project': {
        'id': 'project-1',
        'name': 'Project',
        'description': '',
        'instructions': 'Use the team conventions.',
        'settings': {'instructions': 'Use the team conventions.'},
      },
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    final project = await api.updateProject(
      projectId: 'project-1',
      instructions: 'Use the team conventions.',
    );

    final payload = jsonDecode(client.lastBody!) as Map<String, dynamic>;
    expect(payload['instructions'], 'Use the team conventions.');
    expect((payload['settings'] as Map)['instructions'],
        'Use the team conventions.');
    expect(project.instructions, 'Use the team conventions.');
  });

  test('composes AX state from current Project and Workspace APIs', () async {
    final client = _ApiResponseClient({
      '/api/session': {
        'authenticated': true,
        'user': {
          'id': 'user-1',
          'displayName': 'User One',
          'email': 'user@example.test',
        },
      },
      '/api/projects': {
        'projects': [
          {'id': 'project-1', 'name': 'Project One', 'lastActivity': 'today'},
        ],
      },
      '/api/workspaces': {'workspaces': []},
      '/api/projects/project-1': {
        'project': {
          'id': 'project-1',
          'name': 'Project One',
          'lastActivity': 'today',
        },
      },
      '/api/projects/project-1/workstreams': {
        'workstreams': [
          {
            'id': 'workstream-1',
            'projectId': 'project-1',
            'name': 'Authentication',
            'lead': 'Owner',
            'status': 'active',
            'brief': 'Improve authentication.',
            'primaryWorkspace': 'Workspace One',
            'queueStatus': 'Idle',
          },
        ],
      },
    });
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    final state = await api.loadReadModels(workspaceId: 'workspace-1');

    expect(state.viewer?.id, 'user-1');
    expect(state.projects.single.workstreams.single.id, 'workstream-1');
    expect(client.requests, contains('/api/projects'));
    expect(client.requests, contains('/api/projects/project-1'));
    expect(client.requests, contains('/api/projects/project-1/workstreams'));
    expect(client.requests, contains('/api/workspaces'));
    expect(client.requests, contains('/api/session'));
  });

  test('parses Workspace runtime facts', () {
    final snapshot = AxSnapshot.fromJson({
      'workspaceId': 'workspace-1',
      'workspaces': [
        {
          'id': 'workspace-runtime-1',
          'name': 'Build Workspace',
          'hostname': 'mac.local',
          'status': 'online',
          'appVersion': '4.0.0',
          'workerCount': 2,
          'platform': 'macos',
        },
      ],
      'workers': [
        {'id': 'obsolete-worker'},
      ],
    });

    expect(snapshot.workspaces, hasLength(1));
    expect(snapshot.workspaces.single.name, 'Build Workspace');
    expect(snapshot.workspaces.single.appVersion, '4.0.0');
    expect(snapshot.workspaces.single.platform, 'macos');
  });

  test('parses only the safe Workspace Worker projection', () {
    final worker = AxWorker.fromJson({
      'id': 'worker-codex',
      'workspaceId': 'workspace-1',
      'workspaceName': 'Build Mac',
      'workerTypeId': 'chatgpt',
      'displayName': 'ChatGPT',
      'status': 'ready',
      'readinessState': 'ready',
      'localConcurrencyLimit': 2,
      'capabilities': ['code'],
      'name': 'must-not-be-retained',
      'apiKey': 'must-not-be-retained',
    });

    expect(worker.workspaceId, 'workspace-1');
    expect(worker.workerTypeId, 'chatgpt');
    expect(worker.localConcurrencyLimit, 2);
    expect(worker.attentionReasonCode, isNull);
  });

  test('uses Workspace management routes for rename and invitations', () async {
    final client = _JsonClient({
      'workspace': {
        'id': 'workspace-1',
        'name': 'Updated Workspace',
        'slug': 'updated-workspace',
        'status': 'active',
        'role': 'owner',
      },
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    final workspace = await api.updateWorkspace(
        workspaceId: 'workspace-1', name: 'Updated Workspace');
    expect(workspace.name, 'Updated Workspace');
    expect(client.lastRequest?.method, 'PATCH');
    expect(client.lastRequest?.url.path, '/api/workspaces/workspace-1');

    await api.inviteWorkspaceMember(
        workspaceId: 'workspace-1',
        email: 'member@example.test',
        role: 'member');
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path,
        '/api/workspaces/workspace-1/invitations');
    expect(jsonDecode(client.lastBody!)['email'], 'member@example.test');
  });

  test('does not send obsolete Workspace security headers', () async {
    final client = _JsonClient({
      'workspaceId': 'workspace-2',
      'projects': [],
      'workspaces': [],
      'tasks': [],
      'findings': [],
      'events': [],
      'artifacts': [],
      'modelCalls': [],
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    await api.loadReadModels();

    expect(client.lastRequest?.headers.containsKey('x-conclave-workspace-id'),
        isFalse);
  });
}

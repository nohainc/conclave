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
  test(
      'Chat defaults omit model and effort overrides and send the plain workflow ID',
      () async {
    final client = _JsonClient({
      'workRequest': {'id': 'request-default'}
    });
    final api =
        AxApiClient(baseUrl: 'https://conclave.test/api', client: client);
    await api.createWorkRequest(
        workstreamId: 'stream', workflowId: 'chat', prompt: 'Hello');
    final body = jsonDecode(client.lastBody!) as Map;
    expect(body['workflowId'], 'chat');
    expect(body.containsKey('model'), false);
    expect(body.containsKey('reasoningEffort'), false);
    expect((body['input'] as Map)['originalRequest'], 'Hello');
  });
  test('Work submission exposes the server reason for a 400', () async {
    final client =
        _JsonClient({'error': 'Unsupported workflowId'}, statusCode: 400);
    final api =
        AxApiClient(baseUrl: 'https://conclave.test/api', client: client);
    expect(
        () => api.createWorkRequest(
            workstreamId: 'stream', workflowId: 'chat', prompt: 'Hello'),
        throwsA(isA<AxApiException>().having(
            (e) => e.message, 'reason', contains('Unsupported workflowId'))));
  });

  test('Workspace list reads aggregate grant counts with one HTTP request',
      () async {
    final client = _ApiResponseClient({
      '/api/workspaces': {
        'workspaces': [
          {'id': 'owned', 'name': 'Owned', 'activeProjectGrantCount': 30},
          {'id': 'legacy', 'name': 'Legacy', 'projectGrantCount': 2},
          {'id': 'empty', 'name': 'Empty'},
        ]
      }
    });
    final api =
        AxApiClient(baseUrl: 'https://conclave.test/api', client: client);
    final values = await api.loadWorkspaces();
    expect(values.map((w) => w.projectGrantCount), [30, 2, 0]);
    expect(client.requests, ['/api/workspaces']);
  });
  test('single Work Request details retain identity and authored result',
      () async {
    final client = _JsonClient({
      'workRequest': {
        'id': 'r',
        'status': 'completed',
        'originalRequest': '# Prompt',
        'workflowId': 'direct',
        'workflowVersion': 2,
        'createdAt': '2026-10-06T00:00:00Z'
      },
      'result': {'text': '# Result'},
      'steps': []
    });
    final api = AxApiClient(baseUrl: 'https://example.test', client: client);
    final result = await api.loadWorkRequest(workRequestId: 'r');
    expect(client.lastRequest!.url.path, '/work-requests/r');
    expect(result.id, 'r');
    expect(result.text, '# Result');
    expect(result.originalRequest, '# Prompt');
    await expectLater(api.loadWorkRequest(workRequestId: 'other'),
        throwsA(isA<AxApiException>()));
  });

  test('Work history HTTP loads only one bounded page with typed cursors',
      () async {
    final client = _JsonClient({
      'workRequests': [
        {
          'id': 'b',
          'createdAt': '2026-10-06T02:00:00Z',
          'prompt': '# Exact Markdown'
        },
        {'id': 'a', 'createdAt': '2026-10-06T01:00:00Z'}
      ],
      'nextCursor': {'createdAt': '2026-10-06T01:00:00Z', 'id': 'a'}
    });
    final api = AxApiClient(baseUrl: 'https://example.test', client: client);
    final page = await api.loadWorkstreamWorkRequestPage(
        workstreamId: 'w',
        limit: 40,
        beforeCreatedAt: '2026-10-07T00:00:00Z',
        beforeId: 'id+/=',
        activeOnly: true);
    expect(client.lastRequest!.url.queryParameters, {
      'limit': '40',
      'beforeCreatedAt': '2026-10-07T00:00:00Z',
      'beforeId': 'id+/=',
      'activeOnly': 'true'
    });
    expect(page.requests.map((r) => r.id), ['a', 'b']);
    expect(page.requests.last.prompt, '# Exact Markdown');
    expect(page.nextCursor!.id, 'a');
    expect(() => page.requests.clear(), throwsUnsupportedError);
    await expectLater(
        api.loadWorkstreamWorkRequestPage(workstreamId: 'w', beforeId: 'a'),
        throwsArgumentError);
    await expectLater(
        api.loadWorkstreamWorkRequestPage(workstreamId: 'w', limit: 101),
        throwsArgumentError);
  });
  for (final body in [
    <String, dynamic>{
      'workRequests': [],
      'nextCursor': {'id': 'x'}
    },
    <String, dynamic>{
      'workRequests': [null]
    },
    <String, dynamic>{
      'workRequests': [
        {'id': 'x'}
      ]
    },
  ]) {
    test('Work history rejects malformed page $body', () async {
      final api = AxApiClient(
          baseUrl: 'https://example.test', client: _JsonClient(body));
      await expectLater(api.loadWorkstreamWorkRequestPage(workstreamId: 'w'),
          throwsA(isA<AxApiException>()));
    });
  }

  test(
      'Discussion paging uses bounded query parameters and exposes server cursors',
      () async {
    final client = _JsonClient({
      'schemaVersion': 1,
      'messages': [
        {
          'id': 'm1',
          'workstreamId': 'w',
          'authorUserId': 'u',
          'body': '  **source**\n',
          'createdAt': '2026-10-06T00:00:00.000Z'
        }
      ],
      'nextCursor': 'older',
      'newestCursor': 'newest'
    }, statusCode: 200);
    final api =
        AxApiClient(baseUrl: 'https://conclave.test/api', client: client);
    final page = await api.loadDiscussionPage(
        workstreamId: 'w', limit: 30, before: 'cursor+/=');
    expect(
        client.lastRequest!.url.path, '/api/workstreams/w/discussion-messages');
    expect(client.lastRequest!.url.queryParameters,
        {'limit': '30', 'before': 'cursor+/='});
    expect(page.messages.single.body, '  **source**\n');
    expect(page.nextCursor, 'older');
    expect(page.newestCursor, 'newest');
    expect(() => page.messages.clear(), throwsUnsupportedError);
    await expectLater(api.loadDiscussionPage(workstreamId: 'w', limit: 0),
        throwsArgumentError);
    await expectLater(
        api.loadDiscussionPage(workstreamId: 'w', before: 'a', after: 'b'),
        throwsArgumentError);
  });
  test(
      'Discussion envelope error identifies incompatible schema without message content',
      () async {
    final api = AxApiClient(
        baseUrl: 'https://conclave.test/api',
        client: _JsonClient({
          'messages': [
            {'body': 'Private Chat'}
          ]
        }, statusCode: 200));
    await expectLater(
        api.loadDiscussionPage(workstreamId: 'w'),
        throwsA(isA<AxApiException>().having(
            (error) => error.message,
            'message',
            allOf(contains('expected schemaVersion 1, received missing'),
                isNot(contains('Private Chat'))))));
  });
  for (final response in [
    <String, dynamic>{'messages': []},
    {'schemaVersion': 1, 'messages': [], 'nextCursor': 4},
    {
      'schemaVersion': 1,
      'messages': ['invalid']
    },
    {
      'schemaVersion': 1,
      'messages': [
        {'id': 'm1', 'workstreamId': 'different'}
      ]
    }
  ]) {
    test(
        'Discussion paging rejects malformed or cross-Workstream data $response',
        () async {
      final api = AxApiClient(
          baseUrl: 'https://conclave.test/api',
          client: _JsonClient(response, statusCode: 200));
      await expectLater(api.loadDiscussionPage(workstreamId: 'w'),
          throwsA(isA<AxApiException>()));
    });
  }

  test(
      'focused Project loader uses the detail endpoint without bootstrap reads',
      () async {
    final client = _ApiResponseClient({
      '/api/projects/p1': {
        'project': {
          'id': 'p1',
          'name': 'Details',
          'settings': {'instructions': 'Detailed instructions'},
          'workstreams': [
            {'id': 'w1', 'projectId': 'p1'}
          ]
        }
      }
    });
    final api =
        AxApiClient(baseUrl: 'https://conclave.test/api', client: client);
    final project = await api.loadProject(projectId: 'p1');
    expect(project.instructions, 'Detailed instructions');
    expect(project.workstreams, isEmpty);
    expect(client.requests, ['/api/projects/p1']);
  });

  for (final response in [
    <String, dynamic>{},
    {'project': []},
    {
      'project': {'id': 'different', 'name': 'Wrong Project'}
    }
  ]) {
    test(
        'focused Project loader rejects malformed/mismatched response $response',
        () async {
      final client = _ApiResponseClient({'/api/projects/p1': response});
      final api =
          AxApiClient(baseUrl: 'https://conclave.test/api', client: client);
      await expectLater(
          api.loadProject(projectId: 'p1'), throwsA(isA<AxApiException>()));
    });
  }

  test(
      'canonical inventory readiness determines availability without legacy status',
      () {
    final inventory = <String, dynamic>{
      'workerId': 'worker-chatgpt',
      'workerTypeId': 'chatgpt',
      'workspaceId': 'workspace-test',
      'displayName': 'ChatGPT',
      'activationState': 'enabled',
      'readinessState': 'ready'
    };
    final ready = AxWorker.fromJson(inventory);
    expect(ready.isReady, isTrue);
    expect(ready.status, 'ready');
    expect(
        AxWorker.fromJson({...inventory, 'activationState': 'disabled'})
            .isReady,
        isFalse);
    expect(
        AxWorker.fromJson({
          ...inventory,
          'readinessState': 'worker_runtime_unavailable',
          'readinessIssueCode': 'tool_profile_unavailable'
        }).isReady,
        isFalse);
  });
  test('read errors preserve the server diagnostic and HTTP status', () async {
    final api = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: _JsonClient({'error': 'ambiguous column name: updated_at'},
            statusCode: 400));
    await expectLater(
        api.loadProjectWorkstreams(projectId: 'project-test'),
        throwsA(isA<AxApiException>()
            .having((e) => e.statusCode, 'status', 400)
            .having((e) => e.message, 'message',
                contains('ambiguous column name: updated_at'))));
  });
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
    final client = _JsonClient({
      'status': 'denied',
      'clientName': 'Conclave Profile Lab',
      'audience': 'conclave.profile-lab.management',
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://conclave.test/api',
      client: client,
    );

    expect(
      await api.loadDesktopAuthIntentStatus(intentId: 'intent-a'),
      const AxDesktopAuthIntentStatus(
        status: 'denied',
        clientName: 'Conclave Profile Lab',
        audience: 'conclave.profile-lab.management',
      ),
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

    api.sessionToken = 'fixture-session';
    await api.logout();
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/auth/sign-out');
    expect(client.lastRequest?.headers['content-type'], 'application/json');
    expect(
        client.lastRequest?.headers['authorization'], 'Bearer fixture-session');
    expect(jsonDecode(client.lastBody!), isEmpty);
    expect(api.sessionToken, isNull);
  });

  test('failed logout preserves the session for retry', () async {
    final api = AxApiClient(
        baseUrl: 'https://conclave.test/api',
        client: _JsonClient({}, statusCode: 503));
    api.sessionToken = 'fixture-session';
    await expectLater(api.logout(), throwsA(isA<AxApiException>()));
    expect(api.sessionToken, 'fixture-session');
  });

  test('populates focused stores from the Cloud read model', () async {
    final store = AxStore(const AxFixtureDataSource());
    final snapshot = await store.loadBootstrapState();

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

    final state = await api.loadBootstrapState(workspaceId: 'workspace-1');

    expect(state.viewer?.id, 'user-1');
    expect(state.projects.single.workstreams, isEmpty);
    expect(client.requests, contains('/api/projects'));
    expect(client.requests, isNot(contains('/api/projects/project-1')));
    expect(client.requests,
        isNot(contains('/api/projects/project-1/workstreams')));
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

    await api.loadBootstrapState();

    expect(client.lastRequest?.headers.containsKey('x-conclave-workspace-id'),
        isFalse);
  });
}

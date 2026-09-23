import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/passkey_browser_stub.dart'
    if (dart.library.html) '../auth/passkey_browser_web.dart' as passkeys;
import '../platform/http_client_stub.dart'
    if (dart.library.html) '../platform/http_client_web.dart' as platform;
import 'studio_models.dart';

abstract interface class StudioDataSource {
  void setActiveWorkspace(String? workspaceId);
  Future<StudioSession> loadSession();
  Future<void> logout();
  Future<void> signInWithEmail({
    required String email,
    required String password,
  });
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  });
  Future<void> requestPasswordReset({required String email});
  Future<void> resetPassword({
    required String token,
    required String password,
  });
  Future<void> createProject({
    required String name,
    String? description,
  });
  Future<StudioAccountSecurity> loadAccountSecurity();
  Future<void> revokeAccountSession(String token);
  Future<Uri> beginAccountLink(String provider, Uri returnTo);
  Future<void> registerPasskey(String name);
  Future<void> deletePasskey(String id);
  Future<void> signInWithPasskey();
  Future<List<StudioWorkspace>> loadWorkspaces();

  /// Loads the focused Workspace/project read models in parallel. The legacy
  /// snapshot remains available for compatibility and fixtures only.
  Future<StudioSnapshot> loadReadModels(
      {String? projectId, String? workspaceId});
  Future<StudioSnapshot> loadSnapshot({String? projectId, String? workspaceId});
  Future<void> controlRun(String runId, String command);
  Future<void> respondToRunPrompt(String runId, String response);
  Future<void> createGoal({
    required String projectId,
    required String objective,
    required String revision,
  });
  Future<StudioChatMessage> sendChatMessage({
    required String projectId,
    required String chatId,
    required String text,
  });
  Future<StudioChat> createChat({
    required String projectId,
    required String title,
  });
  Future<void> setWorkerEnabled({
    required String workspaceId,
    required String workerId,
    required bool enabled,
  });
  Future<void> requestCredentialSetup({
    required String workspaceId,
    required String profileId,
    String action = 'reauthenticate',
  });
  Future<void> revokeCredentialProfile({
    required String workspaceId,
    required String profileId,
  });
  Future<void> revokeAgent({
    required String workspaceId,
    required String agentId,
  });
  Future<void> announceAgentUpdate({
    required String workspaceId,
    required String agentId,
    String? channel,
    String? version,
  });
  Future<StudioHostEnrollment> createHostEnrollment({
    required String workspaceId,
    int expiresHours = 24,
  });
  Future<void> saveWorker({
    required String workspaceId,
    String? workerId,
    required String name,
    required String agentId,
    required String workerCatalogId,
    required List<String> roles,
    required List<String> capabilities,
    required bool enabled,
    String workerVersionPolicy = 'latest',
    Map<String, dynamic> config = const {},
    String sessionPolicy = 'stateless',
    int concurrencyLimit = 1,
    String billingMode = 'local_compute',
    String independenceKey = '',
    Map<String, dynamic> costMetadata = const {},
  });
}

class StudioApiException implements Exception {
  const StudioApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

Map<String, dynamic> _studioChatMessageFromApi(Map<String, dynamic> json) {
  final senderType = json['senderType'] ?? json['sender'];
  final sender = switch (senderType) {
    'user' => 'user',
    'system' => 'system',
    _ => 'conclave',
  };
  final metadata = json['metadata'];
  return {
    'id': json['id'],
    'sender': sender,
    'text': json['content'] ?? json['text'] ?? '',
    'timestamp': json['createdAt'] ?? json['timestamp'] ?? '',
    if (metadata is Map && metadata['runPreview'] != null)
      'runPreview': metadata['runPreview'],
  };
}

Map<String, dynamic> _studioChatFromApi(Map<String, dynamic> json) {
  return {
    ...json,
    'lastActivity': json['lastActivity'] ?? json['updatedAt'] ?? '',
    'messages': (json['messages'] as List? ?? const [])
        .map((message) => _studioChatMessageFromApi(
            Map<String, dynamic>.from(message as Map)))
        .toList(),
  };
}

class StudioApiClient implements StudioDataSource {
  StudioApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ??
            (const String.fromEnvironment('CONCLAVE_API_URL').isNotEmpty
                ? const String.fromEnvironment('CONCLAVE_API_URL')
                : platform.defaultStudioApiBaseUrl()),
        client = client ?? platform.createPlatformHttpClient();

  final String baseUrl;
  final http.Client client;
  final passkeyBrowser = passkeys.createStudioPasskeyBrowser();
  String? activeWorkspaceId;

  @override
  void setActiveWorkspace(String? workspaceId) {
    activeWorkspaceId = workspaceId;
  }

  Map<String, String> _headers({String? contentType}) => {
        'accept': 'application/json',
        if (contentType != null) 'content-type': contentType,
        if (activeWorkspaceId != null)
          'x-conclave-workspace-id': activeWorkspaceId!,
      };

  @override
  Future<StudioSession> loadSession() async {
    final response =
        await client.get(Uri.parse('$baseUrl/session'), headers: _headers());
    if (response.statusCode == 401) {
      return const StudioSession(authenticated: false);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Session lookup failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    return StudioSession.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> logout() async {
    final response = await client.post(Uri.parse('$baseUrl/auth/sign-out'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Logout failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  Future<void> _postAuth(String path, Map<String, dynamic> body) async {
    final response = await client.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'Authentication request failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['message'] is String) {
          message = decoded['message'] as String;
        } else if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } catch (_) {
        // Keep the status-based message for non-JSON responses.
      }
      throw StudioApiException(message, statusCode: response.statusCode);
    }
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) =>
      _postAuth('/auth/sign-in/email', {
        'email': email,
        'password': password,
      });

  @override
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  }) =>
      _postAuth('/auth/sign-up/email', {
        'name': name,
        'email': email,
        'password': password,
      });

  @override
  Future<void> requestPasswordReset({required String email}) => _postAuth(
        '/auth/request-password-reset',
        {
          'email': email,
          'redirectTo': '${Uri.base.origin}/login',
        },
      );

  @override
  Future<void> resetPassword({
    required String token,
    required String password,
  }) =>
      _postAuth('/auth/reset-password', {
        'token': token,
        'newPassword': password,
      });

  @override
  Future<StudioAccountSecurity> loadAccountSecurity() async {
    final responses = await Future.wait([
      client.get(Uri.parse('$baseUrl/auth/list-accounts'), headers: _headers()),
      client.get(Uri.parse('$baseUrl/auth/list-sessions'), headers: _headers()),
      client.get(Uri.parse('$baseUrl/auth/passkey/list-user-passkeys'),
          headers: _headers()),
    ]);
    for (final response in responses) {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StudioApiException(
            'Account security lookup failed (${response.statusCode})',
            statusCode: response.statusCode);
      }
    }
    final accountsBody = jsonDecode(responses[0].body);
    final sessionsBody = jsonDecode(responses[1].body);
    final passkeysBody = jsonDecode(responses[2].body);
    final accounts = accountsBody is List
        ? accountsBody
        : accountsBody is Map && accountsBody['accounts'] is List
            ? accountsBody['accounts'] as List
            : const [];
    final sessions = sessionsBody is List
        ? sessionsBody
        : sessionsBody is Map && sessionsBody['sessions'] is List
            ? sessionsBody['sessions'] as List
            : const [];
    final passkeys = passkeysBody is List
        ? passkeysBody
        : passkeysBody is Map && passkeysBody['passkeys'] is List
            ? passkeysBody['passkeys'] as List
            : const [];
    return StudioAccountSecurity.fromJson(
      accounts
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
      sessions
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
      passkeys
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
    );
  }

  @override
  Future<void> registerPasskey(String name) async {
    await passkeyBrowser.register(baseUrl, name);
  }

  @override
  Future<void> deletePasskey(String id) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/passkey/delete-passkey'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'id': id}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Passkey removal failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> signInWithPasskey() async {
    await passkeyBrowser.signIn(baseUrl);
  }

  @override
  Future<void> revokeAccountSession(String token) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/revoke-session'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'token': token}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Session revocation failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<Uri> beginAccountLink(String provider, Uri returnTo) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/link-social'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'provider': provider,
        'callbackURL': returnTo.toString(),
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Could not start account linking',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final url = body is Map ? body['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const StudioApiException('Account linking response is malformed');
    }
    return Uri.parse(url);
  }

  @override
  Future<List<StudioWorkspace>> loadWorkspaces() async {
    final response =
        await client.get(Uri.parse('$baseUrl/workspaces'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace list failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final workspaces = body['workspaces'];
    if (workspaces is! List) {
      throw const StudioApiException('Workspace list response is malformed');
    }
    return workspaces
        .whereType<Map>()
        .map((workspace) =>
            StudioWorkspace.fromJson(Map<String, dynamic>.from(workspace)))
        .toList();
  }

  @override
  Future<void> createProject(
      {required String name, String? description}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'name': name,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } on Object {
        // Keep the status useful even when the server response is not JSON.
      }
      throw StudioApiException(
        'Project creation failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<StudioSnapshot> loadReadModels(
      {String? projectId, String? workspaceId}) async {
    final selectedWorkspaceId = workspaceId ?? activeWorkspaceId;
    if (selectedWorkspaceId == null || selectedWorkspaceId.isEmpty) {
      return loadSnapshot(projectId: projectId, workspaceId: workspaceId);
    }

    Future<Map<String, dynamic>> getJson(Uri uri) async {
      final response = await client.get(uri, headers: _headers());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var detail = '';
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['error'] is String) {
            detail = ': ${body['error']}';
          }
        } on Object {
          // Keep the route and status useful even when the server response is
          // not JSON.
        }
        throw StudioApiException(
          'Read model failed for ${uri.path} (${response.statusCode})$detail',
          statusCode: response.statusCode,
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const StudioApiException('Read model response is malformed');
      }
      return Map<String, dynamic>.from(decoded);
    }

    final responses = await Future.wait([
      getJson(Uri.parse('$baseUrl/projects')),
      getJson(Uri.parse('$baseUrl/workspaces/$selectedWorkspaceId/hosts')),
      getJson(Uri.parse('$baseUrl/workspaces/$selectedWorkspaceId/workers')),
      getJson(Uri.parse('$baseUrl/workspaces/$selectedWorkspaceId/accounts')),
      getJson(Uri.parse('$baseUrl/workspaces/$selectedWorkspaceId/usage')),
    ]);
    final projects = (responses[0]['projects'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    final selected = projectId ??
        (projects.isNotEmpty ? projects.first['id'] as String? : null);
    final detail = selected == null
        ? <String, dynamic>{}
        : await getJson(Uri.parse('$baseUrl/projects/$selected/read-model'));
    final detailProject = detail['project'];
    final mergedProjects = projects.map((project) {
      if (detailProject is Map && project['id'] == detailProject['id']) {
        return Map<String, dynamic>.from(detailProject);
      }
      return project;
    }).toList();
    final usage = (responses[4]['usage'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    final modelCalls = usage
        .map((value) => {
              ...value,
              'worker': value['worker'] ?? value['workerId'],
              'task': value['task'] ?? value['runId'],
              'cost': value['cost'] ?? value['costMicros'],
              'duration': value['duration'] ?? value['durationMs'],
            })
        .toList();
    return StudioSnapshot.fromJson({
      'workspaceId': selectedWorkspaceId,
      'projects': mergedProjects,
      'hosts': responses[1]['hosts'] ?? const [],
      'plugins': (responses[2]['workers'] as List? ?? const []).map((worker) {
        final value = Map<String, dynamic>.from(worker as Map);
        return {
          ...value,
          'name': value['displayName'] ?? value['name'] ?? '',
          'version': value['latestVersion'] ?? value['version'] ?? '—',
          'roles': value['roles'] ?? const [],
          'capabilities': value['capabilities'] ?? const [],
          'status': value['status'] ?? 'available',
        };
      }).toList(),
      'accounts': responses[3]['accounts'] ?? const [],
      'run': detail['run'],
      'activeRunId': detail['activeRunId'],
      'tasks': detail['tasks'] ?? const [],
      'findings': detail['findings'] ?? const [],
      'events': detail['events'] ?? const [],
      'artifacts': detail['artifacts'] ?? const [],
      'modelCalls': modelCalls.isNotEmpty
          ? modelCalls
          : (detail['modelCalls'] ?? const []),
    });
  }

  @override
  Future<StudioSnapshot> loadSnapshot(
      {String? projectId, String? workspaceId}) async {
    final uri = Uri.parse('$baseUrl/studio/snapshot').replace(
      queryParameters: {
        if (projectId != null) 'projectId': projectId,
        if (workspaceId != null) 'workspaceId': workspaceId,
      },
    );
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } on Object {
        // Preserve the HTTP status when the server response is not JSON.
      }
      throw StudioApiException(
          'Conclave AX snapshot failed (${response.statusCode})$detail',
          statusCode: response.statusCode);
    }
    return StudioSnapshot.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> controlRun(String runId, String command) async {
    final response = await client
        .post(Uri.parse('$baseUrl/runs/$runId/$command'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Run control failed (${response.statusCode})');
    }
  }

  @override
  Future<void> respondToRunPrompt(String runId, String response) async {
    final result = await client.post(
      Uri.parse('$baseUrl/runs/$runId/events'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'type': 'run-approval',
        'payload': {'response': response},
      }),
    );
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw StudioApiException('Run response failed',
          statusCode: result.statusCode);
    }
  }

  @override
  Future<void> createGoal({
    required String projectId,
    required String objective,
    required String revision,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/goals'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'projectId': projectId,
        'objective': objective,
        'revision': revision,
        'commitSha': revision,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Goal creation failed (${response.statusCode})');
    }
  }

  @override
  Future<StudioChatMessage> sendChatMessage({
    required String projectId,
    required String chatId,
    required String text,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/chats/$chatId/messages'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'content': text}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Send message failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final message = body['message'];
    if (message is! Map) {
      throw const StudioApiException('Send message response is malformed');
    }
    return StudioChatMessage.fromJson(
        _studioChatMessageFromApi(Map<String, dynamic>.from(message)));
  }

  @override
  Future<StudioChat> createChat({
    required String projectId,
    required String title,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects/$projectId/chats'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'title': title}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Create chat failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final chat = body['chat'];
    if (chat is! Map) {
      throw const StudioApiException('Create chat response is malformed');
    }
    return StudioChat.fromJson(
        _studioChatFromApi(Map<String, dynamic>.from(chat)));
  }

  @override
  Future<void> setWorkerEnabled({
    required String workspaceId,
    required String workerId,
    required bool enabled,
  }) async {
    final response = await client.put(
      Uri.parse('$baseUrl/workspaces/$workspaceId/workers/$workerId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'enabled': enabled}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Worker update failed (${response.statusCode})');
    }
  }

  @override
  Future<void> requestCredentialSetup({
    required String workspaceId,
    required String profileId,
    String action = 'reauthenticate',
  }) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/workspaces/$workspaceId/accounts/$profileId/setup-intent'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'action': action}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Account setup request failed (${response.statusCode})');
    }
  }

  @override
  Future<void> revokeCredentialProfile({
    required String workspaceId,
    required String profileId,
  }) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workspaces/$workspaceId/accounts/$profileId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Account revoke failed (${response.statusCode})');
    }
  }

  @override
  Future<void> revokeAgent({
    required String workspaceId,
    required String agentId,
  }) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workspaces/$workspaceId/agents/$agentId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Host revoke failed (${response.statusCode})');
    }
  }

  @override
  Future<void> announceAgentUpdate({
    required String workspaceId,
    required String agentId,
    String? channel,
    String? version,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/$workspaceId/agents/$agentId/update'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (channel != null) 'channel': channel,
        if (version != null) 'version': version,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Host update announcement failed (${response.statusCode})');
    }
  }

  @override
  Future<StudioHostEnrollment> createHostEnrollment({
    required String workspaceId,
    int expiresHours = 24,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/$workspaceId/agent-enrollments'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'expiresHours': expiresHours}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Host enrollment failed (${response.statusCode})');
    }
    return StudioHostEnrollment.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> saveWorker({
    required String workspaceId,
    String? workerId,
    required String name,
    required String agentId,
    required String workerCatalogId,
    required List<String> roles,
    required List<String> capabilities,
    required bool enabled,
    String workerVersionPolicy = 'latest',
    Map<String, dynamic> config = const {},
    String sessionPolicy = 'stateless',
    int concurrencyLimit = 1,
    String billingMode = 'local_compute',
    String independenceKey = '',
    Map<String, dynamic> costMetadata = const {},
  }) async {
    final uri = workerId == null
        ? Uri.parse('$baseUrl/workspaces/$workspaceId/workers')
        : Uri.parse('$baseUrl/workspaces/$workspaceId/workers/$workerId');
    final payload = {
      'name': name,
      'roles': roles,
      'capabilities': capabilities,
      'enabled': enabled,
      'workerVersionPolicy': workerVersionPolicy,
      'config': config,
      'sessionPolicy': sessionPolicy,
      'concurrencyLimit': concurrencyLimit,
      'billingMode': billingMode,
      'independenceKey': independenceKey,
      'costMetadata': costMetadata,
    };
    final response = workerId == null
        ? await client.post(uri,
            headers: _headers(contentType: 'application/json'),
            body: jsonEncode({
              ...payload,
              'name': name,
              'agentId': agentId,
              'workerCatalogId': workerCatalogId,
            }))
        : await client.put(uri,
            headers: _headers(contentType: 'application/json'),
            body: jsonEncode({
              ...payload,
              'agentId': agentId,
              'workerCatalogId': workerCatalogId,
            }));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Worker save failed (${response.statusCode})');
    }
  }
}

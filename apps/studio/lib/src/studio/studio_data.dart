import 'dart:convert';

import 'package:http/http.dart' as http;

import '../platform/http_client_stub.dart'
    if (dart.library.html) '../platform/http_client_web.dart' as platform;
import 'studio_models.dart';

abstract interface class StudioDataSource {
  Future<StudioSession> loadSession();
  Future<void> logout();
  Future<List<StudioWorkspace>> loadWorkspaces();
  Future<StudioSnapshot> loadSnapshot({String? projectId, String? workspaceId});
  Future<void> controlRun(String runId, String command);
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
  const StudioApiException(this.message);
  final String message;
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

  @override
  Future<StudioSession> loadSession() async {
    final response = await client.get(Uri.parse('$baseUrl/session'),
        headers: {'accept': 'application/json'});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Session lookup failed (${response.statusCode})');
    }
    return StudioSession.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> logout() async {
    final response = await client.post(Uri.parse('$baseUrl/session/logout'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Logout failed (${response.statusCode})');
    }
  }

  @override
  Future<List<StudioWorkspace>> loadWorkspaces() async {
    final response = await client.get(Uri.parse('$baseUrl/workspaces'),
        headers: {'accept': 'application/json'});
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
  Future<StudioSnapshot> loadSnapshot(
      {String? projectId, String? workspaceId}) async {
    final uri = Uri.parse('$baseUrl/studio/snapshot').replace(
      queryParameters: {
        if (projectId != null) 'projectId': projectId,
        if (workspaceId != null) 'workspaceId': workspaceId,
      },
    );
    final response =
        await client.get(uri, headers: {'accept': 'application/json'});
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
          'Studio snapshot failed (${response.statusCode})$detail');
    }
    return StudioSnapshot.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> controlRun(String runId, String command) async {
    final response =
        await client.post(Uri.parse('$baseUrl/runs/$runId/$command'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Run control failed (${response.statusCode})');
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
      headers: {'content-type': 'application/json'},
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
      headers: {'content-type': 'application/json'},
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
      headers: {'content-type': 'application/json'},
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
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'enabled': enabled}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Worker update failed (${response.statusCode})');
    }
  }

  @override
  Future<void> revokeAgent({
    required String workspaceId,
    required String agentId,
  }) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workspaces/$workspaceId/agents/$agentId'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Agent revoke failed (${response.statusCode})');
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
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        if (channel != null) 'channel': channel,
        if (version != null) 'version': version,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Agent update announcement failed (${response.statusCode})');
    }
  }

  @override
  Future<StudioHostEnrollment> createHostEnrollment({
    required String workspaceId,
    int expiresHours = 24,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/$workspaceId/agent-enrollments'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'expiresHours': expiresHours}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Agent enrollment failed (${response.statusCode})');
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
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              ...payload,
              'name': name,
              'agentId': agentId,
              'workerCatalogId': workerCatalogId,
            }))
        : await client.put(uri,
            headers: {'content-type': 'application/json'},
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

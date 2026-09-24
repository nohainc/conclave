import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/passkey_browser_stub.dart'
    if (dart.library.html) '../auth/passkey_browser_web.dart' as passkeys;
import '../platform/http_client_stub.dart'
    if (dart.library.html) '../platform/http_client_web.dart' as platform;
import 'studio_models.dart';

abstract interface class StudioDataSource {
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
  Future<StudioProject> createProject({
    required String name,
    String? description,
    String? repository,
    String? instructions,
    String? defaultExecutionPolicy,
  });
  Future<StudioProject> updateProject({
    required String projectId,
    String? name,
    String? description,
    String? repository,
    String? instructions,
    String? defaultExecutionPolicy,
  });
  Future<void> archiveProject({required String projectId});
  Future<void> deleteProject({required String projectId});
  Future<List<StudioProjectMember>> loadProjectMembers({
    required String projectId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<List<StudioProjectInvitation>> loadProjectInvitations({
    required String projectId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<List<StudioAuditEntry>> loadProjectAudit({
    required String projectId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> inviteProjectMember({
    required String projectId,
    required String email,
    required String role,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> changeProjectMemberRole({
    required String projectId,
    required String userId,
    required String role,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> removeProjectMember({
    required String projectId,
    required String userId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> expireProjectInvitation({
    required String projectId,
    required String invitationId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<StudioAccountSecurity> loadAccountSecurity();
  Future<void> revokeAccountSession(String token);
  Future<Uri> beginAccountLink(String provider, Uri returnTo);
  Future<void> registerPasskey(String name);
  Future<void> deletePasskey(String id);
  Future<void> signInWithPasskey();
  Future<List<StudioWorkspace>> loadWorkspaces();
  Future<StudioWorkspace> createWorkspace({
    required String name,
    String? slug,
  });
  Future<List<StudioProject>> loadProjects();
  Future<List<Map<String, dynamic>>> loadProjectWorkspaces({
    required String projectId,
  });
  Future<void> requestProjectWorkspace({
    required String projectId,
    required String workspaceId,
  });
  Future<List<StudioAgent>> loadHosts({required String workspaceId});
  Future<List<StudioWorker>> loadWorkers({required String workspaceId});
  Future<List<StudioCredentialProfile>> loadCredentialProfiles(
      {required String workspaceId});
  Future<StudioWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  });
  Future<List<StudioWorkspaceMember>> loadWorkspaceMembers(
      {required String workspaceId});
  Future<List<StudioWorkspaceInvitation>> loadWorkspaceInvitations(
      {required String workspaceId});
  Future<List<StudioAuditEntry>> loadWorkspaceAudit(
      {required String workspaceId});
  Future<void> inviteWorkspaceMember({
    required String workspaceId,
    required String email,
    required String role,
  });
  Future<void> changeWorkspaceMemberRole({
    required String workspaceId,
    required String userId,
    required String role,
  });
  Future<void> setWorkspaceMemberStatus({
    required String workspaceId,
    required String userId,
    required String status,
  });
  Future<void> expireWorkspaceInvitation({
    required String workspaceId,
    required String invitationId,
  });

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
  Future<void> provisionWorkstreamCheckout({
    required String workstreamId,
    String? workspaceId,
  }) async =>
      throw UnimplementedError(
          'Workstream checkout provisioning is not available');
  Future<void> setWorkerEnabled({
    required String workspaceId,
    required String workerId,
    required bool enabled,
    String? hostId,
  });
  Future<StudioCredentialProfile> createCredentialProfile({
    required String workspaceId,
    required String displayName,
    required String workerId,
    required String authType,
    required String ownerType,
    required String sharingPolicy,
    String? hostId,
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
  Future<void> updateHost({
    required String workspaceId,
    required String hostId,
    String? name,
    String? channel,
  });
  Future<void> bindHostWorkspace({
    required String workspaceId,
    required String hostId,
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
  String? sessionToken;

  Map<String, String> _headers({String? contentType}) => {
        'accept': 'application/json',
        if (contentType != null) 'content-type': contentType,
        if (sessionToken != null && sessionToken!.isNotEmpty)
          'authorization': 'Bearer $sessionToken',
      };

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
        'Read model failed for ${uri.path} (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const StudioApiException('Read model response is malformed');
    }
    return Map<String, dynamic>.from(decoded);
  }

  @override
  Future<List<StudioProject>> loadProjects() async {
    final body = await _getJson(Uri.parse('$baseUrl/projects'));
    return (body['projects'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => StudioProject.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> loadProjectWorkspaces({
    required String projectId,
  }) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/projects/$projectId/workspaces'));
    return (body['workspaces'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  Future<void> requestProjectWorkspace({
    required String projectId,
    required String workspaceId,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects/$projectId/workspaces'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'workspaceId': workspaceId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
        'Workspace grant failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<StudioAgent>> loadHosts({required String workspaceId}) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/workspaces/$workspaceId/hosts'));
    return (body['hosts'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => StudioAgent.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<StudioWorker>> loadWorkers({required String workspaceId}) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/workspaces/$workspaceId/workers'));
    return (body['workers'] as List? ?? const []).whereType<Map>().map((item) {
      final value = Map<String, dynamic>.from(item);
      return StudioWorker.fromJson({
        ...value,
        'name': value['displayName'] ?? value['name'] ?? '',
        'version': value['latestVersion'] ?? value['version'] ?? '—',
        'roles': value['roles'] ?? const [],
        'capabilities': value['capabilities'] ?? const [],
        'status': value['status'] ?? 'available',
      });
    }).toList();
  }

  @override
  Future<List<StudioCredentialProfile>> loadCredentialProfiles(
      {required String workspaceId}) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/workspaces/$workspaceId/accounts'));
    return (body['accounts'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            StudioCredentialProfile.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

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
    sessionToken = null;
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
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        if (decoded['token'] is String) {
          sessionToken = decoded['token'] as String;
        } else if (decoded['session'] is Map &&
            decoded['session']['token'] is String) {
          sessionToken = decoded['session']['token'] as String;
        }
      }
    } catch (_) {
      // Non-JSON response
    }
    try {
      final setCookie = response.headers['set-cookie'];
      if (setCookie != null &&
          (sessionToken == null || sessionToken!.isEmpty)) {
        final match = RegExp(
                r'(?:better-auth\.session_token|__Secure-better-auth\.session_token)=([^;]+)')
            .firstMatch(setCookie);
        if (match != null) {
          sessionToken = match.group(1);
        }
      }
    } catch (_) {
      // Ignored
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
  Future<StudioWorkspace> createWorkspace({
    required String name,
    String? slug,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'name': name,
        if (slug != null && slug.trim().isNotEmpty) 'slug': slug.trim(),
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
        'Workspace creation failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['workspace'] is! Map) {
      throw const StudioApiException(
          'Workspace creation response is malformed');
    }
    return StudioWorkspace.fromJson(
      Map<String, dynamic>.from(decoded['workspace'] as Map),
    );
  }

  Future<Map<String, dynamic>> _workspaceJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace settings request failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    if (body is! Map) {
      throw const StudioApiException('Workspace settings response malformed');
    }
    return Map<String, dynamic>.from(body);
  }

  @override
  Future<StudioWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workspaces/$workspaceId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace update failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final workspace = body is Map ? body['workspace'] : null;
    if (workspace is! Map) {
      throw const StudioApiException('Workspace update response malformed');
    }
    return StudioWorkspace.fromJson(Map<String, dynamic>.from(workspace));
  }

  @override
  Future<List<StudioWorkspaceMember>> loadWorkspaceMembers(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/members'));
    return (body['members'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            StudioWorkspaceMember.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<StudioWorkspaceInvitation>> loadWorkspaceInvitations(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/invitations'));
    return (body['invitations'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            StudioWorkspaceInvitation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<StudioAuditEntry>> loadWorkspaceAudit(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/audit-export'));
    return (body['entries'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            StudioAuditEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _workspaceMutation(Uri uri, Map<String, dynamic> body,
      {String method = 'POST'}) async {
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(contentType: 'application/json'))
      ..body = jsonEncode(body);
    final streamed = await client.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw StudioApiException(
          'Workspace action failed (${streamed.statusCode})',
          statusCode: streamed.statusCode);
    }
  }

  @override
  Future<void> inviteWorkspaceMember({
    required String workspaceId,
    required String email,
    required String role,
  }) =>
      _workspaceMutation(
        Uri.parse('$baseUrl/workspaces/$workspaceId/invitations'),
        {'email': email, 'role': role},
      );

  @override
  Future<void> changeWorkspaceMemberRole({
    required String workspaceId,
    required String userId,
    required String role,
  }) =>
      _workspaceMutation(
        Uri.parse('$baseUrl/workspaces/$workspaceId/members/$userId/role'),
        {'role': role},
        method: 'PATCH',
      );

  @override
  Future<void> setWorkspaceMemberStatus({
    required String workspaceId,
    required String userId,
    required String status,
  }) =>
      _workspaceMutation(
        Uri.parse('$baseUrl/workspaces/$workspaceId/members/$userId/$status'),
        {},
      );

  @override
  Future<void> expireWorkspaceInvitation({
    required String workspaceId,
    required String invitationId,
  }) =>
      _workspaceMutation(
        Uri.parse(
            '$baseUrl/workspaces/$workspaceId/invitations/$invitationId/expire'),
        {},
      );

  @override
  Future<StudioProject> createProject(
      {required String name,
      String? description,
      String? repository,
      String? instructions,
      String? defaultExecutionPolicy}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'name': name,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (repository != null && repository.trim().isNotEmpty)
          'repositoryId': repository.trim(),
        if (instructions != null && instructions.trim().isNotEmpty ||
            defaultExecutionPolicy != null)
          'settings': {
            if (instructions != null && instructions.trim().isNotEmpty)
              'instructions': instructions.trim(),
            if (defaultExecutionPolicy != null)
              'defaultExecutionPolicy': defaultExecutionPolicy,
          },
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
    final body = jsonDecode(response.body);
    final project = body is Map ? body['project'] : null;
    if (project is! Map) {
      throw const StudioApiException('Project creation response is malformed');
    }
    final value = Map<String, dynamic>.from(project);
    return StudioProject.fromJson({
      ...value,
      'repository': value['repository'] ?? value['repositoryId'] ?? '',
      'branch': value['branch'] ?? '',
      'activeGoals': value['activeGoals'] ?? 0,
      'lastActivity': value['lastActivity'] ?? value['updatedAt'] ?? '',
      'chats': value['chats'] ?? const [],
      'settings': value['settings'] ?? const {},
    });
  }

  @override
  Future<StudioProject> updateProject({
    required String projectId,
    String? name,
    String? description,
    String? repository,
    String? instructions,
    String? defaultExecutionPolicy,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/projects/$projectId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (repository != null) 'repositoryId': repository,
        if (instructions != null || defaultExecutionPolicy != null)
          'settings': {
            if (instructions != null) 'instructions': instructions,
            if (defaultExecutionPolicy != null)
              'defaultExecutionPolicy': defaultExecutionPolicy,
          },
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Project update failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final project = body is Map ? body['project'] : null;
    if (project is! Map) {
      throw const StudioApiException('Project update response is malformed');
    }
    final value = Map<String, dynamic>.from(project);
    return StudioProject.fromJson({
      ...value,
      'repository': value['repository'] ?? value['repositoryId'] ?? '',
      'lastActivity': value['lastActivity'] ?? value['updatedAt'] ?? '',
      'settings': value['settings'] ?? const {},
    });
  }

  @override
  Future<void> archiveProject({required String projectId}) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/projects/$projectId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'archived': true}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Project archive failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> deleteProject({required String projectId}) async {
    final response = await client
        .delete(Uri.parse('$baseUrl/projects/$projectId'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Project deletion failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  Future<Map<String, dynamic>> _projectJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Project collaboration request failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    if (body is! Map) {
      throw const StudioApiException(
          'Project collaboration response malformed');
    }
    return Map<String, dynamic>.from(body);
  }

  @override
  Future<List<StudioProjectMember>> loadProjectMembers({
    required String projectId,
  }) async {
    final body =
        await _projectJson(Uri.parse('$baseUrl/projects/$projectId/members'));
    return (body['members'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            StudioProjectMember.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<StudioProjectInvitation>> loadProjectInvitations({
    required String projectId,
  }) async {
    final body = await _projectJson(
        Uri.parse('$baseUrl/projects/$projectId/invitations'));
    return (body['invitations'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            StudioProjectInvitation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<StudioAuditEntry>> loadProjectAudit({
    required String projectId,
  }) async {
    final body =
        await _projectJson(Uri.parse('$baseUrl/projects/$projectId/audit'));
    return (body['entries'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            StudioAuditEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _projectMutation(Uri uri, Map<String, dynamic> body,
      {String method = 'POST'}) async {
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(contentType: 'application/json'))
      ..body = jsonEncode(body);
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Project collaboration action failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> inviteProjectMember(
          {required String projectId,
          required String email,
          required String role}) =>
      _projectMutation(Uri.parse('$baseUrl/projects/$projectId/invitations'),
          {'email': email, 'role': role});

  @override
  Future<void> changeProjectMemberRole(
          {required String projectId,
          required String userId,
          required String role}) =>
      _projectMutation(
          Uri.parse('$baseUrl/projects/$projectId/members/$userId/role'),
          {'role': role},
          method: 'PATCH');

  @override
  Future<void> removeProjectMember(
          {required String projectId, required String userId}) =>
      _projectMutation(
          Uri.parse('$baseUrl/projects/$projectId/members/$userId/remove'), {},
          method: 'POST');

  @override
  Future<void> expireProjectInvitation(
          {required String projectId, required String invitationId}) =>
      _projectMutation(
          Uri.parse(
              '$baseUrl/projects/$projectId/invitations/$invitationId/expire'),
          {},
          method: 'POST');

  @override
  Future<StudioSnapshot> loadReadModels(
      {String? projectId, String? workspaceId}) async {
    final selectedWorkspaceId = workspaceId;
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
    final usageReport = selected == null
        ? <String, dynamic>{'usage': const []}
        : await getJson(Uri.parse('$baseUrl/projects/$selected/usage'));
    final detailProject = detail['project'];
    final mergedProjects = projects.map((project) {
      if (detailProject is Map && project['id'] == detailProject['id']) {
        return Map<String, dynamic>.from(detailProject);
      }
      return project;
    }).toList();
    final usage = (usageReport['usage'] as List? ?? const [])
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
      'usageReport': usageReport,
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
    return StudioChatMessage.fromJson({
      ..._studioChatMessageFromApi(Map<String, dynamic>.from(message)),
      'goalId': body['goalId'] ?? message['goalId'],
      'runId': body['runId'],
      'intentKind': body['intent'] is Map ? body['intent']['kind'] : null,
    });
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
  Future<void> provisionWorkstreamCheckout({
    required String workstreamId,
    String? workspaceId,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workstreams/$workstreamId/checkouts'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({if (workspaceId != null) 'workspaceId': workspaceId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
        'Checkout provisioning failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> setWorkerEnabled({
    required String workspaceId,
    required String workerId,
    required bool enabled,
    String? hostId,
  }) async {
    final response = await client.put(
      Uri.parse('$baseUrl/workspaces/$workspaceId/workers/$workerId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'enabled': enabled,
        if (hostId != null) 'hostId': hostId,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Worker update failed (${response.statusCode})');
    }
  }

  @override
  Future<StudioCredentialProfile> createCredentialProfile({
    required String workspaceId,
    required String displayName,
    required String workerId,
    required String authType,
    required String ownerType,
    required String sharingPolicy,
    String? hostId,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/$workspaceId/accounts'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'displayName': displayName,
        'workerId': workerId,
        'authType': authType,
        'ownerType': ownerType,
        'sharingPolicy': sharingPolicy,
        if (hostId != null) 'hostId': hostId,
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
        // Preserve the HTTP status when the error body is not JSON.
      }
      throw StudioApiException(
          'Account creation failed (${response.statusCode})$detail');
    }
    final body = jsonDecode(response.body);
    final account = body is Map ? body['account'] : null;
    if (account is! Map) {
      throw const StudioApiException('Account creation response is malformed');
    }
    return StudioCredentialProfile.fromJson(Map<String, dynamic>.from(account));
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
      Uri.parse('$baseUrl/workspaces/$workspaceId/hosts/$agentId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace revoke failed (${response.statusCode})');
    }
  }

  @override
  Future<void> updateHost({
    required String workspaceId,
    required String hostId,
    String? name,
    String? channel,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workspaces/$workspaceId/hosts/$hostId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (channel != null) 'channel': channel,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace update failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> bindHostWorkspace({
    required String workspaceId,
    required String hostId,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/$workspaceId/hosts/$hostId/bind'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace grant failed (${response.statusCode})',
          statusCode: response.statusCode);
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
      Uri.parse('$baseUrl/workspaces/$workspaceId/hosts/$agentId/update'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (channel != null) 'channel': channel,
        if (version != null) 'version': version,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace update announcement failed (${response.statusCode})');
    }
  }

  @override
  Future<StudioHostEnrollment> createHostEnrollment({
    required String workspaceId,
    int expiresHours = 24,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/$workspaceId/enrollments'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'expiresHours': expiresHours}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Workspace enrollment failed (${response.statusCode})');
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
    throw const StudioApiException(
      'Configured Worker instances were removed. Manage Workers through Workspace desired state.',
    );
  }
}

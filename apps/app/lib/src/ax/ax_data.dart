import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/passkey_browser_stub.dart'
    if (dart.library.html) '../auth/passkey_browser_web.dart' as passkeys;
import '../platform/http_client_stub.dart'
    if (dart.library.html) '../platform/http_client_web.dart' as platform;
import 'ax_models.dart';
import 'ax_work_models.dart';

export 'ax_work_models.dart';

class AxApiException implements Exception {
  const AxApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class AxApiClient implements AxDataSource {
  AxApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ??
            (const String.fromEnvironment('CONCLAVE_API_URL').isNotEmpty
                ? const String.fromEnvironment('CONCLAVE_API_URL')
                : platform.defaultAxApiBaseUrl()),
        client = client ?? platform.createPlatformHttpClient();

  final String baseUrl;
  final http.Client client;
  final passkeyBrowser = passkeys.createAxPasskeyBrowser();
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
      throw AxApiException(
        'Read model failed for ${uri.path} (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AxApiException('Read model response is malformed');
    }
    return Map<String, dynamic>.from(decoded);
  }

  @override
  Future<List<AxProject>> loadProjects({bool includeArchived = false}) async {
    final uri = Uri.parse('$baseUrl/projects').replace(
      queryParameters: includeArchived ? {'archived': 'true'} : null,
    );
    final body = await _getJson(uri);
    return (body['projects'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxProject.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async {
    final body = await _getJson(Uri.parse('$baseUrl/workflows/catalog'));
    return (body['workflows'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxBuiltinWorkflow.fromJson(Map<String, dynamic>.from(item)))
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
      body: jsonEncode({
        'workspaceId': workspaceId,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = response.body.trim();
      throw AxApiException(
        'Workspace grant failed (${response.statusCode})${detail.isEmpty ? '' : ': $detail'}',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> revokeWorkspaceProjectGrant({
    required String grantId,
  }) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workspace-project-grants/$grantId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Workspace grant revoke failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<AxWorkstream>> loadProjectWorkstreams({
    required String projectId,
  }) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/projects/$projectId/workstreams'));
    return (body['workstreams'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorkstream.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<AxWorkstream> createWorkstream({
    required String projectId,
    required String name,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects/$projectId/workstreams'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
        'Workstream creation failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final workstream = body is Map ? body['workstream'] : null;
    if (workstream is! Map) {
      throw const AxApiException('Workstream creation response is malformed');
    }
    return AxWorkstream.fromJson(Map<String, dynamic>.from(workstream));
  }

  @override
  Future<AxWorkstream> updateWorkstream({
    required String workstreamId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workstreams/$workstreamId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (status != null) 'status': status,
        if (workConfig != null) 'workConfig': workConfig,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
        'Workstream update failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final workstream = body is Map ? body['workstream'] : null;
    if (workstream is! Map) {
      throw const AxApiException('Workstream update response is malformed');
    }
    return AxWorkstream.fromJson(Map<String, dynamic>.from(workstream));
  }

  @override
  Future<void> deleteWorkstream({required String workstreamId}) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workstreams/$workstreamId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Workstream deletion failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<String> createWorkRequest({
    required String workstreamId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workstreams/$workstreamId/work-requests'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workflowId': workflowId,
        'input': {'originalRequest': prompt, 'attachments': attachments},
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 422) {
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['issues'] is List) {
            final name = body['workflowName']?.toString() ?? workflowId;
            final messages = (body['issues'] as List)
                .whereType<Map>()
                .map((issue) => issue['message'])
                .whereType<String>()
                .toList(growable: false);
            if (messages.isNotEmpty) {
              throw AxApiException(
                'Cannot run $name\n${messages.map((message) => '• $message').join('\n')}',
                statusCode: 422,
              );
            }
          }
        } on AxApiException {
          rethrow;
        } on FormatException {
          // Fall through to the status-only error below.
        }
      }
      throw AxApiException(
        'Work request failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final request = body is Map ? body['workRequest'] : null;
    if (request is! Map || request['id'] is! String) {
      throw const AxApiException('Work request response is malformed');
    }
    return request['id'] as String;
  }

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String workstreamId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workstreams/$workstreamId/work-requests/validate'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workflowId': workflowId,
        'attachments': attachments
            .map((attachment) => {
                  'kind': attachment['kind'],
                  'mediaType': attachment['mediaType'],
                })
            .toList(growable: false),
      }),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const AxApiException('Work eligibility response is malformed');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Work eligibility check failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    if (decoded is! Map) {
      throw const AxApiException('Work eligibility response is malformed');
    }
    final issues = decoded['issues'];
    if (issues is! List) return const [];
    return issues
        .whereType<Map>()
        .map((issue) => issue['message'])
        .whereType<String>()
        .toList(growable: false);
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest({
    required String workRequestId,
  }) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/work-requests/$workRequestId'));
    final request = body['workRequest'];
    final result = body['result'];
    final resultMap = result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
    final requestMap = request is Map
        ? Map<String, dynamic>.from(request)
        : const <String, dynamic>{};
    final steps = (body['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorkRequestStep.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList(growable: false);
    return AxWorkRequestStatus(
      status: requestMap['status']?.toString() ?? 'unknown',
      text: resultMap['text']?.toString(),
      errorCode: body['errorCode']?.toString(),
      errorMessage: body['errorMessage']?.toString(),
      error: body['errorCode'] is String
          ? 'Run failed (${body['errorCode']}).'
          : null,
      workflowId: requestMap['workflowId']?.toString(),
      workflowVersion: requestMap['workflowVersion'] as int?,
      workflowName: requestMap['workflowName']?.toString(),
      requestedByUserId: requestMap['requestedByUserId']?.toString(),
      requestedByName: requestMap['requestedByName']?.toString(),
      originalRequest: requestMap['originalRequest']?.toString(),
      createdAt: requestMap['createdAt']?.toString(),
      steps: steps,
    );
  }

  @override
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? sessionStrategy,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/retry'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'stepKind': stepKind,
        if (sessionStrategy != null) 'sessionStrategy': sessionStrategy,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Step retry failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> cancelWorkRequest({required String workRequestId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/cancel'),
      headers: _headers(contentType: 'application/json'),
      body: '{}',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Run cancellation failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<AxWorkRequest>> loadWorkstreamWorkRequests({
    required String workstreamId,
    bool activeOnly = false,
  }) async {
    const pageSize = 100;
    final records = <AxWorkRequest>[];
    String? beforeCreatedAt;
    String? beforeId;
    while (true) {
      final uri = Uri.parse('$baseUrl/workstreams/$workstreamId/work-requests')
          .replace(queryParameters: {
        'limit': '$pageSize',
        if (activeOnly) 'activeOnly': 'true',
        if (beforeCreatedAt != null) 'beforeCreatedAt': beforeCreatedAt,
        if (beforeId != null) 'beforeId': beforeId,
      });
      final body = await _getJson(uri);
      final page = (body['workRequests'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AxWorkRequest.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .toList();
      records.addAll(page);
      final cursor = body['nextCursor'];
      if (cursor is! Map ||
          cursor['createdAt'] is! String ||
          cursor['id'] is! String) {
        break;
      }
      beforeCreatedAt = cursor['createdAt'] as String;
      beforeId = cursor['id'] as String;
    }
    return records.reversed.toList();
  }

  @override
  Future<List<AxDiscussionMessage>> loadDiscussionMessages({
    required String workstreamId,
  }) async {
    final body = await _getJson(
      Uri.parse('$baseUrl/workstreams/$workstreamId/discussion-messages'),
    );
    return (body['messages'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxDiscussionMessage.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList();
  }

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String workstreamId,
    required String text,
    List<String> references = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workstreams/$workstreamId/discussion-messages'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'body': text,
        'references': references,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep status-only message
      }
      throw AxApiException(
        'Discussion message submission failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map) {
      throw const AxApiException('Discussion message response is malformed');
    }
    return AxDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
  }

  @override
  Future<AxDiscussionMessage> editDiscussionMessage({
    required String messageId,
    required String text,
    List<String> references = const [],
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/discussion-messages/$messageId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'body': text,
        'references': references,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep status-only message
      }
      throw AxApiException(
        'Discussion message edit failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map) {
      throw const AxApiException(
          'Discussion message edit response is malformed');
    }
    return AxDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async {
    final body = await _getJson(Uri.parse('$baseUrl/workers'));
    return (body['workers'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorker.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<AxSession> loadSession() async {
    final response =
        await client.get(Uri.parse('$baseUrl/session'), headers: _headers());
    if (response.statusCode == 401) {
      return const AxSession(authenticated: false);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Session lookup failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    return AxSession.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> logout() async {
    sessionToken = null;
    final response = await client.post(Uri.parse('$baseUrl/auth/sign-out'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Logout failed (${response.statusCode})',
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
      throw AxApiException(message, statusCode: response.statusCode);
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
  Future<AxAccountSecurity> loadAccountSecurity() async {
    final responses = await Future.wait([
      client.get(Uri.parse('$baseUrl/auth/list-accounts'), headers: _headers()),
      client.get(Uri.parse('$baseUrl/auth/list-sessions'), headers: _headers()),
      client.get(Uri.parse('$baseUrl/auth/passkey/list-user-passkeys'),
          headers: _headers()),
    ]);
    for (final response in responses) {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AxApiException(
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
    return AxAccountSecurity.fromJson(
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
      throw AxApiException('Passkey removal failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> signInWithPasskey() async {
    await passkeyBrowser.signIn(baseUrl);
  }

  @override
  Future<void> approveDesktopAuthIntent({
    required String intentId,
  }) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/approve'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(const <String, Object?>{}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message =
          'Workspace sign-in approval failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } on Object {
        // Keep the status-based message for non-JSON error responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
  }

  @override
  Future<String> loadDesktopAuthIntentStatus({
    required String intentId,
  }) async {
    final body = await _getJson(Uri.parse(
      '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/browser-status',
    ));
    final status = body['status'];
    if (status is! String) {
      throw const AxApiException('Sign-in request status is malformed');
    }
    return status;
  }

  @override
  Future<void> denyDesktopAuthIntent({required String intentId}) async {
    final response = await client.post(
      Uri.parse(
        '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/deny',
      ),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(const <String, Object?>{}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Sign-in cancellation failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> revokeAccountSession(String token) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/revoke-session'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'token': token}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Session revocation failed',
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
      throw AxApiException('Could not start account linking',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final url = body is Map ? body['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const AxApiException('Account linking response is malformed');
    }
    return Uri.parse(url);
  }

  @override
  Future<List<AxWorkspace>> loadWorkspaces() async {
    final response =
        await client.get(Uri.parse('$baseUrl/workspaces'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Workspace list failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final workspaces = body['workspaces'];
    if (workspaces is! List) {
      throw const AxApiException('Workspace list response is malformed');
    }
    return workspaces
        .whereType<Map>()
        .map((workspace) =>
            AxWorkspace.fromJson(Map<String, dynamic>.from(workspace)))
        .toList();
  }

  Future<Map<String, dynamic>> _workspaceJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workspace settings request failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    if (body is! Map) {
      throw const AxApiException('Workspace settings response malformed');
    }
    return Map<String, dynamic>.from(body);
  }

  @override
  Future<AxWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workspaces/$workspaceId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Workspace update failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final workspace = body is Map ? body['workspace'] : null;
    if (workspace is! Map) {
      throw const AxApiException('Workspace update response malformed');
    }
    return AxWorkspace.fromJson(Map<String, dynamic>.from(workspace));
  }

  @override
  Future<List<AxWorkspaceMember>> loadWorkspaceMembers(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/members'));
    return (body['members'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxWorkspaceMember.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxWorkspaceInvitation>> loadWorkspaceInvitations(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/invitations'));
    return (body['invitations'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxWorkspaceInvitation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxAuditEntry>> loadWorkspaceAudit(
      {required String workspaceId}) async {
    final body = await _workspaceJson(
        Uri.parse('$baseUrl/workspaces/$workspaceId/audit-export'));
    return (body['entries'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxAuditEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _workspaceMutation(Uri uri, Map<String, dynamic> body,
      {String method = 'POST'}) async {
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(contentType: 'application/json'))
      ..body = jsonEncode(body);
    final streamed = await client.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw AxApiException('Workspace action failed (${streamed.statusCode})',
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
  Future<AxProject> createProject({
    required String name,
    String? description,
    String? instructions,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'name': name,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (instructions != null && instructions.trim().isNotEmpty)
          'settings': {'instructions': instructions.trim()},
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
      throw AxApiException(
        'Project creation failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final project = body is Map ? body['project'] : null;
    if (project is! Map) {
      throw const AxApiException('Project creation response is malformed');
    }
    final value = Map<String, dynamic>.from(project);
    return AxProject.fromJson({
      ...value,
      'branch': value['branch'] ?? '',
      'lastActivity': value['lastActivity'] ?? value['updatedAt'] ?? '',
      'settings': value['settings'] ?? const {},
    });
  }

  @override
  Future<AxProject> updateProject({
    required String projectId,
    String? name,
    String? description,
    String? instructions,
    Map<String, dynamic>? settings,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/projects/$projectId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (instructions != null) 'instructions': instructions,
        if (instructions != null || settings != null)
          'settings': {
            if (settings != null) ...settings,
            if (instructions != null) 'instructions': instructions,
          },
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status useful when the server response is not JSON.
      }
      throw AxApiException(
          'Project update failed (${response.statusCode})$detail',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final project = body is Map ? body['project'] : null;
    if (project is! Map) {
      throw const AxApiException('Project update response is malformed');
    }
    final value = Map<String, dynamic>.from(project);
    return AxProject.fromJson({
      ...value,
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
      throw AxApiException('Project archive failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> deleteProject({required String projectId}) async {
    final response = await client
        .delete(Uri.parse('$baseUrl/projects/$projectId'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } catch (_) {
        // Keep the status-only message when the server returned non-JSON.
      }
      throw AxApiException(
          'Project deletion failed (${response.statusCode})$detail',
          statusCode: response.statusCode);
    }
  }

  Future<Map<String, dynamic>> _projectJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Project collaboration request failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    if (body is! Map) {
      throw const AxApiException('Project collaboration response malformed');
    }
    return Map<String, dynamic>.from(body);
  }

  @override
  Future<List<AxProjectMember>> loadProjectMembers({
    required String projectId,
  }) async {
    final body =
        await _projectJson(Uri.parse('$baseUrl/projects/$projectId/members'));
    return (body['members'] as List? ?? const [])
        .whereType<Map>()
        .map(
            (item) => AxProjectMember.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxProjectInvitation>> loadProjectInvitations({
    required String projectId,
  }) async {
    final body = await _projectJson(
        Uri.parse('$baseUrl/projects/$projectId/invitations'));
    return (body['invitations'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxProjectInvitation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<AxAuditEntry>> loadProjectAudit({
    required String projectId,
  }) async {
    final body =
        await _projectJson(Uri.parse('$baseUrl/projects/$projectId/audit'));
    return (body['entries'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxAuditEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _projectMutation(Uri uri, Map<String, dynamic> body,
      {String method = 'POST'}) async {
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(contentType: 'application/json'))
      ..body = jsonEncode(body);
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final responseBody = await response.stream.bytesToString();
      var detail = '';
      try {
        final errorBody = jsonDecode(responseBody);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
          'Project collaboration action failed (${response.statusCode})$detail',
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
  Future<AxSnapshot> loadReadModels(
      {String? projectId, String? workspaceId}) async {
    final results = await Future.wait<Object>([
      loadProjects(),
      loadWorkspaces(),
      loadSession(),
    ]);
    final projects = results[0] as List<AxProject>;
    final workspaces = results[1] as List<AxWorkspace>;
    final session = results[2] as AxSession;
    final selected = projectId ?? projects.firstOrNull?.id;
    var mergedProjects = projects;
    if (selected != null) {
      final response = await _getJson(Uri.parse('$baseUrl/projects/$selected'));
      final projectValue = response['project'];
      if (projectValue is! Map) {
        throw const AxApiException('Project response is malformed');
      }
      final workstreams = await loadProjectWorkstreams(projectId: selected);
      final detail = AxProject.fromJson(Map<String, dynamic>.from(projectValue))
          .copyWith(workstreams: workstreams);
      mergedProjects = projects
          .map((project) => project.id == selected ? detail : project)
          .toList(growable: false);
    }
    return AxSnapshot(
      workspaceId: workspaceId,
      viewer: session.viewer,
      projects: mergedProjects,
      workspaces: workspaces,
      tasks: const [],
      findings: const [],
      events: const [],
      artifacts: const [],
    );
  }

  @override
  Future<void> controlRun(String runId, String command) async {
    final response = await client
        .post(Uri.parse('$baseUrl/runs/$runId/$command'), headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Run control failed (${response.statusCode})');
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
      throw AxApiException('Run response failed',
          statusCode: result.statusCode);
    }
  }

  @override
  Future<void> revokeWorkspace({required String workspaceId}) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workspaces/$workspaceId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = response.body.trim();
      throw AxApiException(
        'Workspace revoke failed (${response.statusCode})${detail.isEmpty ? '' : ': $detail'}',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<AxWorkspaceEnrollment> createWorkspaceEnrollment({
    required String workspaceId,
    int expiresHours = 24,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workspaces/$workspaceId/enrollments'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'expiresHours': expiresHours}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workspace enrollment failed (${response.statusCode})');
    }
    return AxWorkspaceEnrollment.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }
}

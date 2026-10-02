part of '../ax_data.dart';

mixin _ProjectApi on _AxApiClientCore {
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
}

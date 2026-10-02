part of '../ax_data.dart';

mixin _CatalogApi on _AxApiClientCore {
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
}

part of '../ax_data.dart';

mixin _CatalogApi on _AxApiClientCore {
  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async {
    final uri = Uri.parse('$baseUrl/spaces').replace(
      queryParameters: includeArchived ? {'archived': 'true'} : null,
    );
    final body = await _getJson(uri);
    final list = body['spaces'] ?? body['spaces'];
    return (list as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxSpace.fromJson(Map<String, dynamic>.from(item))
            .copyWith(threads: const []))
        .toList();
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async {
    final body = await _getJson(Uri.parse('$baseUrl/workflows/catalog'),
        conditional: true);
    return (body['workflows'] as List? ?? const [])
        .whereType<Map>()
        .map((item) =>
            AxBuiltinWorkflow.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> loadSpaceWorkspaces({
    required String spaceId,
  }) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/spaces/$spaceId/workspaces'));
    return (body['workspaces'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  Future<void> requestSpaceWorkspace({
    required String spaceId,
    required String workspaceId,
    List<String> allowedPermissions = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/spaces/$spaceId/workspaces'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workspaceId': workspaceId,
        'allowedPermissions': allowedPermissions,
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
  Future<void> updateWorkspaceSpacePermissions({
    required String grantId,
    required List<String> allowedPermissions,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workspace-space-grants/$grantId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'allowedPermissions': allowedPermissions}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workspace access update failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> revokeWorkspaceSpaceGrant({
    required String grantId,
  }) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workspace-space-grants/$grantId'),
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

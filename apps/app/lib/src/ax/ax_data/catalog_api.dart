part of '../ax_data.dart';

mixin _CatalogApi on _AxApiClientCore {
  /// User-level workflow endpoints address one Workspace; without it Cloud
  /// uses the user's selected Workspace.
  String _userWorkflowUrl(String path, String? workspaceId) =>
      '$baseUrl/user/$path${workspaceId == null ? '' : '?workspaceId=${Uri.encodeQueryComponent(workspaceId)}'}';

  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations(
      {String? workspaceId}) async {
    final body = await _getJson(
        Uri.parse(_userWorkflowUrl('workflow-configurations', workspaceId)));
    return (body['configurations'] as List)
        .map((value) => AxUserWorkflowConfiguration.fromJson(
            Map<String, dynamic>.from(value as Map)))
        .toList();
  }

  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration,
      {String? workspaceId}) async {
    final response = await client.put(
        Uri.parse(_userWorkflowUrl(
            'workflow-configurations/${Uri.encodeComponent(configuration.workflowId)}',
            workspaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(configuration.toJson()));
    return _configurationResponse(response);
  }

  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId,
      {String? workspaceId}) async {
    final response = await client.delete(
        Uri.parse(_userWorkflowUrl(
            'workflow-configurations/${Uri.encodeComponent(workflowId)}',
            workspaceId)),
        headers: _headers());
    return _configurationResponse(response);
  }

  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
      String spaceId) async {
    final body = await _getJson(Uri.parse(
        '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-configurations'));
    return (body['configurations'] as List)
        .map((value) => AxUserWorkflowConfiguration.fromJson(
            Map<String, dynamic>.from(value as Map)))
        .toList();
  }

  Future<String> loadWorkflowDefault({String? workspaceId}) async =>
      (await _getJson(
              Uri.parse(_userWorkflowUrl('workflow-default', workspaceId))))[
          'defaultWorkflowId'] as String;

  Future<String> saveWorkflowDefault(String workflowId,
      {String? workspaceId}) async {
    final response = await client.put(
        Uri.parse(_userWorkflowUrl('workflow-default', workspaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'defaultWorkflowId': workflowId}));
    return _workflowDefaultResponse(response);
  }

  Future<String> loadSpaceWorkflowDefault(String spaceId) async =>
      (await _getJson(Uri.parse(
              '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-default')))[
          'defaultWorkflowId'] as String;

  Future<List<AxPerson>> loadPeople() async {
    final response = await _getJson(Uri.parse('$baseUrl/people'));
    return List.unmodifiable((response['people'] as List).map(
        (row) => AxPerson.fromJson(Map<String, dynamic>.from(row as Map))));
  }

  String _workflowWorkspaceUrl(String? spaceId) => spaceId == null
      ? '$baseUrl/user/workflow-workspace'
      : '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-workspace';
  Future<AxWorkflowWorkspaceSettings> loadWorkflowWorkspace(
          {String? spaceId}) async =>
      AxWorkflowWorkspaceSettings.fromJson(
          await _getJson(Uri.parse(_workflowWorkspaceUrl(spaceId))));
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
      {String? spaceId, String? workspaceId, bool inherit = false}) async {
    final response = await client.put(Uri.parse(_workflowWorkspaceUrl(spaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({
          'workspaceId': workspaceId,
          'inherit': inherit,
          'confirmReset': true
        }));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workspace selection failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return AxWorkflowWorkspaceSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  String _memberAccessUrl(String workspaceId) =>
      '$baseUrl/workspaces/${Uri.encodeComponent(workspaceId)}/member-access';

  Future<AxWorkspaceMemberAccess> loadWorkspaceMemberAccess(
          String workspaceId) async =>
      AxWorkspaceMemberAccess.fromJson(
          await _getJson(Uri.parse(_memberAccessUrl(workspaceId))));

  Future<AxWorkspaceMemberAccess> saveWorkspaceMemberAccess(
      String workspaceId, AxWorkspaceMemberAccess access) async {
    final response = await client.put(Uri.parse(_memberAccessUrl(workspaceId)),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(access.toJson()));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Member access update failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return AxWorkspaceMemberAccess.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  AxUserWorkflowConfiguration _configurationResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Workflow configuration failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body) as Map;
    return AxUserWorkflowConfiguration.fromJson(
        Map<String, dynamic>.from(body['configuration'] as Map));
  }

  String _workflowDefaultResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Default workflow selection failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode);
    }
    return (jsonDecode(response.body) as Map)['defaultWorkflowId'] as String;
  }

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async {
    final uri = Uri.parse('$baseUrl/spaces').replace(
      queryParameters: includeArchived ? {'archived': 'true'} : null,
    );
    final body = await _getJson(uri);
    final list = body['spaces'];
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
}

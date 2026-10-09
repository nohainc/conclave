part of '../ax_data.dart';

mixin _CatalogApi on _AxApiClientCore {
  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations() async {
    final body =
        await _getJson(Uri.parse('$baseUrl/user/workflow-configurations'));
    return (body['configurations'] as List)
        .map((value) => AxUserWorkflowConfiguration.fromJson(
            Map<String, dynamic>.from(value as Map)))
        .toList();
  }

  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration) async {
    final response = await client.put(
        Uri.parse(
            '$baseUrl/user/workflow-configurations/${Uri.encodeComponent(configuration.workflowId)}'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(configuration.toJson()));
    return _configurationResponse(response);
  }

  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId) async {
    final response = await client.delete(
        Uri.parse(
            '$baseUrl/user/workflow-configurations/${Uri.encodeComponent(workflowId)}'),
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

  Future<AxUserWorkflowConfiguration> saveSpaceWorkflowConfiguration(
      String spaceId, AxUserWorkflowConfiguration configuration) async {
    return _configurationResponse(await client.put(
        Uri.parse(
            '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-configurations/${Uri.encodeComponent(configuration.workflowId)}'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(configuration.toJson())));
  }

  Future<AxUserWorkflowConfiguration> resetSpaceWorkflowConfiguration(
      String spaceId, String workflowId) async {
    return _configurationResponse(await client.delete(
        Uri.parse(
            '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-configurations/${Uri.encodeComponent(workflowId)}'),
        headers: _headers()));
  }

  Future<String> loadWorkflowDefault() async => (await _getJson(
          Uri.parse('$baseUrl/user/workflow-default')))['defaultWorkflowId']
      as String;

  Future<String> saveWorkflowDefault(String workflowId) async {
    final response = await client.put(
        Uri.parse('$baseUrl/user/workflow-default'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'defaultWorkflowId': workflowId}));
    return _workflowDefaultResponse(response);
  }

  Future<String> loadSpaceWorkflowDefault(String spaceId) async =>
      (await _getJson(Uri.parse(
              '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-default')))[
          'defaultWorkflowId'] as String;

  Future<String> saveSpaceWorkflowDefault(
      String spaceId, String workflowId) async {
    final response = await client.put(
        Uri.parse(
            '$baseUrl/spaces/${Uri.encodeComponent(spaceId)}/workflow-default'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'defaultWorkflowId': workflowId}));
    return _workflowDefaultResponse(response);
  }

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

part of '../ax_data.dart';

mixin _ReadModelApi on _AxApiClientCore {
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
    return AxSnapshot(
      workspaceId: workspaceId,
      viewer: session.viewer,
      projects: projects,
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
}

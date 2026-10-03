import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileAdminApiClient', () {
    late HttpServer server;
    late ProfileAdminApiClient client;
    late String lastPath;
    late String lastMethod;
    late Map<String, dynamic> lastBody;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        lastMethod = req.method;
        lastPath = req.uri.path;
        final bodyStr = await utf8.decoder.bind(req).join();
        if (bodyStr.isNotEmpty) {
          lastBody = jsonDecode(bodyStr) as Map<String, dynamic>;
        }

        if (req.uri.path == '/api/admin/workers/catalog' &&
            req.method == 'POST') {
          req.response.statusCode = 201;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'workerTypeId': lastBody['workerTypeId'],
            'profileDefinitionId': lastBody['profileDefinitionId'],
            'status': 'created',
          }));
        } else if (req.uri.path == '/api/admin/workers/catalog' &&
            req.method == 'GET') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'workers': [
              {
                'workerTypeId': 'claude',
                'displayName': 'Claude',
                'providerToolName': 'claude',
                'activeProfileDefinitionId': 'claude-code',
                'releaseStage': 'draft',
              }
            ],
          }));
        } else if (req.uri.path == '/api/admin/workspace-channels' &&
            req.method == 'GET') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'workspaces': [
              {
                'id': 'ws-1',
                'name': 'Test Mac Workspace',
                'channel': 'testing',
                'hostname': 'vitalii-macbook',
                'platform': 'darwin',
              }
            ],
          }));
        } else if (req.uri.path ==
                '/api/workspaces/ws-1/tool-profile-channel' &&
            req.method == 'PATCH') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'workspaceId': 'ws-1',
            'channel': lastBody['channel'],
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final session = ProfileLabSession(
        credential: 'conclave_dhs_mock',
        sessionId: 'sess-123',
        userId: 'admin-1',
        displayName: 'Test Admin',
        email: 'admin@conclave.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );

      client = ProfileAdminApiClient(
        baseUrl: 'http://${server.address.host}:${server.port}',
        session: session,
      );
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    test(
        'createWorker sends POST to /api/admin/workers/catalog with atomic payloads',
        () async {
      final res = await client.createWorker(
        workerTypeId: 'claude',
        profileDefinitionId: 'claude-code',
        displayName: 'Claude',
        description: 'Anthropic Claude Code AI Assistant Worker',
        providerToolName: 'claude',
        releaseStage: 'draft',
        capabilities: ['code_generation', 'tool_execution'],
        sortOrder: 10,
      );

      expect(lastMethod, 'POST');
      expect(lastPath, '/api/admin/workers/catalog');
      expect(lastBody['workerTypeId'], 'claude');
      expect(lastBody['profileDefinitionId'], 'claude-code');
      expect(lastBody['displayName'], 'Claude');
      expect(
          lastBody['description'], 'Anthropic Claude Code AI Assistant Worker');
      expect(lastBody['providerToolName'], 'claude');
      expect(lastBody['releaseStage'], 'draft');
      expect(lastBody['capabilities'], ['code_generation', 'tool_execution']);
      expect(lastBody['sortOrder'], 10);
      expect(res['status'], 'created');
    });

    test('fetchWorkerCatalog retrieves list of catalog workers', () async {
      final list = await client.fetchWorkerCatalog();
      expect(lastMethod, 'GET');
      expect(lastPath, '/api/admin/workers/catalog');
      expect(list, hasLength(1));
      expect(list.first['workerTypeId'], 'claude');
    });

    test('listWorkspaceChannels retrieves workspace rollout channel list',
        () async {
      final workspaces = await client.listWorkspaceChannels();
      expect(lastMethod, 'GET');
      expect(lastPath, '/api/admin/workspace-channels');
      expect(workspaces, hasLength(1));
      expect(workspaces.first['id'], 'ws-1');
      expect(workspaces.first['channel'], 'testing');
    });

    test('setWorkspaceChannel sends PATCH to update rollout channel', () async {
      final res = await client.setWorkspaceChannel(
          workspaceId: 'ws-1', channel: 'beta');
      expect(lastMethod, 'PATCH');
      expect(lastPath, '/api/workspaces/ws-1/tool-profile-channel');
      expect(lastBody['channel'], 'beta');
      expect(res['channel'], 'beta');
    });
  });
}

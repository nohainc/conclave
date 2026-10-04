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
    String? lastIfMatch;
    var requestCount = 0;
    int catalogStatus = 200;
    Object? catalogOverride;

    test('requires secure non-loopback Cloud API origins', () {
      expect(
        () => ProfileAdminApiClient(baseUrl: 'http://cloud.example.com'),
        throwsArgumentError,
      );
      expect(
        () => ProfileAdminApiClient(baseUrl: 'https://cloud.example.com/api'),
        throwsArgumentError,
      );
    });

    setUp(() async {
      requestCount = 0;
      catalogStatus = 200;
      catalogOverride = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        requestCount++;
        lastMethod = req.method;
        lastPath = req.uri.path;
        lastIfMatch = req.headers.value(HttpHeaders.ifMatchHeader);
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
          req.response.statusCode = catalogStatus;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(catalogOverride ??
              {
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
        } else if (req.uri.path ==
                '/api/admin/tool-profiles/claude-code/releases' &&
            req.method == 'POST') {
          req.response.statusCode = 201;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'status': 'draft',
            'payloadDigest': List.filled(64, 'a').join(),
          }));
        } else if (req.uri.path ==
                '/api/admin/tool-profiles/claude-code/releases/2/draft' &&
            req.method == 'PUT') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'payloadDigest': List.filled(64, 'b').join(),
          }));
        } else if (req.uri.path ==
                '/api/admin/tool-profiles/signing-preflight' &&
            req.method == 'GET') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'ready': true,
            'publisher': 'conclave',
            'signingKeyId': 'profile-key-v2',
            'issues': [],
          }));
        } else if (req.uri.path == '/api/release-trust' &&
            req.method == 'GET') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'revokedKeyIds': ['old-key'],
            'revokedToolProfiles': [
              {
                'profileDefinitionId': 'revoked-profile',
                'releaseVersion': 3,
                'payloadDigest': List.filled(64, 'b').join(),
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
        } else if (req.uri.path.endsWith('/releases/1/promote') &&
            req.method == 'POST') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'status': 'promoted'}));
        } else if (req.uri.path.endsWith('/releases/1/evidence') &&
            req.method == 'POST') {
          req.response.statusCode = 201;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'id': 'evidence-1',
            'status': 'accepted',
            'payloadDigest': List.filled(64, 'a').join(),
          }));
        } else if (req.uri.path.endsWith('/releases/1/publish') &&
            req.method == 'POST') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'status': 'testing',
            'signingKeyId': 'profile-key-v2',
            'publisher': 'conclave',
          }));
        } else if (req.uri.path.endsWith('/releases/1/qualification') &&
            req.method == 'POST') {
          req.response.statusCode = 201;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'status': 'qualified',
            'qualificationEvidenceId': 'qualification-1',
            'payloadDigest': List.filled(64, 'a').join(),
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

    test('Stable promotion requires a stored Cloud evidence ID', () async {
      await expectLater(
        client.promoteRelease(
          profileDefinitionId: 'claude-code',
          releaseVersion: 1,
          channel: 'stable',
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('stored Cloud evidence ID'),
        )),
      );

      expect(requestCount, 0);
    });

    test('signing preflight is read from the Cloud signer boundary', () async {
      final result = await client.checkSigningPreflight();
      expect(lastMethod, 'GET');
      expect(lastPath, '/api/admin/tool-profiles/signing-preflight');
      expect(result, isA<ProfileLabSigningPreflightReadModel>());
      expect(result.ready, isTrue);
      expect(result.signingKeyId, 'profile-key-v2');
    });

    test('release trust reads current key and Tool Profile revocations',
        () async {
      final result = await client.fetchReleaseTrust();
      expect(lastMethod, 'GET');
      expect(lastPath, '/api/release-trust');
      expect(result.revokedKeyIds, ['old-key']);
      expect(result.revokedToolProfiles.single.profileDefinitionId,
          'revoked-profile');
      expect(result.revokedToolProfiles.single.releaseVersion, 3);
    });

    test('publication sends no client signature or signing key controls',
        () async {
      await client.publishRelease(
        profileDefinitionId: 'claude-code',
        releaseVersion: 1,
        qualificationEvidenceId: 'qualification-1',
      );
      expect(lastMethod, 'POST');
      expect(
        lastPath,
        '/api/admin/tool-profiles/claude-code/releases/1/publish',
      );
      expect(lastBody, {'qualificationEvidenceId': 'qualification-1'});
      expect(lastBody.containsKey('signature'), isFalse);
      expect(lastBody.containsKey('signingKeyId'), isFalse);
    });

    test('new draft release uses POST with version and profile payload',
        () async {
      final profile = <String, dynamic>{
        'profileDefinitionId': 'claude-code',
        'releaseVersion': 2,
      };
      final result = await client.createDraftRelease(
        profileDefinitionId: 'claude-code',
        releaseVersion: 2,
        profile: profile,
      );

      expect(lastMethod, 'POST');
      expect(lastPath, '/api/admin/tool-profiles/claude-code/releases');
      expect(lastBody, {'releaseVersion': 2, 'profile': profile});
      expect(result['status'], 'draft');
      expect(result['payloadDigest'], List.filled(64, 'a').join());
    });

    test('draft update sends If-Match and keeps the JSON body to profile',
        () async {
      final digest = List.filled(64, 'a').join();
      final profile = <String, dynamic>{
        'profileDefinitionId': 'claude-code',
        'releaseVersion': 2,
      };
      final result = await client.updateDraft(
        profileDefinitionId: 'claude-code',
        releaseVersion: 2,
        profile: profile,
        expectedBaseDigest: digest,
      );

      expect(lastMethod, 'PUT');
      expect(
        lastPath,
        '/api/admin/tool-profiles/claude-code/releases/2/draft',
      );
      expect(lastBody, {'profile': profile});
      expect(lastIfMatch, '"$digest"');
      expect(result['payloadDigest'], List.filled(64, 'b').join());

      await client.updateDraft(
        profileDefinitionId: 'claude-code',
        releaseVersion: 2,
        profile: profile,
      );
      expect(lastBody, {'profile': profile});
      expect(lastIfMatch, isNull);
    });

    test('missing Cloud release is distinguishable from other request errors',
        () async {
      await expectLater(
        client.fetchRelease('claude-code', 2),
        throwsA(isA<ProfileAdminNotFoundException>()),
      );
    });

    test('local qualification is submitted before publication', () async {
      final evidence = <String, Object?>{
        'formatVersion': 2,
        'profileDefinitionId': 'claude-code',
      };
      final result = await client.submitLocalQualification(
        profileDefinitionId: 'claude-code',
        releaseVersion: 1,
        evidence: evidence,
      );
      expect(lastMethod, 'POST');
      expect(
        lastPath,
        '/api/admin/tool-profiles/claude-code/releases/1/qualification',
      );
      expect(lastBody, {'evidence': evidence});
      expect(result['qualificationEvidenceId'], 'qualification-1');
    });

    test('Stable promotion sends only the stored evidence ID', () async {
      await client.promoteRelease(
        profileDefinitionId: 'claude-code',
        releaseVersion: 1,
        channel: 'stable',
        acceptanceEvidenceId: 'evidence-1',
      );

      expect(lastMethod, 'POST');
      expect(
        lastPath,
        '/api/admin/tool-profiles/claude-code/releases/1/promote',
      );
      expect(lastBody, {
        'channel': 'stable',
        'acceptanceEvidenceId': 'evidence-1',
      });
    });

    test('Beta promotion sends only the channel and no evidence payload',
        () async {
      await client.promoteRelease(
        profileDefinitionId: 'claude-code',
        releaseVersion: 1,
        channel: 'beta',
      );

      expect(lastMethod, 'POST');
      expect(
          lastPath, '/api/admin/tool-profiles/claude-code/releases/1/promote');
      expect(lastBody, {'channel': 'beta'});
    });

    test('acceptance evidence is submitted in its separate endpoint', () async {
      final result = await client.submitReleaseEvidence(
        profileDefinitionId: 'claude-code',
        releaseVersion: 1,
        evidence: {'formatVersion': 2},
      );

      expect(lastMethod, 'POST');
      expect(
        lastPath,
        '/api/admin/tool-profiles/claude-code/releases/1/evidence',
      );
      expect(lastBody, {
        'evidence': {'formatVersion': 2},
      });
      expect(result['id'], 'evidence-1');
    });

    test('fetchWorkerCatalog retrieves list of catalog workers', () async {
      final list = await client.fetchWorkerCatalog();
      expect(lastMethod, 'GET');
      expect(lastPath, '/api/admin/workers/catalog');
      expect(list, hasLength(1));
      expect(list.first, isA<ProfileLabWorkerReadModel>());
      expect(list.first.workerTypeId, 'claude');
    });

    test('malformed catalog response is a failure, not empty', () async {
      catalogOverride = {'unexpected': []};
      await expectLater(client.fetchWorkerCatalog(), throwsFormatException);
    });

    for (final status in [401, 403]) {
      test('catalog HTTP $status preserves unauthorized error', () async {
        catalogStatus = status;
        catalogOverride = {'error': 'Catalog permission denied'};
        await expectLater(
            client.fetchWorkerCatalog(),
            throwsA(isA<ProfileAdminUnauthorizedException>().having(
                (error) => error.message,
                'message',
                'Catalog permission denied')));
      });
    }

    test('listWorkspaceChannels retrieves workspace rollout channel list',
        () async {
      final workspaces = await client.listWorkspaceChannels();
      expect(lastMethod, 'GET');
      expect(lastPath, '/api/admin/workspace-channels');
      expect(workspaces, hasLength(1));
      expect(workspaces.first, isA<ProfileLabWorkspaceChannelReadModel>());
      expect(workspaces.first.workspaceId, 'ws-1');
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

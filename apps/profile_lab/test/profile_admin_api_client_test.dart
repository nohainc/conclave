import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('V9 candidate validation and publication use one Worker Profile',
      () async {
    final requests = <(String, String, Map<String, dynamic>)>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.path,
        body.isEmpty ? <String, dynamic>{} : jsonDecode(body),
      ));
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/admin/workers' && request.method == 'GET') {
        request.response.write(jsonEncode({
          'workers': [
            {
              'workerTypeId': 'claude',
              'displayName': 'Claude',
              'currentRevision': 4,
              'currentDigest': List.filled(64, 'a').join(),
            }
          ],
        }));
      } else if (request.uri.path == '/api/admin/workers/claude/profile' &&
          request.method == 'GET') {
        request.response.write(jsonEncode({
          'workerTypeId': 'claude',
          'schemaVersion': 1,
          'profile': {'logicalWorkerTypeId': 'claude'},
          'revision': 4,
          'digest': List.filled(64, 'a').join(),
          'signature': 'signature',
          'signingKeyId': 'key',
          'verified': true,
        }));
      } else if (request.uri.path ==
              '/api/admin/workers/claude/profile/validate' &&
          request.method == 'POST') {
        request.response.write(jsonEncode({'valid': true}));
      } else if (request.uri.path == '/api/admin/workers/claude/profile' &&
          request.method == 'PUT') {
        request.response.write(jsonEncode({
          'workerTypeId': 'claude',
          'revision': 5,
          'digest': List.filled(64, 'b').join(),
          'verified': true,
        }));
      } else if (request.uri.path ==
              '/api/admin/workers/claude/profile/history' &&
          request.method == 'GET') {
        request.response.write(jsonEncode({
          'history': [
            {
              'revision': 4,
              'digest': List.filled(64, 'a').join(),
              'profile': {'logicalWorkerTypeId': 'claude'},
              'verified': true,
            }
          ],
        }));
      } else if (request.uri.path ==
              '/api/admin/workers/claude/profile/restore' &&
          request.method == 'POST') {
        request.response.write(jsonEncode({
          'workerTypeId': 'claude',
          'revision': 6,
          'digest': List.filled(64, 'c').join(),
          'profile': {'logicalWorkerTypeId': 'claude'},
          'verified': true,
        }));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });

    final client = ProfileAdminApiClient(
      baseUrl: 'http://${server.address.host}:${server.port}',
      session: ProfileLabSession(
        credential: 'fixture',
        sessionId: 'session',
        userId: 'operator',
        displayName: 'Operator',
        email: 'operator@example.test',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    addTearDown(client.close);

    final workers = await client.fetchWorkerCatalog();
    expect(workers.single.workerTypeId, 'claude');
    final current = await client.fetchCurrentWorkerProfile('claude');
    expect(current['revision'], 4);

    const digest =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final evidence = <String, Object?>{
      'formatVersion': 1,
      'workerTypeId': 'claude',
      'candidateDigest': digest,
    };
    await client.validateWorkerProfileCandidate(
      workerTypeId: 'claude',
      profile: {'logicalWorkerTypeId': 'claude'},
      candidateDigest: digest,
      evidence: evidence,
    );
    await client.publishWorkerProfile(
      workerTypeId: 'claude',
      expectedRevision: 4,
      profile: {'logicalWorkerTypeId': 'claude'},
      candidateDigest: digest,
      evidence: evidence,
    );
    final history = await client.fetchWorkerProfileHistory('claude');
    expect(history.single['revision'], 4);
    final restored = await client.restoreWorkerProfile(
      workerTypeId: 'claude',
      expectedRevision: 5,
      targetRevision: 4,
      restorationReason: 'Restore known-good revision',
    );
    expect(restored['revision'], 6);

    expect(requests[2].$1, 'POST');
    expect(requests[2].$2, '/api/admin/workers/claude/profile/validate');
    expect(requests[3].$1, 'PUT');
    expect(requests[3].$3['expectedRevision'], 4);
    expect(requests[3].$3.containsKey('channel'), isFalse);
    expect(requests[3].$3.containsKey('releaseVersion'), isFalse);
    expect(requests[4].$1, 'GET');
    expect(requests[4].$2, '/api/admin/workers/claude/profile/history');
    expect(requests[5].$1, 'POST');
    expect(requests[5].$2, '/api/admin/workers/claude/profile/restore');
    expect(requests[5].$3['expectedRevision'], 5);
    expect(requests[5].$3['targetRevision'], 4);
    expect(requests[5].$3['restorationReason'], 'Restore known-good revision');
  });
}

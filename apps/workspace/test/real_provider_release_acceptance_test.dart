import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

import 'support/compile_dart_executable.dart';

void main() {
  final officialProfiles = <_OfficialCandidate>[
    const _OfficialCandidate(
      definitionId: 'chatgpt-codex',
      logicalWorkerTypeId: 'chatgpt',
      providerToolName: 'Codex CLI',
      profilePath: 'packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
      optInVariable: 'CONCLAVE_TEST_REAL_PROFILE_CHATGPT',
    ),
    const _OfficialCandidate(
      definitionId: 'gemini-antigravity',
      logicalWorkerTypeId: 'gemini',
      providerToolName: 'Antigravity CLI',
      profilePath:
          'packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
      optInVariable: 'CONCLAVE_TEST_REAL_PROFILE_GEMINI',
    ),
  ];

  for (final official in officialProfiles) {
    test(
      'Phase 29 — Mock Engine cannot certify ${official.definitionId}',
      () async {
        await _runRealProviderReleaseAcceptance(official);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}

final class _OfficialCandidate {
  const _OfficialCandidate({
    required this.definitionId,
    required this.logicalWorkerTypeId,
    required this.providerToolName,
    required this.profilePath,
    required this.optInVariable,
  });

  final String definitionId;
  final String logicalWorkerTypeId;
  final String providerToolName;
  final String profilePath;
  final String optInVariable;
}

Future<void> _runRealProviderReleaseAcceptance(
    _OfficialCandidate official) async {
  final repositoryRoot = Directory.current.parent.parent.path;
  final tempDir = await Directory.systemTemp
      .createTemp('conclave-phase29-${official.definitionId}-');
  addTearDown(() => tempDir.delete(recursive: true));

  final sandboxDir = Directory('${tempDir.path}/sandbox')
    ..createSync(recursive: true);

  // 1. Prepare Mock Engine Binary for standalone testing when live provider CLI is unconfigured
  final mockEngineSourceFile = File('${tempDir.path}/mock_engine.dart')
    ..writeAsStringSync(_mockEngineSource);
  final mockEngineBinary = await compileDartExecutable(
    mockEngineSourceFile,
    tempDir,
    name: 'mock_engine_binary',
  );

  // 2. Mock Cloud Admin & Catalog HTTP Server
  HttpOverrides.global = null;
  final mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  final storedReleases = <String, List<Map<String, dynamic>>>{};
  final storedWorkers = <Map<String, dynamic>>[];

  mockServer.listen((request) async {
    final path = request.uri.path;
    request.response.headers.contentType = ContentType.json;

    if (path == '/api/admin/workers/catalog') {
      if (request.method == 'POST') {
        final bodyStr = await utf8.decoder.bind(request).join();
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        storedWorkers.add(body);
        request.response.write(jsonEncode({'success': true, 'worker': body}));
      } else {
        request.response.write(jsonEncode({'workers': storedWorkers}));
      }
    } else if (path.contains('/draft')) {
      request.response.write(jsonEncode({'success': true, 'draftVersion': 1}));
    } else if (path.contains('/publish')) {
      request.response.statusCode = HttpStatus.conflict;
      request.response.write(jsonEncode({
        'error': 'A qualifying Cloud evidence record is required.',
      }));
    } else if (path.contains('/releases')) {
      final rels = storedReleases[official.definitionId] ?? [];
      request.response.write(jsonEncode({'releases': rels}));
    } else {
      request.response
          .write(jsonEncode({'workers': storedWorkers, 'releases': []}));
    }

    await request.response.close();
  });

  addTearDown(() => mockServer.close(force: true));

  final baseUrl = 'http://${mockServer.address.address}:${mockServer.port}';

  // -----------------------------------------------------------------------
  // STEP 1: Profile Lab Candidate Creation & Load Fixture
  // -----------------------------------------------------------------------
  final profileFile = File('$repositoryRoot/${official.profilePath}');
  final profileMap = Map<String, dynamic>.from(
    jsonDecode(await profileFile.readAsString()) as Map,
  );

  final candidate = LocalDraftProfileCandidate.fromProfileMap(profileMap);
  expect(candidate.logicalWorkerTypeId, equals(official.logicalWorkerTypeId));
  expect(candidate.isSigned, isFalse);

  // -----------------------------------------------------------------------
  // STEP 2: Exercise the ladder with a mock Engine that cannot run a provider.
  // -----------------------------------------------------------------------
  final sandbox = ProfileLabTestSandbox(
    sandboxRoot: sandboxDir,
    engineExecutable: mockEngineBinary,
  );

  final ladderRes = await sandbox.executeTestLadder(candidate: candidate);
  expect(ladderRes.stages.length, equals(11));
  expect(ladderRes.stages[0].status, equals('passed')); // schema
  expect(ladderRes.stages[1].status, equals('passed')); // engine compatibility
  expect(ladderRes.overallResult, equals('fail'));
  expect(
    ladderRes.stages
        .singleWhere((stage) => stage.stageId == 'passive_probe')
        .status,
    equals('failed'),
  );

  // -----------------------------------------------------------------------
  // STEP 3: Cloud refuses publication without qualifying evidence.
  // -----------------------------------------------------------------------
  final adminClient = ProfileAdminApiClient(
    baseUrl: baseUrl,
    httpClient: HttpClient(),
    session: ProfileLabSession(
      credential: 'operator_token_p29',
      sessionId: 'sess_p29',
      userId: 'usr_p29',
      displayName: 'Lead Operator',
      email: 'lead.operator@conclave.internal',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    ),
  );
  addTearDown(() => adminClient.close());

  // Create worker in catalog
  await adminClient.createWorker(
    workerTypeId: official.logicalWorkerTypeId,
    profileDefinitionId: official.definitionId,
    displayName: official.providerToolName,
    description: 'Release candidate for ${official.definitionId}',
    providerToolName: official.providerToolName,
    releaseStage: 'testing',
    capabilities: const ['text'],
    sortOrder: 1,
  );

  final draftRes = await adminClient.updateDraft(
    profileDefinitionId: official.definitionId,
    releaseVersion: 1,
    profile: profileMap,
  );
  expect(draftRes['success'], isTrue);

  // -----------------------------------------------------------------------
  await expectLater(
    adminClient.publishRelease(
      profileDefinitionId: official.definitionId,
      releaseVersion: 1,
      qualificationEvidenceId: 'unissued-qualification-id',
    ),
    throwsA(isA<StateError>().having(
      (error) => error.message,
      'message',
      contains('qualifying Cloud evidence record'),
    )),
  );
  expect(storedReleases[official.definitionId], isNull);
}

const _mockEngineSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final profileFileIndex = args.indexOf('--profile');
  final profile = profileFileIndex != -1
      ? jsonDecode(await File(args[profileFileIndex + 1]).readAsString()) as Map<String, dynamic>
      : <String, dynamic>{
          'logicalWorkerTypeId': 'chatgpt',
          'profileDefinitionId': 'chatgpt-codex',
          'releaseVersion': 1,
          'schemaVersion': 1,
          'capabilities': ['text'],
        };
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    switch (request['type']) {
      case 'initialize.request':
        stdout.writeln(jsonEncode({
          'type': 'initialize.result',
          'protocolVersion': '4.0',
          'requestId': request['requestId'],
          'workerTypeId': profile['logicalWorkerTypeId'],
          'engineVersion': '1.0.0',
          'profileDefinitionId': profile['profileDefinitionId'],
          'profileReleaseVersion': '${profile['releaseVersion']}',
          'profileSchemaVersion': profile['schemaVersion'],
          'capabilities': profile['capabilities'],
        }));
        await stdout.flush();
      case 'probe.request':
        stdout.writeln(jsonEncode({
          'type': 'probe.result',
          'requestId': request['requestId'],
          'mode': request['mode'] ?? 'passive',
          'ready': false,
          'issueCode': 'provider_tool_unavailable',
          'providerToolName': profile['providerTool']?['name'] ?? 'Provider CLI',
          'providerToolVersion': '1.0.0',
          'checks': [
            {
              'code': 'provider_tool_version',
              'status': 'failed',
              'message': 'Mock Engine does not run a provider probe',
            }
          ],
        }));
        await stdout.flush();
      case 'execute.request':
        stdout.writeln(jsonEncode({
          'type': 'error',
          'requestId': request['requestId'],
          'assignmentId': request['assignmentId'],
          'code': 'provider_tool_unavailable',
          'message': 'Mock Engine does not execute a provider CLI',
          'retryable': false,
        }));
        await stdout.flush();
    }
  }
}
''';

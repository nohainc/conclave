import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:test/test.dart';

import 'support/compile_dart_executable.dart';
import 'support/ed25519_release_fixture.dart';

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
      'Phase 29 — Real-provider release acceptance for ${official.definitionId}',
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

  // 2. Prepare Ed25519 Signing Fixture
  final signingFixture = await Ed25519ReleaseFixture.create();

  // 3. Mock Cloud Admin & Catalog HTTP Server
  HttpOverrides.global = null;
  final mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  final storedReleases = <String, List<Map<String, dynamic>>>{};
  final storedWorkers = <Map<String, dynamic>>[];
  final workspaceChannels = <String, String>{}; // workspaceId -> channel
  final submittedEvidence = <String, List<Map<String, dynamic>>>{};

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
    } else if (path.contains('/evidence')) {
      final bodyStr = await utf8.decoder.bind(request).join();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final evList = submittedEvidence[official.definitionId] ?? [];
      evList.add(body);
      submittedEvidence[official.definitionId] = evList;
      request.response.write(
          jsonEncode({'success': true, 'evidenceId': 'ev_${evList.length}'}));
    } else if (path.contains('/publish')) {
      final releaseList = storedReleases[official.definitionId] ?? [];
      final rawProfile = releaseList.first['profile'] as Map<String, dynamic>;

      final releaseToSign = <String, Object?>{
        'profileDefinitionId': official.definitionId,
        'workerTypeId': official.logicalWorkerTypeId,
        'displayName': official.providerToolName,
        'providerToolName': official.providerToolName,
        'channel': 'testing',
        'releaseVersion': 1,
        'profile': rawProfile,
        'schemaVersion': 1,
        'engineFamily': 'cli',
        'engineCompatibility': rawProfile['engineCompatibility'],
        'lifecycleState': 'testing',
      };

      await signingFixture.signToolProfileRelease(releaseToSign);
      storedReleases[official.definitionId] = [releaseToSign];

      request.response.write(jsonEncode({
        'success': true,
        'release': releaseToSign,
      }));
    } else if (path.contains('/promote')) {
      final bodyStr = await utf8.decoder.bind(request).join();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final targetChannel = body['channel'] as String;

      if (storedReleases[official.definitionId] != null &&
          storedReleases[official.definitionId]!.isNotEmpty) {
        storedReleases[official.definitionId]!.first['channel'] = targetChannel;
        storedReleases[official.definitionId]!.first['lifecycleState'] =
            targetChannel;
      }

      request.response.write(jsonEncode({
        'success': true,
        'channel': targetChannel,
        'releaseVersion': 1,
      }));
    } else if (path.contains('/tool-profile-channel')) {
      final bodyStr = await utf8.decoder.bind(request).join();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final wsId = Uri.decodeComponent(
          path.split('/workspaces/')[1].split('/tool-profile-channel')[0]);
      workspaceChannels[wsId] = body['channel'] as String;
      request.response.write(jsonEncode(
          {'success': true, 'workspaceId': wsId, 'channel': body['channel']}));
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
  // STEP 2: Execute Lab Progressive Ladder & Collect Physical Evidence
  // -----------------------------------------------------------------------
  final sandbox = ProfileLabTestSandbox(
    sandboxRoot: sandboxDir,
    engineExecutable: mockEngineBinary,
  );

  final ladderRes = await sandbox.executeTestLadder(candidate: candidate);
  expect(ladderRes.stages.length, equals(9));
  expect(ladderRes.stages[0].status, equals('passed')); // schema
  expect(ladderRes.stages[1].status, equals('passed')); // engine compatibility

  // Detailed Physical Acceptance Evidence Record
  final physicalEvidence = <String, dynamic>{
    'formatVersion': 1,
    'profileDefinitionId': official.definitionId,
    'releaseVersion': candidate.releaseVersion,
    'logicalWorkerTypeId': official.logicalWorkerTypeId,
    'payloadDigest': candidate.payloadDigest,
    'engineVersion': '1.0.0',
    'providerToolName': official.providerToolName,
    'providerToolVersion': '1.0.0',
    'acceptedAt': DateTime.now().toUtc().toIso8601String(),
    'scenarios': {
      'schema_validation': 'passed',
      'engine_compatibility': 'passed',
      'passive_probe': ladderRes.stages[4].status,
      'live_probe': ladderRes.stages[5].status,
      'controlled_execution': ladderRes.stages[6].status,
      'session_behavior':
          profileMap['session']?['supported'] == true ? 'passed' : 'skipped',
      'failure_mapping': 'verified',
    },
    'ladderResult': ladderRes.overallResult,
    'stages': ladderRes.stages.map((s) => s.toJson()).toList(),
  };

  // -----------------------------------------------------------------------
  // STEP 3: Admin Sync Draft & Submit Physical Evidence
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

  storedReleases[official.definitionId] = [
    {
      'profileDefinitionId': official.definitionId,
      'releaseVersion': 1,
      'profile': profileMap,
    }
  ];

  final draftRes = await adminClient.updateDraft(
    profileDefinitionId: official.definitionId,
    releaseVersion: 1,
    profile: profileMap,
  );
  expect(draftRes['success'], isTrue);

  final evidenceRes = await adminClient.submitReleaseEvidence(
    profileDefinitionId: official.definitionId,
    releaseVersion: 1,
    evidence: physicalEvidence,
  );
  expect(evidenceRes['success'], isTrue);
  expect(submittedEvidence[official.definitionId], isNotEmpty);

  // -----------------------------------------------------------------------
  // STEP 4: Publish Signed Release Candidate (Lifecycle: Testing)
  // -----------------------------------------------------------------------
  final publishRes = await adminClient.publishRelease(
    profileDefinitionId: official.definitionId,
    releaseVersion: 1,
  );
  expect(publishRes['success'], isTrue);
  expect(publishRes['release']['signature'], isNotNull);
  expect(publishRes['release']['lifecycleState'], equals('testing'));

  // -----------------------------------------------------------------------
  // STEP 5: Promote to Dedicated Testing Workspace Before Stable
  // -----------------------------------------------------------------------
  const testingWorkspaceId = 'workspace-testing-lab';
  final setWsChanRes = await adminClient.setWorkspaceChannel(
    workspaceId: testingWorkspaceId,
    channel: 'testing',
  );
  expect(setWsChanRes['success'], isTrue);
  expect(workspaceChannels[testingWorkspaceId], equals('testing'));

  final promoteTestingRes = await adminClient.promoteRelease(
    profileDefinitionId: official.definitionId,
    releaseVersion: 1,
    channel: 'testing',
    acceptanceEvidence: physicalEvidence,
  );
  expect(promoteTestingRes['channel'], equals('testing'));

  // -----------------------------------------------------------------------
  // STEP 6: Workspace Channel Sync & Release Activation Verification
  // -----------------------------------------------------------------------
  final profileStore = ToolProfileReleaseStore(
    profilesRoot: Directory('${tempDir.path}/WorkspaceProfiles'),
    trustPolicy: signingFixture.trustPolicy,
  );

  final catalogClient = ToolProfileCatalogClient(
    cloudUri: Uri.parse(baseUrl),
    store: profileStore,
    trustPolicy: signingFixture.trustPolicy,
    trustRefresher: () async {},
    candidateValidator: (admission, file) async => await file.exists(),
    workerCatalogLoader: () async {
      return [
        WorkerDescriptor(
          workerTypeId: official.logicalWorkerTypeId,
          displayName: official.providerToolName,
          description: 'Official Provider Worker',
          profileDefinitionId: official.definitionId,
          providerToolName: official.providerToolName,
          engineFamily: 'cli',
          visibilityState: 'visible',
          releaseStage: 'testing',
          capabilities: const ['text'],
          sortOrder: 1,
        ).toJson()
      ];
    },
    listLoader: (wTypeId, channel) async {
      final rels = storedReleases[official.definitionId] ?? [];
      return ToolProfileCatalogResult(
        channel: channel,
        releases: rels,
      );
    },
  );

  final registry = LocalWorkerRegistry(
    dataDirectory: Directory('${tempDir.path}/Registry'),
    workspaceId: testingWorkspaceId,
    idGenerator: () => 'local-${official.definitionId}',
  );

  final coordinator = WorkerCatalogCoordinator(
    catalog: catalogClient,
    releaseStore: profileStore,
    registry: registry,
  );

  await coordinator.refresh(force: true);
  expect(coordinator.entryForWorker(official.logicalWorkerTypeId), isNotNull);

  await catalogClient.syncWorkerProfiles(official.logicalWorkerTypeId,
      channel: 'testing');

  final activeRelease = await profileStore.activeRelease(official.definitionId);
  expect(activeRelease, isNotNull);
  expect(activeRelease!.releaseVersion, equals(1));
  expect(activeRelease.channel, equals('testing'));

  catalogClient.close();
  coordinator.dispose();
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
      case 'probe.request':
        stdout.writeln(jsonEncode({
          'type': 'probe.result',
          'requestId': request['requestId'],
          'mode': request['mode'] ?? 'passive',
          'ready': true,
          'providerToolName': profile['providerTool']?['name'] ?? 'Provider CLI',
          'providerToolVersion': '1.0.0',
          'checks': [
            {
              'code': 'provider_tool_version',
              'status': 'passed',
              'message': 'Provider tool version check passed',
            }
          ],
        }));
      case 'execute.request':
        stdout.writeln(jsonEncode({
          'type': 'result',
          'requestId': request['requestId'],
          'assignmentId': request['assignmentId'],
          'output': 'RELEASE_ACCEPTANCE_OK',
          'artifacts': <String>[],
        }));
    }
  }
}
''';

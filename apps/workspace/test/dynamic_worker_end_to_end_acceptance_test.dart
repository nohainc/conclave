import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/local_worker_setup.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:conclave_workspace/workspace_worker_view.dart';
import 'package:test/test.dart';

import 'support/compile_dart_executable.dart';
import 'support/ed25519_release_fixture.dart';

void main() {
  test('Phase 28 — Real end-to-end dynamic Worker acceptance scenario',
      () async {
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final dynamicWorkerTypeId = 'dyn-test-worker-$nonce';
    final dynamicProfileDefinitionId = 'dyn-test-profile-$nonce';
    final dynamicDisplayName = 'Dynamic Acceptance Worker $nonce';

    final tempDir =
        await Directory.systemTemp.createTemp('conclave-phase28-e2e-');
    addTearDown(() => tempDir.delete(recursive: true));

    final sandboxDir = Directory('${tempDir.path}/profile_lab_sandbox');
    await sandboxDir.create(recursive: true);

    // 1. Prepare Fixture Mock Engine Binary
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
    final channelPointers =
        <String, String>{}; // profileDefinitionId -> channel

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
        request.response
            .write(jsonEncode({'success': true, 'draftVersion': 1}));
      } else if (path.contains('/evidence')) {
        request.response
            .write(jsonEncode({'success': true, 'evidenceId': 'ev_123'}));
      } else if (path.contains('/publish')) {
        final defId = dynamicProfileDefinitionId;
        final releaseList = storedReleases[defId] ?? [];
        final rawProfile = releaseList.first['profile'] as Map<String, dynamic>;

        final releaseToSign = <String, Object?>{
          'profileDefinitionId': defId,
          'workerTypeId': dynamicWorkerTypeId,
          'displayName': dynamicDisplayName,
          'providerToolName': 'Dynamic CLI Tool',
          'channel': 'testing',
          'releaseVersion': 1,
          'profile': rawProfile,
          'schemaVersion': 1,
          'engineFamily': 'cli',
          'engineCompatibility': rawProfile['engineCompatibility'],
          'lifecycleState': 'testing',
        };

        await signingFixture.signToolProfileRelease(releaseToSign);
        storedReleases[defId] = [releaseToSign];
        channelPointers[defId] = 'testing';

        request.response.write(jsonEncode({
          'success': true,
          'release': releaseToSign,
        }));
      } else if (path.contains('/promote')) {
        final bodyStr = await utf8.decoder.bind(request).join();
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final targetChannel = body['channel'] as String;
        channelPointers[dynamicProfileDefinitionId] = targetChannel;

        if (storedReleases[dynamicProfileDefinitionId] != null &&
            storedReleases[dynamicProfileDefinitionId]!.isNotEmpty) {
          storedReleases[dynamicProfileDefinitionId]!.first['channel'] =
              targetChannel;
          storedReleases[dynamicProfileDefinitionId]!.first['lifecycleState'] =
              targetChannel;
        }

        request.response.write(jsonEncode({
          'success': true,
          'channel': targetChannel,
          'releaseVersion': 1,
        }));
      } else if (path.contains('/releases')) {
        final rels = storedReleases[dynamicProfileDefinitionId] ?? [];
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
    // STEP 1: Profile Lab — Create Worker & Definition, Edit Draft, Test, Publish, Promote
    // -----------------------------------------------------------------------
    final adminClient = ProfileAdminApiClient(
      baseUrl: baseUrl,
      httpClient: HttpClient(),
      session: ProfileLabSession(
        credential: 'admin_token_e2e',
        sessionId: 'sess_e2e',
        userId: 'usr_operator',
        displayName: 'Operator',
        email: 'operator@conclave.internal',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    addTearDown(() => adminClient.close());

    // 1.1 Register Worker Definition in Profile Lab
    final createWorkerRes = await adminClient.createWorker(
      workerTypeId: dynamicWorkerTypeId,
      profileDefinitionId: dynamicProfileDefinitionId,
      displayName: dynamicDisplayName,
      description:
          'Dynamically registered Worker for Phase 28 acceptance test.',
      providerToolName: 'Dynamic CLI Tool',
      releaseStage: 'testing',
      capabilities: ['text'],
      sortOrder: 99,
    );
    expect(createWorkerRes['success'], isTrue);

    // 1.2 Draft Profile Payload derived from fixture template
    final fixtureFile = File(
      '${Directory.current.parent.parent.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
    );
    final draftPayload = Map<String, dynamic>.from(
      jsonDecode(await fixtureFile.readAsString()) as Map,
    );
    draftPayload['profileDefinitionId'] = dynamicProfileDefinitionId;
    draftPayload['logicalWorkerTypeId'] = dynamicWorkerTypeId;
    draftPayload['providerTool'] =
        Map<String, dynamic>.from(draftPayload['providerTool'] as Map)
          ..['name'] = 'Dynamic CLI Tool'
          ..['executableCandidates'] = ['dart'];

    // Save draft payload on Cloud
    storedReleases[dynamicProfileDefinitionId] = [
      {
        'profileDefinitionId': dynamicProfileDefinitionId,
        'releaseVersion': 1,
        'profile': draftPayload,
      }
    ];
    final draftRes = await adminClient.updateDraft(
      profileDefinitionId: dynamicProfileDefinitionId,
      releaseVersion: 1,
      profile: draftPayload,
    );
    expect(draftRes['success'], isTrue);

    // 1.3 Run Progressive Test Ladder in Sandbox
    final sandbox = ProfileLabTestSandbox(
      sandboxRoot: sandboxDir,
      engineExecutable: mockEngineBinary,
    );
    final candidate = LocalDraftProfileCandidate.fromProfileMap(draftPayload);
    expect(candidate.logicalWorkerTypeId, equals(dynamicWorkerTypeId));
    expect(candidate.isSigned, isFalse);

    final ladderRes = await sandbox.executeTestLadder(candidate: candidate);
    expect(ladderRes.overallResult, equals('pass'));
    expect(ladderRes.stages.length, equals(9));
    expect(ladderRes.stages[0].status, equals('passed')); // schema
    expect(
        ladderRes.stages[1].status, equals('passed')); // engine compatibility

    // 1.4 Submit Evidence & Publish
    final evidenceRes = await adminClient.submitReleaseEvidence(
      profileDefinitionId: dynamicProfileDefinitionId,
      releaseVersion: 1,
      evidence: {
        'payloadDigest': candidate.payloadDigest,
        'ladderResult': 'pass',
        'stagesPassed': 9,
      },
    );
    expect(evidenceRes['success'], isTrue);

    final publishRes = await adminClient.publishRelease(
      profileDefinitionId: dynamicProfileDefinitionId,
      releaseVersion: 1,
    );
    expect(publishRes['success'], isTrue);
    expect(publishRes['release']['signature'], isNotNull);
    expect(publishRes['release']['lifecycleState'], equals('testing'));

    // 1.5 Promote Testing -> Beta -> Stable
    final promoteBetaRes = await adminClient.promoteRelease(
      profileDefinitionId: dynamicProfileDefinitionId,
      releaseVersion: 1,
      channel: 'beta',
    );
    expect(promoteBetaRes['channel'], equals('beta'));

    final promoteStableRes = await adminClient.promoteRelease(
      profileDefinitionId: dynamicProfileDefinitionId,
      releaseVersion: 1,
      channel: 'stable',
    );
    expect(promoteStableRes['channel'], equals('stable'));

    // -----------------------------------------------------------------------
    // STEP 2: Workspace — Dynamic Discovery, Setup, Inventory & AX Display
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
            workerTypeId: dynamicWorkerTypeId,
            displayName: dynamicDisplayName,
            description: 'Dynamically discovered worker',
            profileDefinitionId: dynamicProfileDefinitionId,
            providerToolName: 'Dynamic CLI Tool',
            engineFamily: 'cli',
            visibilityState: 'visible',
            releaseStage: 'stable',
            capabilities: const ['text'],
            sortOrder: 99,
          ).toJson()
        ];
      },
      listLoader: (wTypeId, channel) async {
        final rels = storedReleases[dynamicProfileDefinitionId] ?? [];
        return ToolProfileCatalogResult(
          channel: channel,
          releases: rels,
        );
      },
    );

    final registry = LocalWorkerRegistry(
      dataDirectory: Directory('${tempDir.path}/Registry'),
      workspaceId: 'workspace-e2e-phase28',
      idGenerator: () => 'local-$dynamicWorkerTypeId',
    );

    final coordinator = WorkerCatalogCoordinator(
      catalog: catalogClient,
      releaseStore: profileStore,
      registry: registry,
    );

    // Dynamic Discovery
    await coordinator.refresh(force: true);
    final entry = coordinator.entryForWorker(dynamicWorkerTypeId);
    expect(entry, isNotNull);
    expect(entry!.displayName, equals(dynamicDisplayName));
    expect(entry.profileDefinitionId, equals(dynamicProfileDefinitionId));

    // Sync & Install Profile Releases into Store
    await catalogClient.syncWorkerProfiles(dynamicWorkerTypeId,
        channel: 'stable');

    // Verify Release Store downloaded and installed the signed Stable release
    final activeRel =
        await profileStore.activeRelease(dynamicProfileDefinitionId);
    expect(activeRel, isNotNull);
    expect(activeRel!.releaseVersion, equals(1));
    expect(activeRel.channel, equals('stable'));

    // Configure Local Worker
    final setupService = LocalWorkerSetupService(registry: registry);
    final localWorker = await setupService.createCatalogWorker(
      entry: entry,
      permissions: const ['repository:read'],
    );
    expect(localWorker.workerTypeId, equals(dynamicWorkerTypeId));

    await coordinator.refreshLocalWorkers();
    final localWorkers = await registry.list();
    expect(
        localWorkers.map((w) => w.workerTypeId), contains(dynamicWorkerTypeId));

    // AX / Workspace View Model Verification
    final workerStateView = WorkerCatalogWorkerState(
      descriptor: WorkerDescriptor(
        workerTypeId: dynamicWorkerTypeId,
        displayName: dynamicDisplayName,
        description: 'Dynamically discovered worker',
        profileDefinitionId: dynamicProfileDefinitionId,
        providerToolName: 'Dynamic CLI Tool',
        engineFamily: 'cli',
        visibilityState: 'visible',
        releaseStage: 'stable',
        capabilities: const ['text'],
        sortOrder: 99,
      ),
      catalogRetired: false,
      localWorker: localWorker,
      localState: WorkspaceLocalWorkerState.configured,
      profileAvailability: const WorkerProfileResolution(
          state: WorkspaceWorkerProfileState.ready),
      providerToolState: WorkspaceProviderToolState.available,
    );

    expect(workerStateView.catalogAvailable, isTrue);
    expect(
        workerStateView.localWorker?.workerTypeId, equals(dynamicWorkerTypeId));
    expect(
      {WorkspaceWorkerState.ready, WorkspaceWorkerState.profileReady},
      contains(workerStateView.state),
    );

    // -----------------------------------------------------------------------
    // STEP 3: Workstream Selection & Generic Engine Execution
    // -----------------------------------------------------------------------
    final profileResolution = await coordinator.resolveProfileForWorker(
      workerTypeId: dynamicWorkerTypeId,
      engineVersion: '1.0.0',
    );
    expect(profileResolution.isAvailable, isTrue);
    final activeAdmission = profileResolution.release;
    expect(activeAdmission, isNotNull);
    expect(activeAdmission!.logicalWorkerTypeId, equals(dynamicWorkerTypeId));

    final supervisor = CliWorkerEngineSupervisor(
      engineExecutable: mockEngineBinary.path,
    );

    final stateDir = await Directory('${tempDir.path}/engine_state').create();
    final workstreamDir =
        await Directory('${tempDir.path}/workstream').create();
    final profileFile = profileStore.profileFile(dynamicProfileDefinitionId, 1);

    final result = await supervisor.execute(
      activeAdmission,
      profileFile: profileFile,
      stateDirectory: stateDir,
      workingDirectory: workstreamDir,
      workerId: localWorker.id,
      maxConcurrentAssignments: 1,
      assignmentId: 'assign_e2e_1',
      prompt: 'Verify dynamic worker execution',
      timeout: const Duration(seconds: 10),
    );

    expect(result.output, equals('Verify dynamic worker execution'));

    // Cleanup
    catalogClient.close();
    coordinator.dispose();
  });
}

const _mockEngineSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String valueAfter(List<String> args, String key) => args[args.indexOf(key) + 1];

Future<void> main(List<String> args) async {
  final profileFileIndex = args.indexOf('--profile');
  final profile = profileFileIndex != -1
      ? jsonDecode(await File(args[profileFileIndex + 1]).readAsString()) as Map<String, dynamic>
      : <String, dynamic>{
          'logicalWorkerTypeId': 'dynamic-worker',
          'profileDefinitionId': 'dynamic-profile',
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
          'providerToolName': 'Dynamic CLI Tool',
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
          'output': request['prompt'],
          'artifacts': <String>[],
        }));
    }
  }
}
''';

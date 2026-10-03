import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/local_worker_setup.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/workstream_directory.dart';
import 'package:conclave_workspace/workstream_path.dart';
import 'package:conclave_workspace/workspace_worker_view.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  test(
    'brand-new Profile Lab Worker is discovered by Workspace and executes AX Work without source changes',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp
          .createTemp('conclave-profile-lab-dynamic-e2e-');
      addTearDown(() => root.delete(recursive: true));

      final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final workerTypeId = 'phase-13-unknown-$suffix';
      final profileDefinitionId = 'phase-13-profile-$suffix';
      final displayName = 'Phase 13 Unknown Worker $suffix';
      final descriptorJson = <String, Object?>{
        'workerTypeId': workerTypeId,
        'displayName': displayName,
        'description': 'Created during the Profile Lab acceptance run.',
        'engineFamily': 'cli',
        'capabilities': ['text', 'workstream_write', 'durable_session'],
        'profileDefinitionId': profileDefinitionId,
        'providerToolName': 'Phase 13 Fixture CLI',
        'releaseStage': 'testing',
        'visibilityState': 'visible',
        'sortOrder': 9000,
      };

      final providerDirectory = Directory('${root.path}/provider-bin')
        ..createSync(recursive: true);
      final provider = File('${providerDirectory.path}/phase13-fixture')
        ..writeAsStringSync(_fixtureProviderScript);
      final chmod = await Process.run('chmod', ['700', provider.path]);
      expect(chmod.exitCode, 0, reason: '${chmod.stdout}\n${chmod.stderr}');
      final path = '${providerDirectory.path}${Platform.isWindows ? ';' : ':'}'
          '${Platform.environment['PATH'] ?? ''}';

      // Profile Lab authors a new catalog Worker and keeps its unsigned Draft
      // in its own Draft store. The only provider behavior is fixture data.
      final mockCloud = await _DynamicWorkerCloud.create(
        descriptorJson: descriptorJson,
        workerTypeId: workerTypeId,
        profileDefinitionId: profileDefinitionId,
      );
      addTearDown(mockCloud.close);
      final admin = ProfileAdminApiClient(
        baseUrl: mockCloud.baseUrl,
        httpClient: HttpClient(),
        session: ProfileLabSession(
          credential: 'test-admin-session',
          sessionId: 'phase13-session',
          userId: 'profile-lab-test-operator',
          displayName: 'Profile Lab Test Operator',
          email: 'profile-lab-test@example.invalid',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      addTearDown(admin.close);
      final created = await admin.createWorker(
        workerTypeId: workerTypeId,
        profileDefinitionId: profileDefinitionId,
        displayName: displayName,
        description: descriptorJson['description']! as String,
        providerToolName: 'Phase 13 Fixture CLI',
        releaseStage: 'testing',
        capabilities: ['text', 'workstream_write', 'durable_session'],
        sortOrder: 9000,
      );
      expect(created['success'], isTrue);
      expect(mockCloud.createdWorker?['workerTypeId'], workerTypeId);

      final profile = _dynamicProfile(
        workerTypeId: workerTypeId,
        profileDefinitionId: profileDefinitionId,
      );
      final createdDraft = await admin.createDraftRelease(
        profileDefinitionId: profileDefinitionId,
        releaseVersion: 1,
        profile: profile,
      );
      expect(createdDraft['success'], isTrue);
      final cloudDraft = await admin.updateDraft(
        profileDefinitionId: profileDefinitionId,
        releaseVersion: 1,
        profile: profile,
      );
      expect(cloudDraft['success'], isTrue);
      expect(mockCloud.draftProfile?['logicalWorkerTypeId'], workerTypeId);

      final engine = File(
        '$repository/apps/workspace/assets/engines/'
        'conclave_cli_worker_engine${Platform.isWindows ? '.exe' : ''}',
      );
      expect(await engine.exists(), isTrue,
          reason: 'Acceptance requires the actual bundled CLI Worker Engine.');
      final labStore = DraftProfileStore(
        draftsRoot: Directory('${root.path}/profile-lab-drafts'),
      );
      final persistedDraft = await labStore.saveDraft(
        profileDefinitionId: profileDefinitionId,
        profileJson: profile,
        author: 'Phase 13 Profile Lab acceptance',
      );
      expect(persistedDraft.isSigned, isFalse);
      final candidate = await labStore.loadDraft(profileDefinitionId);
      expect(candidate, isNotNull);
      final labSandboxRoot = Directory('${root.path}/profile-lab-sandbox')
        ..createSync(recursive: true);
      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: labSandboxRoot,
        engineExecutable: engine,
        environmentOverrides: {'PATH': path, 'HOME': root.path},
      );
      final discoveryResult =
          await sandbox.executeTestLadder(candidate: candidate!);
      expect(discoveryResult.overallResult, 'fail');
      final versionStage = discoveryResult.stages
          .firstWhere((stage) => stage.stageId == 'cli_version');
      expect(versionStage.status, 'failed');
      final suggestedMin = versionStage.details['suggestedMin']! as String;
      final suggestedMax =
          versionStage.details['suggestedMaxExclusive']! as String;
      (profile['providerTool']! as Map<String, Object?>)['supportedVersions'] =
          [
        {'min': suggestedMin, 'maxExclusive': suggestedMax},
      ];
      final configuredDraft = await admin.updateDraft(
        profileDefinitionId: profileDefinitionId,
        releaseVersion: 1,
        profile: profile,
      );
      expect(configuredDraft['success'], isTrue);
      await labStore.saveDraft(
        profileDefinitionId: profileDefinitionId,
        profileJson: profile,
        author: 'Phase 13 Profile Lab acceptance',
      );
      final configuredCandidate = await labStore.loadDraft(profileDefinitionId);
      expect(configuredCandidate, isNotNull);

      final labResult =
          await sandbox.executeTestLadder(candidate: configuredCandidate!);
      expect(
        labResult.overallResult,
        'pass',
        reason: labResult.stages
            .map((stage) =>
                '${stage.stageId}:${stage.status}:${stage.diagnostics}')
            .join('\n'),
      );
      final qualification = labResult.acceptanceEvidence!.toJson();
      expect(qualification['logicalWorkerTypeId'], workerTypeId);
      expect(qualification['profileDigest'], configuredCandidate.payloadDigest);
      final qualificationResponse = await admin.submitLocalQualification(
        profileDefinitionId: profileDefinitionId,
        releaseVersion: 1,
        evidence: qualification,
      );
      final qualificationEvidenceId =
          qualificationResponse['qualificationEvidenceId']! as String;
      expect(mockCloud.qualificationEvidence?['profileDigest'],
          configuredCandidate.payloadDigest);

      // The fake Cloud boundary applies a test-only signing key after it has
      // received the exact qualification ID. Production signing remains Cloud-owned.
      final signing = await Ed25519ReleaseFixture.create();
      mockCloud.signing = signing;
      final published = await admin.publishRelease(
        profileDefinitionId: profileDefinitionId,
        releaseVersion: 1,
        qualificationEvidenceId: qualificationEvidenceId,
      );
      expect(published['release'], isA<Map>());
      final release = Map<String, Object?>.from(published['release'] as Map);
      expect(release['channel'], 'testing');
      expect(release['logicalWorkerTypeId'] ?? release['workerTypeId'],
          workerTypeId);
      expect(mockCloud.publishedQualificationId, qualificationEvidenceId);

      // Workspace discovers an unknown catalog identity from Cloud, downloads
      // the signed Testing Profile, probes the real fixture CLI, and registers
      // a local Worker without any new Worker-specific source branch.
      final profileStore = ToolProfileReleaseStore(
        profilesRoot: Directory('${root.path}/workspace-profiles'),
        trustPolicy: signing.trustPolicy,
      );
      final workspaceEngine = CliWorkerEngineSupervisor(
        engineExecutable: engine.path,
        environmentOverrides: {'PATH': path, 'HOME': root.path},
      );
      final catalog = ToolProfileCatalogClient(
        cloudUri: Uri.parse(mockCloud.baseUrl),
        store: profileStore,
        trustPolicy: signing.trustPolicy,
        workspaceRuntimeId: 'phase13-runtime',
        authToken: 'phase13-workspace-token',
        trustRefresher: () async {},
        candidateValidator: (admission, profileFile) async {
          final result = await workspaceEngine.probe(
            admission,
            profileFile: profileFile,
            stateDirectory: Directory(
                '${root.path}/workspace-probes/${admission.profileDefinitionId}'),
            mode: WorkerProbeMode.passive,
            timeout: const Duration(seconds: 10),
          );
          return result.ready;
        },
      );
      addTearDown(catalog.close);
      final registry = LocalWorkerRegistry(
        dataDirectory: Directory('${root.path}/workspace-registry'),
        workspaceId: 'phase13-workspace',
        idGenerator: () => 'phase13-local-worker-$suffix',
      );
      final coordinator = WorkerCatalogCoordinator(
        catalog: catalog,
        releaseStore: profileStore,
        registry: registry,
      );
      addTearDown(coordinator.dispose);
      await coordinator.refresh(force: true);
      expect(
          coordinator.entryForWorker(workerTypeId)?.displayName, displayName);
      expect(
        coordinator.snapshot.profiles[workerTypeId]?.state,
        WorkspaceWorkerProfileState.ready,
      );
      final descriptor = coordinator.entryForWorker(workerTypeId)!;
      final localWorker =
          await LocalWorkerSetupService(registry: registry).createCatalogWorker(
        entry: descriptor,
        permissions: const ['repository:read', 'repository:write'],
      );
      mockCloud.localWorkerId = localWorker.id;
      await coordinator.refreshLocalWorkers();
      final readiness = WorkerReadinessMonitor(
        registry: registry,
        toolProfileReleaseStore: profileStore,
        workerCatalogCoordinator: coordinator,
        cliWorkerEngineSupervisor: workspaceEngine,
        workerStateDirectory: (workerId) =>
            Directory('${root.path}/workspace-workers/$workerId/state'),
      );
      await readiness.checkNow(workerTypeId: workerTypeId);
      final readyWorker = (await registry.find(localWorker.id))!;
      expect(readyWorker.readinessState, WorkerReadinessState.ready,
          reason: readyWorker.readinessIssueCode);
      final inventory = await coordinator.inventoryForWorkers(
        await registry.list(),
        engineVersion: cliWorkerEngineVersion,
        engineAvailable: true,
      );
      // Cloud joins the Workspace runtime projection to its approved catalog
      // descriptor before exposing the safe inventory record to AX.
      final axWorkerProjection = {
        ...inventory.single,
        'workspaceId': 'phase13-workspace',
        'workspaceName': 'Phase 13 Acceptance Workspace',
        'displayName': descriptor.displayName,
      };
      expect(axWorkerProjection['workerTypeId'], workerTypeId);
      expect(axWorkerProjection['displayName'], displayName);
      expect(axWorkerProjection['readinessState'], 'ready');

      // AX creates the Work Request over HTTP. The test Cloud boundary applies
      // its Workstream binding and dispatches the resulting assignment.
      final workRoot = Directory('${root.path}/workspace-work-root')
        ..createSync(recursive: true);
      final workstreamLifecycle = WorkstreamDirectoryLifecycle(
        pathResolver: WorkstreamPathResolver(workRoot),
      );
      final handler = WorkerAssignmentHandler(
        resolveLogicalWorker: (workerId) async {
          final configured = await registry.find(workerId);
          if (configured == null) return null;
          final catalogEntry =
              await coordinator.ensureCatalogEntry(configured.workerTypeId);
          return AssignmentLogicalWorker(
            id: configured.id,
            workerTypeId: configured.workerTypeId,
            enabled: catalogEntry != null &&
                configured.activationState ==
                    LocalWorkerActivationState.enabled,
            ready: catalogEntry != null &&
                configured.status == LocalWorkerStatus.ready,
            permissions: configured.localPermissions.toSet(),
            localConcurrencyLimit: configured.localConcurrencyLimit,
            providerCliVersion: configured.toolVersion,
          );
        },
        defaultWorkingDirectory: Directory('${root.path}/work'),
        workstreamDirectoryLifecycle: workstreamLifecycle,
        executeWithToolProfile:
            (logicalWorker, workingDirectory, context, payload,
                {onProgress}) async {
          final resolution = await coordinator.resolveProfileForWorker(
            workerTypeId: logicalWorker.workerTypeId,
            engineVersion: cliWorkerEngineVersion,
            providerCliVersion: logicalWorker.providerCliVersion,
          );
          final admitted = resolution.release;
          if (admitted == null) {
            throw StateError(
                'Profile Lab-created Worker has no admitted release');
          }
          final input = Map<String, Object?>.from(payload['input']! as Map);
          return workspaceEngine.execute(
            admitted,
            profileFile: profileStore.profileFile(
              profileDefinitionId,
              admitted.releaseVersion,
            ),
            stateDirectory: Directory(
                '${root.path}/workspace-workers/${logicalWorker.id}/state'),
            workingDirectory: workingDirectory,
            workerId: logicalWorker.id,
            maxConcurrentAssignments: logicalWorker.localConcurrencyLimit,
            assignmentId: context.assignmentId,
            prompt: input['prompt']! as String,
            timeout: const Duration(seconds: 30),
          );
        },
      );
      mockCloud.assignmentExecutor = (prompt, workRequestId) => handler(
            WorkspaceAssignmentContext(
              workspaceId: 'phase13-workspace',
              workspaceRuntimeId: 'phase13-runtime',
              workerId: localWorker.id,
              runId: 'phase13-work-run',
              taskId: 'phase13-work-step',
              attemptId: 'phase13-work-attempt',
              assignmentId: 'phase13-work-assignment',
              idempotencyKey: 'phase13-work-idempotency',
              payload: {
                'workerId': localWorker.id,
                'workerTypeId': workerTypeId,
                'projectId': 'phase13-project',
                'workstreamId': 'phase13-workstream',
                'workRequestId': workRequestId,
                'executionClass': 'stateless_read',
                'timeoutMs': 30000,
                'input': {'prompt': prompt},
              },
            ),
          );
      final ax = AxApiClient(baseUrl: mockCloud.baseUrl);
      addTearDown(ax.client.close);
      final workRequestId = await ax.createWorkRequest(
        workstreamId: 'phase13-workstream',
        workflowId: 'direct',
        prompt: 'Implement the Phase 13 acceptance task.',
      );
      final workStatus = await ax.loadWorkRequest(
        workRequestId: workRequestId,
      );
      expect(workStatus.status, 'completed');
      expect(workStatus.text, 'WORK_DONE');
      expect(workStatus.steps, hasLength(1));
      expect(workStatus.steps.single.workerTypeId, workerTypeId);
      expect(workStatus.steps.single.workerDisplayName, displayName);
      expect(workStatus.steps.single.resultText, 'WORK_DONE');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Map<String, Object?> _dynamicProfile({
  required String workerTypeId,
  required String profileDefinitionId,
}) =>
    {
      'schemaVersion': 1,
      'profileDefinitionId': profileDefinitionId,
      'releaseVersion': 1,
      'logicalWorkerTypeId': workerTypeId,
      'engineFamily': 'cli',
      'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
      'providerTool': {
        'name': 'Phase 13 Fixture CLI',
        'executableCandidates': ['phase13-fixture'],
        'discovery': {'standardLocations': [], 'allowPathSearch': true},
        'versionProbe': {
          'arguments': ['--version'],
          'timeoutMs': 10000,
          'source': 'stdout',
          'extract': {'kind': 'regex_capture', 'patternId': 'semver'},
        },
        'supportedVersions': <Map<String, String>>[],
      },
      'environment': {
        'passthrough': ['PATH', 'HOME'],
        'set': {},
      },
      'probe': {
        'passive': {
          'checks': [
            {
              'id': 'fixture-readiness',
              'arguments': ['probe'],
              'timeoutMs': 5000,
              'successExitCodes': [0],
              'failureIssueCode': 'provider_authentication_required',
            },
          ],
          'configChecks': [],
        },
        'live': {
          'timeoutMs': 10000,
          'expectedFinalText': {'kind': 'exact', 'value': 'OK'},
        },
      },
      'execution': {
        'arguments': [
          'run',
          {'modelArguments': true},
          {'sessionResumeArguments': true},
          {'providerTimeoutArguments': true},
        ],
        'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
        'output': {'mode': 'single_json'},
        'events': [
          {
            'when': [],
            'actions': [
              {'type': 'set_session', 'selector': r'$.sessionId'},
              {'type': 'set_final_text', 'selector': r'$.text'},
              {'type': 'mark_success'},
            ],
          },
        ],
      },
      'session': {
        'supported': true,
        'formatId': 'phase13-session-v1',
        'compatibleFormatIds': ['phase13-session-v1'],
        'extract': r'$.sessionId',
        'resumeArguments': [],
        'requireObservedIdMatch': false,
      },
      'model': {
        'supported': true,
        'arguments': ['--model', '{{model}}'],
        'allowlist': ['phase13-fixture-model'],
        'unknownModelPolicy': 'profile_allowlist',
      },
      'timeout': {'providerArguments': [], 'providerReserveMs': 0},
      'sandbox': {
        'mappings': {
          'restricted': [],
          'provider_default': [],
          'full_access': [],
        },
      },
      'progress': [],
      'errors': {
        'mappings': [
          {
            'evidence': {'kind': 'exit_code', 'value': 2},
            'issueCode': 'provider_failure',
          },
          {
            'evidence': {'kind': 'missing_terminal'},
            'issueCode': 'provider_failure',
          },
        ],
      },
      'capabilities': ['text', 'workstream_write', 'durable_session'],
      'compatibilityOverrides': [],
    };

const _fixtureProviderScript = r'''#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "phase13-fixture 1.2.3"
  exit 0
fi
if [ "$1" = "probe" ]; then
  echo "ready"
  exit 0
fi
prompt=$(cat)
case "$* $prompt" in
  *cancellation*|*timeout*) sleep 30 ;;
esac
case "$* $prompt" in
  *acceptance-write.txt*) printf 'conclave-profile-lab-write-verified' > acceptance-write.txt ;;
esac
case "$* $prompt" in
  *"Reply with exactly the word OK"*) text=OK ;;
  *) text=WORK_DONE ;;
esac
printf '{"sessionId":"phase13-fixture-session","text":"%s"}\n' "$text"
''';

final class _DynamicWorkerCloud {
  _DynamicWorkerCloud._({
    required this.server,
    required this.descriptorJson,
    required this.workerTypeId,
    required this.profileDefinitionId,
  });

  final HttpServer server;
  final Map<String, Object?> descriptorJson;
  final String workerTypeId;
  final String profileDefinitionId;
  Map<String, dynamic>? createdWorker;
  final Map<int, Map<String, Object?>> cloudDrafts = {};
  Map<String, Object?>? draftProfile;
  Map<String, Object?>? qualificationEvidence;
  String? publishedQualificationId;
  Ed25519ReleaseFixture? signing;
  Map<String, Object?>? release;
  String? localWorkerId;
  Future<WorkspaceAssignmentResult> Function(
      String prompt, String workRequestId)? assignmentExecutor;
  Map<String, Object?>? workRequestResponse;

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  static Future<_DynamicWorkerCloud> create({
    required Map<String, Object?> descriptorJson,
    required String workerTypeId,
    required String profileDefinitionId,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cloud = _DynamicWorkerCloud._(
      server: server,
      descriptorJson: descriptorJson,
      workerTypeId: workerTypeId,
      profileDefinitionId: profileDefinitionId,
    );
    server.listen(cloud._handle);
    return cloud;
  }

  Future<void> _handle(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    final body = request.method == 'GET'
        ? <String, Object?>{}
        : Map<String, Object?>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
    final path = request.uri.path;
    if (path.startsWith('/workstreams/') &&
        path.endsWith('/work-requests') &&
        request.method == 'POST') {
      final executor = assignmentExecutor;
      if (executor == null || body['workflowId'] != 'direct') {
        request.response.statusCode = HttpStatus.conflict;
        request.response
            .write(jsonEncode({'error': 'Work binding unavailable'}));
      } else {
        final input = Map<String, Object?>.from(body['input']! as Map);
        final workRequestId =
            'work-request-00000000-0000-4000-8000-000000000013';
        final assignment = await executor(
          input['originalRequest']! as String,
          workRequestId,
        );
        workRequestResponse = {
          'workRequest': {
            'id': workRequestId,
            'status': 'completed',
            'workflowId': 'direct',
            'workflowVersion': 1,
          },
          'result': {'text': assignment.summary},
          'steps': [
            {
              'kind': 'implement',
              'status': 'completed',
              'workerId': localWorkerId,
              'workerTypeId': workerTypeId,
              'workerDisplayName': descriptorJson['displayName'],
              'engineVersion': cliWorkerEngineVersion,
              'profileDefinitionId': profileDefinitionId,
              'profileReleaseVersion': 1,
              'providerToolName': descriptorJson['providerToolName'],
              'providerToolVersion': '1.2.3',
              'resultText': assignment.summary,
              'assignmentId': 'phase13-work-assignment',
              'sessionPolicy': 'stateless',
            },
          ],
        };
        request.response.write(jsonEncode({
          'workRequest': {'id': workRequestId}
        }));
      }
    } else if (path.startsWith('/work-requests/') &&
        request.method == 'GET' &&
        workRequestResponse != null) {
      request.response.write(jsonEncode(workRequestResponse));
    } else if (path == '/api/workspace-runtime/workers/catalog' &&
        request.method == 'GET') {
      request.response.write(jsonEncode({
        'channel': 'testing',
        'workers': [descriptorJson],
      }));
    } else if (path == '/api/tool-profiles' &&
        request.method == 'GET' &&
        request.uri.queryParameters['workerTypeId'] == workerTypeId) {
      request.response.write(jsonEncode({
        'channel': 'testing',
        'profiles': [release],
      }));
    } else if (path == '/api/admin/workers/catalog' &&
        request.method == 'POST') {
      createdWorker = Map<String, dynamic>.from(body);
      request.response.write(jsonEncode({'success': true, 'worker': body}));
    } else if (path.endsWith('/releases') && request.method == 'POST') {
      final version = body['releaseVersion']! as int;
      if (cloudDrafts.containsKey(version)) {
        request.response.statusCode = HttpStatus.conflict;
        request.response.write(jsonEncode({'error': 'draft already exists'}));
      } else {
        final profile = Map<String, Object?>.from(body['profile']! as Map);
        cloudDrafts[version] = profile;
        draftProfile = profile;
        request.response.statusCode = HttpStatus.created;
        request.response.write(jsonEncode({
          'success': true,
          'status': 'draft',
          'payloadDigest': 'phase13-draft-digest-$version',
        }));
      }
    } else if (path.endsWith('/draft') && request.method == 'PUT') {
      final version = int.parse(path.split('/').reversed.skip(1).first);
      if (!cloudDrafts.containsKey(version)) {
        request.response.statusCode = HttpStatus.notFound;
        request.response
            .write(jsonEncode({'error': 'draft release not found'}));
      } else {
        draftProfile = Map<String, Object?>.from(body['profile']! as Map);
        cloudDrafts[version] = draftProfile!;
        request.response.write(jsonEncode({
          'success': true,
          'draftVersion': version,
          'payloadDigest': 'phase13-updated-digest-$version',
        }));
      }
    } else if (path.endsWith('/qualification') && request.method == 'POST') {
      qualificationEvidence =
          Map<String, Object?>.from(body['evidence']! as Map);
      request.response.write(jsonEncode({
        'success': true,
        'qualificationEvidenceId': 'phase13-qualification-1',
      }));
    } else if (path.endsWith('/publish') && request.method == 'POST') {
      publishedQualificationId = body['qualificationEvidenceId'] as String?;
      final profile = draftProfile;
      final signer = signing;
      if (publishedQualificationId != 'phase13-qualification-1' ||
          profile == null ||
          signer == null) {
        request.response.statusCode = HttpStatus.conflict;
        request.response.write(jsonEncode({'error': 'qualification required'}));
      } else {
        final candidate = <String, Object?>{
          'profileDefinitionId': profileDefinitionId,
          'workerTypeId': workerTypeId,
          'displayName': descriptorJson['displayName'],
          'providerToolName': descriptorJson['providerToolName'],
          'channel': 'testing',
          'releaseVersion': 1,
          'profile': profile,
          'schemaVersion': profile['schemaVersion'],
          'engineFamily': profile['engineFamily'],
          'engineCompatibility': profile['engineCompatibility'],
        };
        await signer.signToolProfileRelease(candidate);
        release = candidate;
        request.response.write(jsonEncode({'release': candidate}));
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'not found'}));
    }
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

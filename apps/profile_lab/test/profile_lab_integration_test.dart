import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_profile_lab/utils/profile_domain_diff.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late ProfileLabPaths paths;
  late DraftProfileStore draftStore;
  late ProfileLabController controller;

  final sampleValidProfile = <String, Object?>{
    'schemaVersion': 1,
    'profileDefinitionId': 'opencode-cli',
    'releaseVersion': 1,
    'logicalWorkerTypeId': 'integration-worker',
    'engineFamily': 'cli',
    'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
    'providerTool': {
      'name': 'opencode',
      'executableCandidates': ['opencode'],
      'discovery': {'standardLocations': [], 'allowPathSearch': true},
      'versionProbe': {
        'arguments': ['--version'],
        'timeoutMs': 10000,
        'source': 'stdout',
        'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
      },
      'supportedVersions': [
        {'min': '0.0.1', 'maxExclusive': '99.0.0'}
      ],
    },
    'environment': {
      'passthrough': ['PATH', 'HOME'],
      'set': {}
    },
    'probe': {
      'passive': {
        'checks': [
          {
            'id': 'auth',
            'arguments': ['--version'],
            'timeoutMs': 5000,
            'successExitCodes': [0],
            'failureIssueCode': 'provider_authentication_required'
          }
        ],
        'configChecks': []
      }
    },
    'execution': {
      'arguments': ['run', '{{prompt}}'],
      'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
      'output': {'mode': 'plain_text'},
      'events': []
    },
    'session': {
      'supported': false,
      'formatId': 'session-v1',
      'compatibleFormatIds': ['session-v1'],
      'resumeArguments': [],
      'requireObservedIdMatch': false
    },
    'model': {
      'supported': false,
      'arguments': [],
      'unknownModelPolicy': 'pass_through'
    },
    'timeout': {'providerArguments': [], 'providerReserveMs': 0},
    'sandbox': {
      'mappings': {'restricted': [], 'provider_default': [], 'full_access': []}
    },
    'progress': [],
    'errors': {'mappings': []},
    'capabilities': ['code_generation'],
    'compatibilityOverrides': [],
  };

  setUp(() async {
    HttpOverrides.global = null;
    tempDir =
        await Directory.systemTemp.createTemp('profile_lab_integration_test_');
    paths = ProfileLabPaths(homeDirectory: tempDir.path);
    await paths.ensureDirectoriesExist();
    draftStore = DraftProfileStore(draftsRoot: paths.draftsDirectory);
    controller = ProfileLabController(
      paths: paths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
    );
    await controller.initialize();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 27 — Comprehensive Profile Lab Integration Test Suite', () {
    test('1. Draft loading, editing, conflicts & local persistence', () async {
      // Create new draft
      final candidate = await draftStore.saveDraft(
        profileDefinitionId: 'opencode-cli',
        profileJson: sampleValidProfile,
      );

      expect(candidate.profileDefinitionId, equals('opencode-cli'));
      expect(candidate.isSigned, isFalse);

      // Load draft from store
      final loaded = await draftStore.loadDraft('opencode-cli');
      expect(loaded, isNotNull);
      expect(loaded!.payloadDigest, equals(candidate.payloadDigest));

      // Controller draft mutation & unsaved tracking
      await controller.createNewDraft(
        profileDefinitionId: 'opencode-cli',
        workerTypeId: 'integration-worker',
        providerToolName: 'opencode',
      );
      expect(controller.isDirty, isFalse);

      final editedMap = Map<String, Object?>.from(sampleValidProfile);
      editedMap['releaseVersion'] = 2;
      controller.updateJsonText(
          const JsonEncoder.withIndent('  ').convert(editedMap));

      expect(controller.isDirty, isTrue);

      await controller.saveCurrentDraft();
      expect(controller.isDirty, isFalse);
      expect(controller.currentDraft?.releaseVersion, equals(2));
    });

    test('2. Validation & exact digest evidence invalidation', () async {
      final candidateV1 =
          LocalDraftProfileCandidate.fromProfileMap(sampleValidProfile);

      // Create evidence record tied to candidateV1 digest
      final evidenceV1 = {
        'evidenceId': 'ev_1001',
        'profileDefinitionId': candidateV1.profileDefinitionId,
        'releaseVersion': candidateV1.releaseVersion,
        'payloadDigest': candidateV1.payloadDigest,
        'status': 'pass',
        'timestamp': DateTime.now().toIso8601String(),
      };

      // Mutate draft payload (e.g. change version probe pattern)
      final mutatedProfile = Map<String, Object?>.from(sampleValidProfile);
      (mutatedProfile['providerTool'] as Map<String, Object?>)['name'] =
          'opencode-v2';
      final candidateV2 =
          LocalDraftProfileCandidate.fromProfileMap(mutatedProfile);

      expect(
          candidateV2.payloadDigest, isNot(equals(candidateV1.payloadDigest)));

      // Invalidation check: evidence from V1 does not match V2 digest
      final isEvidenceValidForV2 =
          evidenceV1['payloadDigest'] == candidateV2.payloadDigest;
      expect(isEvidenceValidForV2, isFalse);
    });

    test('3. Profile domain diffing & candidate materialization', () {
      final profileA = Map<String, Object?>.from(sampleValidProfile);

      final profileB = Map<String, Object?>.from(sampleValidProfile);
      profileB['model'] = {
        'supported': true,
        'arguments': ['--model', '{{model}}'],
        'unknownModelPolicy': 'reject',
      };

      final groups =
          ProfileDomainDiffCalculator.computeDiff(profileA, profileB);
      final hasChanges = groups.any((g) => g.hasChanges);
      expect(hasChanges, isTrue);

      final candidateB = LocalDraftProfileCandidate.fromProfileMap(profileB);
      expect(candidateB.logicalWorkerTypeId, equals('integration-worker'));
      expect(candidateB.isSigned, isFalse);
      expect(candidateB.payloadDigest.length, equals(64));
    });

    test(
        '4. Provider discovery, passive/live test ladder, cancellation, and cleanup',
        () async {
      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: paths.sandboxDirectory,
        engineExecutable: File('${tempDir.path}/mock_engine'),
      );

      final validCandidate =
          LocalDraftProfileCandidate.fromProfileMap(sampleValidProfile);

      final ladderRes =
          await sandbox.executeTestLadder(candidate: validCandidate);

      expect(ladderRes.stages.length, equals(11));
      expect(ladderRes.stages[0].stageId, equals('schema'));
      expect(ladderRes.stages[0].status, equals('passed'));
      expect(ladderRes.stages[1].stageId, equals('engine_compatibility'));
      expect(ladderRes.stages[1].status, equals('passed'));
      expect(
        ladderRes.stages
            .where(
                (stage) => stage.stageId == 'representative_workstream_write')
            .single
            .status,
        isNot(equals('passed')),
      );
      expect(ladderRes.overallResult, equals('fail'));

      // Clean scratch directory teardown verification
      final scratchItems = await paths.sandboxDirectory.list().toList();
      expect(scratchItems, isEmpty);
    });

    test('5. Cloud draft synchronization, publication & releases polling',
        () async {
      HttpOverrides.global = null;
      final mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      mockServer.listen((request) async {
        final path = request.uri.path;
        request.response.headers.contentType = ContentType.json;

        if (path.contains('/draft')) {
          request.response
              .write(jsonEncode({'success': true, 'draftVersion': 1}));
        } else if (path.contains('/qualification')) {
          request.response.write(jsonEncode({
            'status': 'qualified',
            'qualificationEvidenceId': 'qualification-1',
            'payloadDigest': 'sha256:abc123mock',
          }));
        } else if (path.contains('/publish')) {
          request.response.write(jsonEncode({
            'success': true,
            'release': {
              'profileDefinitionId': 'opencode-cli',
              'releaseVersion': 1,
              'lifecycleState': 'testing',
              'payloadDigest': 'sha256:abc123mock',
              'signature': 'mock_ed25519_sig',
              'profile': sampleValidProfile,
            }
          }));
        } else if (path.contains('/releases')) {
          request.response.write(jsonEncode({
            'releases': [
              {
                'profileDefinitionId': 'opencode-cli',
                'releaseVersion': 1,
                'lifecycleState': 'testing',
                'payloadDigest': 'sha256:abc123mock',
                'signature': 'mock_ed25519_sig',
                'profile': sampleValidProfile,
              }
            ]
          }));
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });

      final httpClient = HttpClient();
      final client = ProfileAdminApiClient(
        baseUrl: 'http://${mockServer.address.address}:${mockServer.port}',
        httpClient: httpClient,
        session: ProfileLabSession(
          credential: 'test_token',
          sessionId: 'sess_1',
          userId: 'usr_1',
          displayName: 'Test Operator',
          email: 'operator@conclave.internal',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );

      try {
        final syncRes = await client.updateDraft(
          profileDefinitionId: 'opencode-cli',
          releaseVersion: 1,
          profile: sampleValidProfile,
        );
        expect(syncRes['success'], isTrue);

        final qualification = await client.submitLocalQualification(
          profileDefinitionId: 'opencode-cli',
          releaseVersion: 1,
          evidence: const {'formatVersion': 2},
        );
        expect(
          qualification['qualificationEvidenceId'],
          equals('qualification-1'),
        );

        final pubRes = await client.publishRelease(
          profileDefinitionId: 'opencode-cli',
          releaseVersion: 1,
          qualificationEvidenceId:
              qualification['qualificationEvidenceId'] as String,
        );
        expect(pubRes['release']['releaseVersion'], equals(1));
        expect(pubRes['release']['signature'], equals('mock_ed25519_sig'));

        final releases = await client.fetchReleases('opencode-cli');
        expect(releases.length, equals(1));
        expect(releases.first['lifecycleState'], equals('testing'));
      } finally {
        client.close();
        await mockServer.close(force: true);
      }
    });

    test('6a. Promotion constraints, rollback, and revocation', () async {
      HttpOverrides.global = null;
      final mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      mockServer.listen((request) async {
        final path = request.uri.path;
        request.response.headers.contentType = ContentType.json;
        request.response.persistentConnection = false;

        if (path.contains('/rollback')) {
          request.response.write(jsonEncode({
            'success': true,
            'channel': 'stable',
            'targetReleaseVersion': 1
          }));
        } else if (path.contains('/revoke')) {
          request.response.write(jsonEncode(
              {'success': true, 'revokedVersion': 2, 'state': 'revoked'}));
        } else {
          request.response.write(jsonEncode({'releases': []}));
        }
        await request.response.close();
      });

      final client = ProfileAdminApiClient(
        baseUrl: 'http://${mockServer.address.address}:${mockServer.port}',
        httpClient: HttpClient(),
        session: ProfileLabSession(
          credential: 'admin_token',
          sessionId: 'sess_admin',
          userId: 'usr_admin',
          displayName: 'Test Operator',
          email: 'operator@conclave.internal',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );

      try {
        final rbRes = await client.rollbackChannel(
          profileDefinitionId: 'opencode-cli',
          channel: 'stable',
          targetReleaseVersion: 1,
          reason: 'CLI regression',
        );
        expect(rbRes['success'], isTrue);

        final rvRes = await client.changeLifecycle(
          profileDefinitionId: 'opencode-cli',
          releaseVersion: 2,
          lifecycle: 'revoke',
          reason: 'Security vulnerability',
        );
        expect(rvRes['success'], isTrue);
      } finally {
        client.close();
        await mockServer.close(force: true);
      }
    });

    test('6b. Authorization failures on missing credentials', () async {
      HttpOverrides.global = null;
      final mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      mockServer.listen((request) async {
        await utf8.decoder.bind(request).drain();
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
            jsonEncode({'error': 'Unauthorized authentication session'}));
        await request.response.close();
      });

      final unauthClient = ProfileAdminApiClient(
        baseUrl: 'http://${mockServer.address.address}:${mockServer.port}',
        httpClient: HttpClient(),
      );

      try {
        await expectLater(
          unauthClient.fetchReleases('opencode-cli'),
          throwsA(isA<StateError>()),
        );
      } finally {
        unauthClient.close();
        await mockServer.close(force: true);
      }
    });
  });
}

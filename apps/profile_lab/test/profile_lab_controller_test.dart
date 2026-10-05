import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These tests use local HttpServer fixtures; keep Dart's real HTTP client.
  HttpOverrides.global = null;

  group('ProfileLabController', () {
    late Directory temp;
    late ProfileLabPaths paths;
    late ProfileLabController controller;
    final sessionValues = <String, String>{};
    const sessionChannel = MethodChannel('profile-lab-controller-session-test');

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lab_ctrl_test_');
      paths = ProfileLabPaths(homeDirectory: temp.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionChannel, (call) async {
        final account = (call.arguments as Map)['account'] as String;
        if (call.method == 'read') {
          return sessionValues[account];
        }
        if (call.method == 'write') {
          sessionValues[account] = (call.arguments as Map)['value'] as String;
        }
        if (call.method == 'delete') {
          sessionValues.remove(account);
        }
        return null;
      });
      controller = ProfileLabController(
        paths: paths,
        sessionStore: ProfileLabSessionStore.forTesting(
          paths,
          channel: sessionChannel,
        ),
      );
      await controller.initialize();
    });

    tearDown(() async {
      sessionValues.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionChannel, null);
      await temp.delete(recursive: true);
    });

    for (final entry in [
      ('chatgpt', 'chatgpt-codex', 'codex'),
      ('gemini', 'gemini-antigravity', 'agy'),
    ]) {
      test(
          '${entry.$1} initial draft clones Cloud template locally and preserves it on retry',
          () async {
        final payload = jsonDecode(await File(
                '../../packages/tool-profile/test/fixtures/${entry.$2}.v1.json')
            .readAsString()) as Map<String, dynamic>;
        controller.selectedCloudWorker = {
          'workerTypeId': entry.$1,
          'profileDefinitionId': entry.$2
        };
        controller.selectedDefinitionId = entry.$2;
        controller.selectedCloudDefinition = {
          'providerToolName': entry.$3,
          'starterTemplate': {'schemaVersion': 1, 'profile': payload}
        };
        await controller.createInitialDraft();
        expect(controller.currentDraft!.profile, payload);
        expect(controller.currentDraft!.isSigned, isFalse);
        expect(controller.currentEvidence, isEmpty);
        final digest = controller.currentDraft!.payloadDigest;
        await controller.createInitialDraft();
        expect(controller.currentDraft!.payloadDigest, digest);
        expect(controller.workerSubView, WorkerSubView.draftAndTest);
      });
    }

    test('initial creation does not replace an existing Cloud release',
        () async {
      controller.selectedCloudWorker = {'workerTypeId': 'future-worker'};
      controller.selectedDefinitionId = 'future-profile';
      controller.selectedCloudDefinition = {'providerToolName': 'future-cli'};
      controller.cloudReleases = [
        {'releaseVersion': 1}
      ];
      await controller.createInitialDraft();
      expect(await controller.store.loadDraft('future-profile'), isNull);
    });

    test(
        'future Worker without template creates blank Profile with known identity',
        () async {
      controller.selectedCloudWorker = {
        'workerTypeId': 'future-worker',
        'profileDefinitionId': 'future-profile'
      };
      controller.selectedDefinitionId = 'future-profile';
      controller.selectedCloudDefinition = {
        'providerToolName': 'future-cli',
        'starterTemplate': null
      };
      await controller.createInitialDraft();
      expect(controller.currentDraft!.profileDefinitionId, 'future-profile');
      expect(controller.currentDraft!.profile['logicalWorkerTypeId'],
          'future-worker');
      expect((controller.currentDraft!.profile['providerTool'] as Map)['name'],
          'future-cli');
    });

    test('mismatched starter identity is rejected without saving a draft',
        () async {
      controller.selectedCloudWorker = {'workerTypeId': 'future-worker'};
      controller.selectedDefinitionId = 'future-profile';
      controller.selectedCloudDefinition = {
        'providerToolName': 'future-cli',
        'starterTemplate': {
          'schemaVersion': 1,
          'profile': {'profileDefinitionId': 'other'}
        }
      };
      await expectLater(controller.createInitialDraft(), throwsStateError);
      expect(await controller.store.loadDraft('future-profile'), isNull);
    });

    test('saving a changed Draft clears previous run and qualification display',
        () async {
      await controller.createNewDraft(
          profileDefinitionId: 'bound-test',
          workerTypeId: 'bound-worker',
          providerToolName: 'missing-fixture-tool');
      controller.testedDraftDigest = controller.currentDraft!.payloadDigest;
      controller.testedProfileDefinitionId =
          controller.currentDraft!.profileDefinitionId;
      controller.lastTestResult = 'pass';
      controller.testStatusMessage = '11/11 passed';
      final changed =
          Map<String, Object?>.from(controller.currentDraft!.profile);
      changed['releaseVersion'] = 2;
      controller.updateJsonText(jsonEncode(changed));
      await controller.saveCurrentDraft();
      expect(controller.lastTestResult, isNull);
      expect(controller.activeLadderStages, isEmpty);
      expect(controller.testedDraftDigest, isNull);
      expect(controller.testStatusMessage, isNull);
    });

    test(
        'controller streams real stages before completion and drops late events after Draft switch',
        () async {
      await controller.createNewDraft(
          profileDefinitionId: 'bound-test',
          workerTypeId: 'bound-worker',
          providerToolName: 'missing-fixture-tool');
      final observed = <int>[];
      controller.addListener(() {
        if (controller.isTesting && controller.activeLadderStages.isNotEmpty) {
          observed.add(controller.activeLadderStages.length);
          if (controller.activeLadderStages.length == 1) {
            controller.currentDraft = null;
            controller.resetDraftTestState();
          }
        }
      });
      controller.engineExecutable = File('${temp.path}/unused-engine');
      await controller.runTestLadder();
      expect(observed, [1]);
      expect(controller.lastTestResult, isNull);
      expect(controller.activeLadderStages, isEmpty);
      expect(controller.testLogs, isEmpty);
      expect(controller.isTesting, isFalse);
    });

    test('creates new draft, validates JSON, and updates state', () async {
      expect(controller.draftDefinitionIds, isEmpty);

      await controller.createNewDraft(
        profileDefinitionId: 'test-codex',
        workerTypeId: 'chatgpt',
        providerToolName: 'codex',
      );

      expect(controller.draftDefinitionIds, contains('test-codex'));
      expect(controller.selectedDefinitionId, 'test-codex');
      expect(controller.currentDraft, isNotNull);
      expect(controller.currentDraft!.profileDefinitionId, 'test-codex');
      expect(controller.jsonValidationError, isNull);
      expect(
        (controller.currentDraft!.profile['providerTool']
            as Map)['supportedVersions'],
        isEmpty,
      );
      await controller.applyRecommendedProviderCompatibilityRange(
        min: '0.187.2',
        maxExclusive: '0.188.0',
      );
      expect(controller.isDirty, isFalse);
      expect(
        ((controller.currentDraft!.profile['providerTool']
                as Map)['supportedVersions'] as List)
            .single,
        {'min': '0.187.2', 'maxExclusive': '0.188.0'},
      );

      // Editing JSON with invalid syntax
      controller.updateJsonText('{ invalid json');
      expect(controller.isDirty, isTrue);
      expect(controller.jsonValidationError, isNotNull);

      // Editing JSON with valid syntax and saving
      controller.updateJsonText(controller.currentJsonText
          .replaceFirst('{ invalid json', '{\n  "schemaVersion": 1'));
      // Reload current clean draft
      await controller.selectDraft('test-codex');
      expect(controller.jsonValidationError, isNull);
      expect(controller.isDirty, isFalse);
    });

    test('discovers only executable names declared by Worker and Profile data',
        () async {
      await controller.createNewDraft(
        profileDefinitionId: 'dynamic-provider-profile',
        workerTypeId: 'dynamic-worker',
        providerToolName: 'example-runtime',
      );
      final editedProfile =
          jsonDecode(controller.currentJsonText) as Map<String, dynamic>;
      final providerTool =
          editedProfile['providerTool'] as Map<String, dynamic>;
      providerTool['name'] = 'profile-tool';
      providerTool['executableCandidates'] = ['profile-candidate'];
      controller.updateJsonText(jsonEncode(editedProfile));
      controller.cloudWorkers = [
        {'providerToolName': 'catalog-runtime'},
      ];

      await controller.discoverInstalledProviders();

      expect(
        controller.configuredProviderExecutables,
        [
          'catalog-runtime',
          'example-runtime',
          'profile-candidate',
          'profile-tool',
        ],
      );
    });

    test('switches primary areas cleanly', () {
      expect(controller.selectedArea, LabArea.workers);

      controller.setArea(LabArea.workers);
      expect(controller.selectedArea, LabArea.workers);

      controller.setArea(LabArea.workspaces);
      expect(controller.selectedArea, LabArea.workspaces);

      controller.setArea(LabArea.audit);
      expect(controller.selectedArea, LabArea.audit);

      controller.setArea(LabArea.audit);
      expect(controller.selectedArea, LabArea.audit);
    });

    test('deletes draft and clears selection', () async {
      await controller.createNewDraft(
        profileDefinitionId: 'draft-to-delete',
        workerTypeId: 'worker',
        providerToolName: 'tool',
      );
      expect(controller.draftDefinitionIds, contains('draft-to-delete'));

      await controller.deleteCurrentDraft();
      expect(controller.draftDefinitionIds, isEmpty);
      expect(controller.selectedDefinitionId, isNull);
    });

    test('loads saved session from Keychain', () async {
      expect(controller.currentSession, isNull);

      final session = ProfileLabSession(
        credential: 'conclave_dhs_saved_cred',
        sessionId: 'session-saved-1',
        userId: 'admin-1',
        displayName: 'Test Admin',
        email: 'test@conclave.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
      );
      await ProfileLabSessionStore.forTesting(paths, channel: sessionChannel)
          .save(session, cloudOrigin: controller.cloudUrl);

      await controller.loadSavedSession();
      expect(controller.currentSession, isNotNull);
      expect(controller.currentSession!.credential, 'conclave_dhs_saved_cred');
      expect(controller.currentSession!.displayName, 'Test Admin');

      // Sign out clears Keychain session.
      await controller.signOut();
      expect(controller.currentSession, isNull);
      expect(await paths.sessionFile.exists(), isFalse);
    });

    test('persists Cloud origin settings and clears sign-in on origin change',
        () async {
      controller.currentSession = ProfileLabSession(
        credential: 'origin-bound-credential',
        sessionId: 'origin-bound-session',
        userId: 'admin-1',
        displayName: 'Test Admin',
        email: 'test@conclave.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
      sessionValues['profile-lab-human-session'] = 'saved-session';

      await controller.setCloudUrl('http://localhost:8787');

      expect(controller.cloudUrl, 'http://localhost:8787');
      expect(controller.currentSession, isNull);
      expect(sessionValues, isEmpty);
      expect(await paths.cloudSettingsFile.exists(), isTrue);

      await controller.loadCloudConfiguration();
      expect(controller.cloudUrl, 'http://localhost:8787');

      await controller.resetCloudUrl();
      expect(controller.cloudUrl, 'https://app.conclaveax.com');
      expect(await paths.cloudSettingsFile.exists(), isFalse);
    });

    test('reverts unsaved edits and duplicates draft as next release version',
        () async {
      await controller.createNewDraft(
        profileDefinitionId: 'draft-editor-test',
        workerTypeId: 'chatgpt',
        providerToolName: 'codex',
      );

      // Make dirty edit
      controller.updateJsonText(
          '{"schemaVersion": 1, "profileDefinitionId": "draft-editor-test", "releaseVersion": 1}');
      expect(controller.isDirty, isTrue);

      // Revert
      await controller.revertCurrentDraft();
      expect(controller.isDirty, isFalse);

      // Duplicate as next release
      await controller.duplicateCurrentDraftAsNextRelease();
      expect(controller.currentDraft!.releaseVersion, 2);
    });

    test(
        'creates next draft version automatically from a published release payload',
        () async {
      final releasePayload = <String, Object?>{
        'schemaVersion': 1,
        'profileDefinitionId': 'published-worker-profile',
        'releaseVersion': 3,
        'logicalWorkerTypeId': 'worker',
        'engineFamily': 'cli',
        'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
        'providerTool': {
          'name': 'tool',
          'executableCandidates': ['tool'],
          'discovery': {'standardLocations': [], 'allowPathSearch': true},
          'versionProbe': {
            'arguments': ['--version'],
            'timeoutMs': 10000,
            'source': 'stdout',
            'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
          },
          'supportedVersions': [
            {'min': '1.2.3', 'maxExclusive': '1.3.0'}
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
          'mappings': {
            'restricted': [],
            'provider_default': [],
            'full_access': []
          }
        },
        'progress': [],
        'errors': {
          'mappings': [
            {
              'evidence': {'kind': 'exit_code', 'value': 2},
              'issueCode': 'provider_failure'
            }
          ]
        },
        'capabilities': ['code_generation'],
        'compatibilityOverrides': [],
      };

      await controller.createDraftFromRelease(
        profileDefinitionId: 'published-worker-profile',
        releasePayload: releasePayload,
      );

      expect(controller.selectedDefinitionId, 'published-worker-profile');
      expect(controller.currentDraft, isNotNull);
      expect(controller.currentDraft!.releaseVersion, 4);
      expect(controller.selectedArea, LabArea.workers);
    });

    test(
        'tracks draft sync state and handles Cloud optimistic concurrency save & conflict resolution',
        () async {
      final fakeApi = FakeProfileAdminApiClient();
      controller.setApiClientForTesting(fakeApi);

      await controller.createNewDraft(
        profileDefinitionId: 'sync-test-worker',
        workerTypeId: 'chatgpt',
        providerToolName: 'codex',
      );

      expect(controller.syncState, DraftSyncState.saved);

      // Make local edit
      controller.updateJsonText(controller.currentJsonText.replaceFirst(
          '"capabilities": [\n    "text"\n  ]',
          '"capabilities": [\n    "text",\n    "code_generation"\n  ]'));
      expect(controller.isDirty, isTrue);
      expect(controller.syncState, DraftSyncState.modifiedLocally);

      // Save to Cloud with optimistic concurrency
      await controller.saveCurrentDraftToCloud();
      expect(controller.isDirty, isFalse);
      expect(controller.syncState, DraftSyncState.saved);
      expect(controller.baseCloudDigest, 'updated-cloud-digest-1');
      expect(fakeApi.updateCallCount, 1);

      // Simulate conflict on next save
      final conflictApi = FakeProfileAdminApiClient(simulateConflict: true);
      controller.setApiClientForTesting(conflictApi);
      controller.baseCloudDigest = 'old-digest';
      controller.updateJsonText(controller.currentJsonText.replaceFirst(
          '"capabilities": [\n    "text",\n    "code_generation"\n  ]',
          '"capabilities": [\n    "text"\n  ]'));
      expect(controller.syncState, DraftSyncState.conflict);

      expect(controller.saveCurrentDraftToCloud(), throwsA(isA<StateError>()));
      expect(controller.syncState, DraftSyncState.conflict);

      // Resolve conflict by discarding local edits and loading cloud draft payload
      controller.cloudDraftPayload = {
        'schemaVersion': 1,
        'profileDefinitionId': 'sync-test-worker',
        'releaseVersion': 1,
        'logicalWorkerTypeId': 'chatgpt',
        'engineFamily': 'cli',
        'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
        'providerTool': {
          'name': 'codex',
          'executableCandidates': ['codex'],
          'discovery': {'standardLocations': [], 'allowPathSearch': true},
          'versionProbe': {
            'arguments': ['--version'],
            'timeoutMs': 10000,
            'source': 'stdout',
            'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
          },
          'supportedVersions': [
            {'min': '1.2.3', 'maxExclusive': '1.3.0'}
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
          'mappings': {
            'restricted': [],
            'provider_default': [],
            'full_access': []
          }
        },
        'progress': [],
        'errors': {
          'mappings': [
            {
              'evidence': {'kind': 'exit_code', 'value': 2},
              'issueCode': 'provider_failure'
            }
          ]
        },
        'capabilities': ['text', 'code_generation'],
        'compatibilityOverrides': []
      };
      controller.cloudDigest = 'remote-ai-digest';

      await controller.resolveConflictKeepCloud();
      expect(controller.syncState, DraftSyncState.saved);
      expect(controller.isDirty, isFalse);
      expect(controller.currentJsonText, contains('"code_generation"'));
    });

    test('creates an absent Cloud v1 draft with POST before updating it',
        () async {
      final fakeApi = FakeProfileAdminApiClient();
      fakeApi.missingCloudReleaseVersions.add(1);
      controller.setApiClientForTesting(fakeApi);

      await controller.createNewDraft(
        profileDefinitionId: 'new-cloud-worker',
        workerTypeId: 'new-worker',
        providerToolName: 'new-cli',
      );
      await controller.saveCurrentDraftToCloud();

      expect(fakeApi.createDraftCallCount, 1);
      expect(fakeApi.updateCallCount, 0);
      expect(controller.cloudDraftExists, isTrue);
      expect(controller.baseCloudDigest, 'created-cloud-digest-1');

      final edited =
          jsonDecode(controller.currentJsonText) as Map<String, dynamic>;
      (edited['timeout'] as Map<String, dynamic>)['providerReserveMs'] = 1;
      controller
          .updateJsonText(const JsonEncoder.withIndent('  ').convert(edited));
      await controller.saveCurrentDraftToCloud();
      expect(fakeApi.createDraftCallCount, 1);
      expect(fakeApi.updateCallCount, 1);
    });

    test('creates Cloud v2 when starting from a published stable v1', () async {
      final fakeApi = FakeProfileAdminApiClient();
      fakeApi.missingCloudReleaseVersions.add(2);
      controller.setApiClientForTesting(fakeApi);

      await controller.createNewDraft(
        profileDefinitionId: 'stable-worker-profile',
        workerTypeId: 'stable-worker',
        providerToolName: 'stable-cli',
      );
      final stableV1 =
          jsonDecode(controller.currentJsonText) as Map<String, dynamic>;
      await controller.createDraftFromRelease(
        profileDefinitionId: 'stable-worker-profile',
        releasePayload: stableV1,
      );

      expect(controller.currentDraft!.releaseVersion, 2);
      expect(controller.cloudDraftExists, isFalse);
      await controller.saveCurrentDraftToCloud();
      expect(fakeApi.createDraftCallCount, 1);
      expect(fakeApi.updateCallCount, 0);
    });

    test('executes channel pointer rollback to prior known-good release',
        () async {
      final fakeApi = FakeProfileAdminApiClient();
      controller.setApiClientForTesting(fakeApi);
      controller.selectedDefinitionId = 'rollback-test-worker';

      await controller.rollbackChannelPointer(
        channel: 'stable',
        targetReleaseVersion: 18,
        reason: 'Rollback stable from v19 to v18 due to CLI argument issue',
      );

      expect(fakeApi.rollbackCallCount, 1);
      expect(fakeApi.lastRollbackChannel, 'stable');
      expect(fakeApi.lastRollbackTargetVersion, 18);
      expect(controller.selectedCloudDefinition?['channels']['stable'], 18);
    });

    test('executes permanent release revocation with mandatory reason',
        () async {
      final fakeApi = FakeProfileAdminApiClient();
      controller.setApiClientForTesting(fakeApi);
      controller.selectedDefinitionId = 'revoke-test-worker';

      await controller.revokeCloudRelease(
        releaseVersion: 19,
        reason: 'Critical security vulnerability in execution arguments',
      );

      expect(fakeApi.revokeCallCount, 1);
      expect(fakeApi.lastRevokedVersion, 19);
      expect(fakeApi.lastRevokedReason,
          'Critical security vulnerability in execution arguments');
      expect(controller.cloudReleases.first['lifecycleState'], 'revoked');
    });
  });
}

class FakeProfileAdminApiClient extends ProfileAdminApiClient {
  FakeProfileAdminApiClient({bool simulateConflict = false})
      : _simulateConflict = simulateConflict,
        super(baseUrl: 'http://localhost:8787');

  final bool _simulateConflict;
  int updateCallCount = 0;
  int createDraftCallCount = 0;
  String? lastExpectedBaseDigest;
  final Set<int> missingCloudReleaseVersions = {};

  int rollbackCallCount = 0;
  String? lastRollbackChannel;
  int? lastRollbackTargetVersion;

  int revokeCallCount = 0;
  int? lastRevokedVersion;
  String? lastRevokedReason;

  @override
  Future<ProfileLabDefinitionReadModel> fetchDefinition(String id) async =>
      ProfileLabDefinitionReadModel.fromJson({
        'profileDefinitionId': id,
        'displayName': id,
        'channels': {'stable': lastRollbackTargetVersion}
      });

  @override
  Future<Map<String, dynamic>> rollbackChannel({
    required String profileDefinitionId,
    required String channel,
    required int targetReleaseVersion,
    String? reason,
  }) async {
    rollbackCallCount++;
    lastRollbackChannel = channel;
    lastRollbackTargetVersion = targetReleaseVersion;
    return {
      'status': 'rolled_back',
      'channel': channel,
      'targetReleaseVersion': targetReleaseVersion
    };
  }

  @override
  Future<Map<String, dynamic>> changeLifecycle({
    required String profileDefinitionId,
    required int releaseVersion,
    required String lifecycle,
    required String reason,
  }) async {
    if (lifecycle == 'revoked') {
      revokeCallCount++;
      lastRevokedVersion = releaseVersion;
      lastRevokedReason = reason;
    }
    return {'lifecycleState': lifecycle};
  }

  @override
  Future<List<ProfileLabReleaseReadModel>> fetchReleases(
      String profileDefinitionId) async {
    return [
      ProfileLabReleaseReadModel.fromJson({
        'releaseVersion': 19,
        'lifecycleState': revokeCallCount > 0 ? 'revoked' : 'stable',
        'lifecycleReason': lastRevokedReason
      }),
      ProfileLabReleaseReadModel.fromJson(
          {'releaseVersion': 18, 'lifecycleState': 'published'}),
    ];
  }

  @override
  Future<List<ProfileLabAuditEventReadModel>> fetchAudit(
      [String? profileDefinitionId]) async {
    return [];
  }

  @override
  Future<Map<String, dynamic>> updateDraft({
    required String profileDefinitionId,
    required int releaseVersion,
    required Map<String, dynamic> profile,
    String? expectedBaseDigest,
  }) async {
    updateCallCount++;
    lastExpectedBaseDigest = expectedBaseDigest;
    if (_simulateConflict && expectedBaseDigest != null) {
      throw StateError(
          'Request failed (409): Draft conflict detected. Expected base digest mismatch.');
    }
    return {
      'status': 'success',
      'digest': 'updated-cloud-digest-$updateCallCount',
    };
  }

  @override
  Future<Map<String, dynamic>> createDraftRelease({
    required String profileDefinitionId,
    required int releaseVersion,
    required Map<String, dynamic> profile,
  }) async {
    createDraftCallCount++;
    return {
      'status': 'draft',
      'payloadDigest': 'created-cloud-digest-$createDraftCallCount',
    };
  }

  @override
  Future<ProfileLabReleaseReadModel> fetchRelease(
      String profileDefinitionId, int releaseVersion) async {
    if (missingCloudReleaseVersions.contains(releaseVersion)) {
      throw ProfileAdminNotFoundException('Tool Profile release was not found');
    }
    return ProfileLabReleaseReadModel.fromJson({
      'profileDefinitionId': profileDefinitionId,
      'releaseVersion': releaseVersion,
      'lifecycleState': 'draft',
      'profile': {
        'schemaVersion': 1,
        'profileDefinitionId': profileDefinitionId
      },
      'payloadDigest': 'server-digest-1',
    });
  }
}

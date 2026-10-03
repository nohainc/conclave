import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileLabController', () {
    late Directory temp;
    late ProfileLabPaths paths;
    late ProfileLabController controller;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lab_ctrl_test_');
      paths = ProfileLabPaths(homeDirectory: temp.path);
      controller = ProfileLabController(paths: paths);
      await controller.initialize();
    });

    tearDown(() async {
      await temp.delete(recursive: true);
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

    test('switches tabs cleanly', () {
      expect(controller.selectedTab, LabTab.workers);

      controller.setTab(LabTab.profiles);
      expect(controller.selectedTab, LabTab.profiles);

      controller.setTab(LabTab.tests);
      expect(controller.selectedTab, LabTab.tests);

      controller.setTab(LabTab.releases);
      expect(controller.selectedTab, LabTab.releases);

      controller.setTab(LabTab.audit);
      expect(controller.selectedTab, LabTab.audit);
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

    test('loads saved session from dedicated credentials directory', () async {
      expect(controller.currentSession, isNull);

      final session = ProfileLabSession(
        credential: 'conclave_dhs_saved_cred',
        sessionId: 'session-saved-1',
        userId: 'admin-1',
        displayName: 'Test Admin',
        email: 'test@conclave.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
      );
      await session.saveToFile(paths.sessionFile);

      await controller.loadSavedSession();
      expect(controller.currentSession, isNotNull);
      expect(controller.currentSession!.credential, 'conclave_dhs_saved_cred');
      expect(controller.currentSession!.displayName, 'Test Admin');

      // Sign out clears local file and session
      await controller.signOut();
      expect(controller.currentSession, isNull);
      expect(await paths.sessionFile.exists(), isFalse);
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
      expect(controller.selectedTab, LabTab.profiles);
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
  String? lastExpectedBaseDigest;

  int rollbackCallCount = 0;
  String? lastRollbackChannel;
  int? lastRollbackTargetVersion;

  int revokeCallCount = 0;
  int? lastRevokedVersion;
  String? lastRevokedReason;

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
  Future<List<Map<String, dynamic>>> fetchReleases(
      String profileDefinitionId) async {
    return [
      {
        'releaseVersion': 19,
        'lifecycleState': revokeCallCount > 0 ? 'revoked' : 'stable',
        'lifecycleReason': lastRevokedReason
      },
      {'releaseVersion': 18, 'lifecycleState': 'published'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchAudit(
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
  Future<Map<String, dynamic>> fetchRelease(
      String profileDefinitionId, int releaseVersion) async {
    return {
      'profileDefinitionId': profileDefinitionId,
      'releaseVersion': releaseVersion,
      'profile': {
        'schemaVersion': 1,
        'profileDefinitionId': profileDefinitionId
      },
      'payloadDigest': 'server-digest-1',
    };
  }
}

import 'dart:io';

import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileLabTestSandbox', () {
    late Directory temp;
    late Directory sandboxRoot;
    late File dummyEngine;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('sandbox_test_');
      sandboxRoot = Directory('${temp.path}/sandbox')
        ..createSync(recursive: true);
      dummyEngine = File('${temp.path}/mock_engine.sh')
        ..writeAsStringSync('#!/bin/sh\nexit 0');
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test(
        'validates candidate profile strictly and rejects invalid schema in ladder',
        () async {
      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: sandboxRoot,
        engineExecutable: dummyEngine,
      );

      final invalidCandidate = LocalDraftProfileCandidate(
        profileDefinitionId: 'invalid-profile',
        logicalWorkerTypeId: 'worker',
        providerToolName: 'tool',
        releaseVersion: 1,
        payloadDigest: 'abc123digest',
        profile: {
          'schemaVersion': 1,
          'profileDefinitionId': 'invalid-profile',
        },
      );

      final ladderResult =
          await sandbox.executeTestLadder(candidate: invalidCandidate);
      expect(ladderResult.overallResult, 'fail');
      expect(ladderResult.stages.first.stageId, 'schema');
      expect(ladderResult.stages.first.status, 'failed');
      expect(ladderResult.stages.skip(1).every((s) => s.status == 'skipped'),
          isTrue);
    });

    test('executes 9-stage test ladder and produces detailed stage diagnostics',
        () async {
      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: sandboxRoot,
        engineExecutable: dummyEngine,
      );

      final validProfile = <String, Object?>{
        'schemaVersion': 1,
        'profileDefinitionId': 'sandbox-test-worker',
        'releaseVersion': 1,
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

      final validCandidate =
          LocalDraftProfileCandidate.fromProfileMap(validProfile);

      final stageUpdates = <String>[];
      final ladderResult = await sandbox.executeTestLadder(
        candidate: validCandidate,
        onStageUpdate: (stageId, status, diag) =>
            stageUpdates.add('$stageId:$status'),
      );

      expect(ladderResult.stages.length, 9);
      expect(ladderResult.stages[0].stageId, 'schema');
      expect(ladderResult.stages[0].status, 'passed');
      expect(ladderResult.stages[0].consumesQuota, isFalse);

      expect(ladderResult.stages[1].stageId, 'engine_compatibility');
      expect(ladderResult.stages[1].status, 'passed');

      expect(ladderResult.stages[7].stageId, 'session_test');
      expect(ladderResult.stages[7].status,
          'skipped'); // because session.supported = false
      expect(ladderResult.stages[7].diagnostics, contains('not supported'));

      expect(ladderResult.stages[8].stageId, 'model_selection_test');
      expect(ladderResult.stages[8].status,
          'skipped'); // because model.supported = false

      expect(stageUpdates, isNotEmpty);

      // Verify transient directories inside sandboxRoot are cleaned up
      final subEntries = sandboxRoot.listSync();
      expect(subEntries, isEmpty);
    });
  });
}

import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart'
    show cliWorkerEngineVersion;
import 'package:conclave_profile_lab/bundled_cli_worker_engine_loader.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/worker_profile_fixture.dart';

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

    test('rejects a symbolic link as the sandbox root', () async {
      final linkedRoot = Link('${temp.path}/sandbox-link');
      await linkedRoot.create(sandboxRoot.path);
      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: Directory(linkedRoot.path),
        engineExecutable: dummyEngine,
      );
      final candidate = LocalDraftProfileCandidate(
        profileDefinitionId: 'sandbox-link-test',
        logicalWorkerTypeId: 'worker',
        providerToolName: 'tool',
        releaseVersion: 1,
        payloadDigest: 'digest',
        profile: {'schemaVersion': 1},
      );

      await expectLater(
        sandbox.executeTestLadder(candidate: candidate),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('derives evidence scenarios from the Profile', () {
      final statuses = cloudAcceptanceScenarioStatuses({
        'session': {'supported': false},
      });
      expect(statuses.keys.toSet(), cloudAcceptanceScenarioNames.toSet());
      expect(statuses['passive_probe'], 'passed');
      // Every Profile must declare a usage command.
      expect(statuses['usage_check'], 'passed');
    });

    test(
        'runs the full acceptance ladder from a persisted Draft through the bundled Engine and fixture provider',
        () async {
      final providerBin = Directory('${temp.path}/provider-bin')
        ..createSync(recursive: true);
      final provider = File('${providerBin.path}/tool')
        ..writeAsStringSync(r'''#!/bin/sh
if [ "$1" = "info" ] && [ "$2" = "--version" ]; then
  echo "tool version v1.2.3" >&2
  exit 0
fi
if [ "$1" = "--version" ]; then
  echo "tool 1.2.3"
  exit 0
fi
case "$*" in
  *cancellation*|*timeout*) sleep 30 ;;
esac
case "$*" in
  *acceptance-write.txt*) printf 'conclave-profile-lab-write-verified\n' > acceptance-write.txt ;;
esac
printf '{"sessionId":"fixture-session","text":"OK"}\n'
''');
      await Process.run('chmod', ['700', provider.path]);
      final path = '${providerBin.path}${Platform.isWindows ? ';' : ':'}'
          '${Platform.environment['PATH'] ?? ''}';
      final engine = await loadBundledCliWorkerEngine(
        enginesDirectory: Directory('${temp.path}/engine-cache'),
      );
      expect(engine, isNotNull, reason: 'The real bundled Engine is required.');
      // The bundled Engine binary must be materialized and executable.
      expect(engine!.existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(engine.statSync().mode & 0x49, isNonZero);
      }
      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: sandboxRoot,
        engineExecutable: engine,
        environmentOverrides: {'PATH': path},
      );

      final validProfile = buildTestWorkerProfile(
        profileDefinitionId: 'sandbox-test-worker',
        logicalWorkerTypeId: 'worker',
        providerTool: {
          'name': 'tool',
          'executableCandidates': ['tool'],
          'discovery': {'standardLocations': [], 'allowPathSearch': true},
          'versionProbe': {
            'arguments': ['info', '--version'],
            'timeoutMs': 10000,
            'source': 'stderr',
            'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
          },
          'supportedVersions': [
            {'min': '1.2.3', 'maxExclusive': '1.3.0'}
          ],
        },
        probe: {
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
          },
          'live': {
            'timeoutMs': 10000,
            'expectedFinalText': {'kind': 'exact', 'value': 'OK'},
          },
        },
        execution: {
          'arguments': ['run', '{{prompt}}'],
          'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
          'output': {'mode': 'single_json'},
          'events': [
            {
              'when': [],
              'actions': [
                {'type': 'set_final_text', 'selector': r'$.text'},
                {'type': 'mark_success'},
              ],
            },
          ]
        },
        session: {
          'supported': true,
          'formatId': 'session-v1',
          'compatibleFormatIds': ['session-v1'],
          'extract': r'$.sessionId',
          'resumeArguments': [],
          'requireObservedIdMatch': false
        },
        model: {
          'supported': true,
          'arguments': ['--model', '{{model}}'],
          'allowlist': ['fixture-model'],
          'unknownModelPolicy': 'profile_allowlist'
        },
        sandbox: {
          'mappings': {
            'restricted': ['--sandbox', 'workspace-write'],
            'provider_default': [],
            'full_access': []
          }
        },
        errors: {
          'mappings': [
            {
              'evidence': {'kind': 'exit_code', 'value': 2},
              'issueCode': 'provider_failure'
            }
          ]
        },
      );

      final draftStore = DraftProfileStore(
        draftsRoot: Directory('${temp.path}/profile-lab-drafts'),
      );
      final savedDraft = await draftStore.saveDraft(
        profileDefinitionId: 'sandbox-test-worker',
        profileJson: validProfile,
        author: 'macOS acceptance fixture',
      );
      expect(savedDraft.isPublished, isFalse);
      final loadedDraft = await draftStore.loadDraft('sandbox-test-worker');
      expect(loadedDraft, isNotNull);
      final validCandidate = loadedDraft!;

      final stageUpdates = <String>[];
      final streamedStages = <ProfileLabLadderStageResult>[];
      final ladderResult = await sandbox.executeTestLadder(
        candidate: validCandidate,
        onStageResult: streamedStages.add,
        onStageUpdate: (stageId, status, diag) =>
            stageUpdates.add('$stageId:$status'),
      );

      expect(ladderResult.stages.map((stage) => stage.stageId), [
        'schema',
        'activity_mapping',
        'executable_discovery',
        'cli_version',
        'passive_probe',
        'usage_check',
      ]);
      expect(streamedStages, orderedEquals(ladderResult.stages));
      expect(ladderResult.stages[0].status, 'passed');
      expect(ladderResult.stages[0].consumesQuota, isFalse);
      expect(ladderResult.stages[1].status, 'not_applicable');
      expect(
        ladderResult.overallResult,
        'pass',
        reason: ladderResult.stages
            .map((stage) =>
                '${stage.stageId}:${stage.status}:${stage.diagnostics}')
            .join('\n'),
      );
      // The usage command comes from the fixture Profile and is answered by
      // the fixture provider.
      expect(ladderResult.stages[5].status, 'passed');

      expect(stageUpdates, isNotEmpty);

      final evidence = ladderResult.acceptanceEvidence;
      expect(evidence, isNotNull);
      final evidenceJson = evidence!.toJson();
      expect(evidenceJson['formatVersion'], 2);
      expect(
        evidenceJson.keys.toSet(),
        {
          'formatVersion',
          'profileDefinitionId',
          'releaseVersion',
          'profileReleaseVersion',
          'logicalWorkerTypeId',
          'profileDigest',
          'engineVersion',
          'providerToolName',
          'providerToolVersion',
          'acceptedAt',
          'scenarios',
        },
      );
      expect(evidenceJson['providerToolVersion'], '1.2.3');
      expect(evidenceJson['profileDigest'], validCandidate.payloadDigest);
      expect(
        ToolProfileAcceptanceEvidence.hasCloudContractShape(
          evidenceJson,
          profile: validCandidate.profile,
        ),
        isTrue,
      );
      final scenarios = evidenceJson['scenarios'] as Map<String, String>;
      expect(scenarios.keys.toSet(), cloudAcceptanceScenarioNames.toSet());
      expect(
        scenarios,
        cloudAcceptanceScenarioStatuses(validCandidate.profile),
      );

      final publicationEvidence = ladderResult.publicationEvidence;
      expect(publicationEvidence, isNotNull);
      final publicationJson = publicationEvidence!.toJson();
      expect(publicationJson, {
        'formatVersion': 1,
        'workerTypeId': validCandidate.logicalWorkerTypeId,
        'candidateDigest': validCandidate.payloadDigest,
        'engineVersion': cliWorkerEngineVersion,
        'providerToolName': validCandidate.providerToolName,
        'providerToolVersion': '1.2.3',
        'testedAt': publicationJson['testedAt'],
        'scenarios': scenarios,
      });

      // Verify transient directories inside sandboxRoot are cleaned up
      final subEntries = sandboxRoot.listSync();
      expect(subEntries, isEmpty);
    });
  });
}

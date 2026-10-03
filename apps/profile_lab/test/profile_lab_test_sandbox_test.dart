import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/bundled_cli_worker_engine_loader.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:crypto/crypto.dart';
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

    test('runs a trusted model proposal through the generic Engine', () async {
      final providerBin = Directory('${temp.path}/model-provider-bin')
        ..createSync(recursive: true);
      final provider = File('${providerBin.path}/fixture-provider');
      final fixtureFile = File(
        '${Directory.current.parent.parent.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
      );
      final profile = Map<String, Object?>.from(
        jsonDecode(await fixtureFile.readAsString()) as Map,
      );
      profile['profileDefinitionId'] = 'model-runner';
      profile['releaseVersion'] = 3;
      profile['logicalWorkerTypeId'] = 'model-worker';
      profile['execution'] = {
        'arguments': ['run'],
        'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
        'output': {'mode': 'plain_text'},
        'events': <Object?>[],
      };
      final profileDigest =
          sha256.convert(utf8.encode(canonicalJson(profile))).toString();
      final proposal = Map<String, Object?>.from(profile)
        ..['description'] = 'proposed by the fixture model';
      await provider.writeAsString('''#!/bin/sh
cat >/dev/null
cat <<'CONCLAVE_MODEL_OUTPUT'
${jsonEncode(proposal)}
CONCLAVE_MODEL_OUTPUT
''');
      await Process.run('chmod', ['700', provider.path]);
      final engine = await loadBundledCliWorkerEngine(
        enginesDirectory: Directory('${temp.path}/engine-cache'),
      );
      expect(engine, isNotNull);

      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: sandboxRoot,
        engineExecutable: engine!,
        environmentOverrides: {
          'PATH':
              '${providerBin.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
        },
      );
      final admission = ToolProfileReleaseAdmission(
        profile: profile,
        profileDefinitionId: 'model-runner',
        releaseVersion: 3,
        logicalWorkerTypeId: 'model-worker',
        providerToolName: 'Fixture CLI',
        payloadDigest: profileDigest,
        channel: 'stable',
      );

      final output = await sandbox.runTrustedModelProposal(
        modelProfile: admission,
        prompt: 'Propose a safe Draft change.',
      );

      expect(jsonDecode(output), proposal);
      expect(sandboxRoot.listSync(), isEmpty,
          reason: 'The model request sandbox is removed after execution.');
    });

    test('derives optional evidence scenarios from Profile capabilities', () {
      final statuses = cloudAcceptanceScenarioStatuses({
        'capabilities': ['text'],
        'session': {'supported': false},
      });
      expect(statuses?['representative_workstream_write'], 'not_applicable');
      expect(statuses?['durable_session_start'], 'not_applicable');
      expect(statuses?['durable_session_resume'], 'not_applicable');
      expect(statuses?['model_selection'], 'not_applicable');
      expect(statuses?['passive_probe'], 'passed');
      expect(statuses?['cancellation'], 'passed');
      final capableStatuses = cloudAcceptanceScenarioStatuses({
        'capabilities': ['workstream_write', 'durable_session'],
        'session': {'supported': true},
        'model': {
          'supported': true,
          'allowlist': ['fixture-model']
        },
      });
      expect(capableStatuses?['representative_workstream_write'], 'passed');
      expect(capableStatuses?['durable_session_start'], 'passed');
      expect(capableStatuses?['durable_session_resume'], 'passed');
      expect(capableStatuses?['model_selection'], 'passed');
      expect(
        cloudAcceptanceScenarioStatuses({
          'capabilities': ['durable_session'],
          'session': {'supported': false},
        }),
        isNull,
      );
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
  *acceptance-write.txt*) printf 'conclave-profile-lab-write-verified' > acceptance-write.txt ;;
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
      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: sandboxRoot,
        engineExecutable: engine!,
        environmentOverrides: {'PATH': path},
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
            'arguments': ['info', '--version'],
            'timeoutMs': 10000,
            'source': 'stderr',
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
          },
          'live': {
            'timeoutMs': 10000,
            'expectedFinalText': {'kind': 'exact', 'value': 'OK'},
          },
        },
        'execution': {
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
        'session': {
          'supported': true,
          'formatId': 'session-v1',
          'compatibleFormatIds': ['session-v1'],
          'extract': r'$.sessionId',
          'resumeArguments': [],
          'requireObservedIdMatch': false
        },
        'model': {
          'supported': true,
          'arguments': ['--model', '{{model}}'],
          'allowlist': ['fixture-model'],
          'unknownModelPolicy': 'profile_allowlist'
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
        'capabilities': ['workstream_write', 'durable_session'],
        'compatibilityOverrides': [],
      };

      final draftStore = DraftProfileStore(
        draftsRoot: Directory('${temp.path}/profile-lab-drafts'),
      );
      final savedDraft = await draftStore.saveDraft(
        profileDefinitionId: 'sandbox-test-worker',
        profileJson: validProfile,
        author: 'macOS acceptance fixture',
      );
      expect(savedDraft.isSigned, isFalse);
      final loadedDraft = await draftStore.loadDraft('sandbox-test-worker');
      expect(loadedDraft, isNotNull);
      final validCandidate = loadedDraft!;

      final stageUpdates = <String>[];
      final ladderResult = await sandbox.executeTestLadder(
        candidate: validCandidate,
        onStageUpdate: (stageId, status, diag) =>
            stageUpdates.add('$stageId:$status'),
      );

      expect(ladderResult.stages.length, 11);
      expect(ladderResult.stages[0].stageId, 'schema');
      expect(ladderResult.stages[0].status, 'passed');
      expect(ladderResult.stages[0].consumesQuota, isFalse);

      expect(ladderResult.stages[1].stageId, 'engine_compatibility');
      expect(ladderResult.stages[1].status, 'passed');
      expect(
        ladderResult.overallResult,
        'pass',
        reason: ladderResult.stages
            .map((stage) =>
                '${stage.stageId}:${stage.status}:${stage.diagnostics}')
            .join('\n'),
      );
      for (final stageId in [
        'representative_workstream_write',
        'session_test',
        'model_selection_test',
        'cancellation_test',
        'timeout_test',
      ]) {
        expect(
          ladderResult.stages
              .singleWhere((stage) => stage.stageId == stageId)
              .status,
          'passed',
          reason:
              'The real Engine stage $stageId should complete its scenario.',
        );
      }

      expect(ladderResult.stages[7].stageId, 'session_test');
      expect(ladderResult.stages[7].status, 'passed');

      expect(ladderResult.stages[8].stageId, 'model_selection_test');
      expect(ladderResult.stages[8].status, 'passed');

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
      expect(scenarios.values.toSet(), {'passed'});

      // Verify transient directories inside sandboxRoot are cleaned up
      final subEntries = sandboxRoot.listSync();
      expect(subEntries, isEmpty);
    });
  });
}

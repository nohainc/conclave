import 'dart:io';

import 'package:conclave_profile_lab/bundled_cli_worker_engine_loader.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_profile_lab/utils/profile_ai_repair_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProfileLabPaths tempPaths;
  late ProfileLabController controller;
  final runner = ProfileAiRepairLoopRunner();

  setUp(() async {
    final tempDir =
        await Directory.systemTemp.createTemp('profile_lab_repair_test_');
    tempPaths = ProfileLabPaths(homeDirectory: tempDir.path);
    await tempPaths.ensureDirectoriesExist();

    controller = ProfileLabController(
      paths: tempPaths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(tempPaths),
    );
    await controller.createNewDraft(
      profileDefinitionId: 'repair-loop-test',
      workerTypeId: 'claude',
      providerToolName: 'claude',
    );
  });

  group('ProfileAiRepairLoopRunner', () {
    test(
        'normalizes test ladder stage failures cleanly into diagnostic records',
        () {
      const stageResults = [
        ProfileLabLadderStageResult(
          stageId: 'schema_validation',
          displayName: 'Schema Validation',
          status: 'passed',
          durationMs: 2,
          diagnostics: 'Schema valid',
          consumesQuota: false,
        ),
        ProfileLabLadderStageResult(
          stageId: 'passive_probe',
          displayName: 'Passive Probe',
          status: 'failed',
          durationMs: 15,
          diagnostics: 'CLI exited with code 1',
          consumesQuota: false,
          issueCode: 'provider_authentication_required',
        ),
      ];

      final ladderResult = ProfileLabLadderResult(
        overallResult: 'fail',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        stages: stageResults,
        acceptanceEvidence: null,
        logs: [],
      );

      final normalized = runner.normalizeLadderFailures(ladderResult);

      expect(normalized.length, 1);
      expect(normalized.first['stage'], 'passive_probe');
      expect(normalized.first['displayName'], 'Passive Probe');
      expect(normalized.first['issueCode'], 'provider_authentication_required');
      expect(normalized.first['diagnostics'], contains('code 1'));
    });

    test(
        'runs repair iteration step: candidate -> test -> failure normalization -> AI revision -> diff',
        () async {
      final initialPayload =
          Map<String, dynamic>.from(controller.currentDraft!.profile);
      // Introduce broken passive probe to trigger failure normalization
      initialPayload['probe'] = {
        'passive': {
          'checks': [
            {
              'id': 'broken_check',
              'arguments': ['--non-existent-flag-for-failure'],
              'timeoutMs': 1000,
              'successExitCodes': [0],
              'failureIssueCode': 'provider_failure'
            }
          ],
          'configChecks': [],
        }
      };

      controller.engineExecutable ??= await loadBundledCliWorkerEngine(
          enginesDirectory: tempPaths.enginesDirectory);

      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: tempPaths.sandboxDirectory,
        engineExecutable: controller.engineExecutable!,
      );

      final record = await runner.runIteration(
        controller: controller,
        iterationNumber: 1,
        workingPayload: initialPayload,
        sandbox: sandbox,
      );

      expect(record.iterationNumber, 1);
      expect(record.ladderResult, isNotNull);
      expect(record.status, RepairIterationStep.awaitingConfirmation);
      expect(record.normalizedFailures, isNotEmpty);
      expect(record.aiProposedPayload, isNotNull);
      expect(record.diffGroups, isNotEmpty);
    });
  });
}

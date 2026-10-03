import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';
import 'profile_ai_assistant.dart';
import 'profile_domain_diff.dart';

enum RepairIterationStep {
  starting,
  testing,
  failureNormalized,
  aiRevising,
  diffCalculated,
  awaitingConfirmation,
  completed,
  failed,
}

class RepairIterationRecord {
  RepairIterationRecord({
    required this.iterationNumber,
    required this.candidatePayload,
    this.ladderResult,
    this.normalizedFailures = const [],
    this.aiProposedPayload,
    this.diffGroups = const [],
    this.status = RepairIterationStep.starting,
    this.applied = false,
  });

  final int iterationNumber;
  final Map<String, dynamic> candidatePayload;
  ProfileLabLadderResult? ladderResult;
  List<Map<String, dynamic>> normalizedFailures;
  Map<String, dynamic>? aiProposedPayload;
  List<DomainDiffGroup> diffGroups;
  RepairIterationStep status;
  bool applied;
}

class ProfileAiRepairLoopResult {
  const ProfileAiRepairLoopResult({
    required this.success,
    required this.totalIterations,
    required this.maxIterations,
    required this.history,
    required this.finalPayload,
    this.stopReason,
  });

  final bool success;
  final int totalIterations;
  final int maxIterations;
  final List<RepairIterationRecord> history;
  final Map<String, dynamic> finalPayload;
  final String? stopReason;
}

class ProfileAiRepairLoopRunner {
  ProfileAiRepairLoopRunner({
    this.assistantService = const ProfileAiHeuristicRepairService(),
  });

  final ProfileAiHeuristicRepairService assistantService;

  /// Normalizes test ladder failures into safe structured diagnostic records.
  List<Map<String, dynamic>> normalizeLadderFailures(
      ProfileLabLadderResult result) {
    final failures = <Map<String, dynamic>>[];
    for (final stage in result.stages) {
      if (stage.status == 'failed') {
        failures.add({
          'stage': stage.stageId,
          'displayName': stage.displayName,
          'status': 'failed',
          'diagnostics': stage.diagnostics,
          'issueCode': stage.issueCode ?? 'stage_execution_failure',
          'consumesQuota': stage.consumesQuota,
        });
      }
    }
    return failures;
  }

  /// Executes one iterative step of the AI repair loop:
  /// Candidate Payload -> Validate & Local Test -> Normalize Failure -> Ask AI Revision -> Compute Diff.
  Future<RepairIterationRecord> runIteration({
    required ProfileLabController controller,
    required int iterationNumber,
    required Map<String, dynamic> workingPayload,
    required ProfileLabTestSandbox sandbox,
    String? customInstruction,
  }) async {
    final record = RepairIterationRecord(
      iterationNumber: iterationNumber,
      candidatePayload: workingPayload,
      status: RepairIterationStep.testing,
    );

    // 1. Temporary candidate setup for test ladder run
    final candidate = LocalDraftProfileCandidate.fromProfileMap(workingPayload);

    // 2. Execute Progressive Test Ladder
    final ladderResult = await sandbox.executeTestLadder(candidate: candidate);
    record.ladderResult = ladderResult;

    // 3. Check for overall pass
    if (ladderResult.overallResult == 'pass') {
      record.status = RepairIterationStep.completed;
      return record;
    }

    // 4. Normalize Failure
    record.status = RepairIterationStep.failureNormalized;
    record.normalizedFailures = normalizeLadderFailures(ladderResult);

    // 5. Ask AI for Revision
    record.status = RepairIterationStep.aiRevising;
    final context = assistantService.gatherContext(controller);
    // Enrich context diagnostics with normalized failures from this iteration
    final enrichedDiagnostics =
        List<Map<String, dynamic>>.from(context.testDiagnostics)
          ..addAll(record.normalizedFailures);

    final enrichedContext = AiAssistantContext(
      workerMetadata: context.workerMetadata,
      stableProfile: context.stableProfile,
      currentDraft: workingPayload,
      testDiagnostics: enrichedDiagnostics,
      providerCliInfo: context.providerCliInfo,
    );

    final failedNames =
        record.normalizedFailures.map((f) => f['displayName']).join(', ');
    final instruction = customInstruction ??
        'Fix failing ladder stages ($failedNames) and adjust profile definitions cleanly.';

    final proposed = assistantService.proposeCandidateDraft(
      context: enrichedContext,
      userInstruction: instruction,
    );
    record.aiProposedPayload = proposed;

    // 6. Compute Domain Diff
    record.diffGroups =
        ProfileDomainDiffCalculator.computeDiff(workingPayload, proposed);
    record.status = RepairIterationStep.awaitingConfirmation;

    return record;
  }
}

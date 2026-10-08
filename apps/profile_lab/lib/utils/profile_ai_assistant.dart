import 'dart:convert';

import '../controllers/profile_lab_controller.dart';

/// Context gathered from safe non-credential runtime sources for AI draft synthesis.
class AiAssistantContext {
  const AiAssistantContext({
    required this.workerMetadata,
    required this.stableProfile,
    required this.currentDraft,
    required this.testDiagnostics,
    required this.providerCliInfo,
  });

  final Map<String, dynamic> workerMetadata;
  final Map<String, dynamic>? stableProfile;
  final Map<String, dynamic> currentDraft;
  final List<Map<String, dynamic>> testDiagnostics;
  final Map<String, dynamic> providerCliInfo;

  Map<String, dynamic> toJson() => {
        'worker': workerMetadata,
        'stableProfile': stableProfile,
        'currentDraft': currentDraft,
        'testDiagnostics': testDiagnostics,
        'providerCliInfo': providerCliInfo,
      };
}

/// Service that gathers context and synthesizes AI-proposed Tool Profile candidate drafts.
class ProfileAiHeuristicRepairService {
  const ProfileAiHeuristicRepairService();

  /// Gathers safe, non-credential context for AI draft generation.
  AiAssistantContext gatherContext(ProfileLabController controller) {
    // 1. Worker metadata
    final worker = controller.selectedCloudWorker ??
        {
          'workerTypeId': controller.selectedDefinitionId ?? 'unknown-worker',
          'displayName': controller.selectedDefinitionId ?? 'Unknown Worker',
          'capabilities': ['code_generation'],
        };

    // 2. Stable profile
    final stableRelease = controller.cloudReleases.firstWhere(
      (r) => (r['lifecycleState'] as String? ?? '').toLowerCase() == 'stable',
      orElse: () => <String, dynamic>{},
    );
    final stableProfile = stableRelease['profile'] as Map<String, dynamic>?;

    // 3. Current candidate draft
    Map<String, dynamic> currentDraftPayload = {};
    try {
      final decoded = jsonDecode(controller.currentJsonText);
      if (decoded is Map<String, dynamic>) {
        currentDraftPayload = decoded;
      }
    } catch (_) {
      if (controller.currentDraft != null) {
        currentDraftPayload =
            Map<String, dynamic>.from(controller.currentDraft!.profile);
      }
    }

    // 4. Bounded test diagnostics
    final diagnostics = <Map<String, dynamic>>[];
    if (controller.jsonValidationError != null) {
      diagnostics.add({
        'stage': 'schema_validation',
        'passed': false,
        'error': controller.jsonValidationError,
      });
    }
    if (controller.lastLadderResult != null) {
      for (final stage in controller.lastLadderResult!.stages) {
        diagnostics.add({
          'stage': stage.stageId,
          'status': stage.status,
          'diagnostics': stage.diagnostics,
        });
      }
    }

    // 5. Provider CLI info
    final providerInfo = {
      'detectedProviderPaths': controller.detectedProviderPaths,
      'hasEngine': controller.engineExecutable != null,
    };

    return AiAssistantContext(
      workerMetadata: worker,
      stableProfile: stableProfile,
      currentDraft: currentDraftPayload,
      testDiagnostics: diagnostics,
      providerCliInfo: providerInfo,
    );
  }

  /// Synthesizes a proposed updated Tool Profile v1 candidate payload.
  /// Always returns a valid complete candidate map meant to land in Draft.
  Map<String, dynamic> proposeCandidateDraft({
    required AiAssistantContext context,
    required String userInstruction,
  }) {
    final base = Map<String, dynamic>.from(context.currentDraft);
    if (base.isEmpty) {
      final workerType =
          context.workerMetadata['workerTypeId'] as String? ?? 'ai-generated';
      final defId = '$workerType-profile';
      base.addAll({
        'schemaVersion': 1,
        'profileDefinitionId': defId,
        'releaseVersion': 1,
        'logicalWorkerTypeId':
            context.workerMetadata['workerTypeId'] ?? 'ai-worker',
        'engineFamily': 'cli',
        'execution': {
          'argv': ['run'],
          'env': {},
        },
        'passiveProbe': {
          'argv': ['--version'],
          'exitCode': 0,
        },
        'capabilities': ['code_generation'],
      });
    }

    final promptLower = userInstruction.toLowerCase();

    // Stage failure-driven repair adjustments:
    for (final diag in context.testDiagnostics) {
      final stage = diag['stage'] as String? ?? '';
      final status = diag['status'] as String? ?? '';
      final isFailed =
          status == 'failed' || status == 'fail' || diag['passed'] == false;

      if (isFailed) {
        switch (stage) {
          case 'schema_validation':
            base['schemaVersion'] = 1;
            base['engineFamily'] = 'cli';
            base.putIfAbsent('logicalWorkerTypeId',
                () => context.workerMetadata['workerTypeId'] ?? 'ai-worker');
            break;
          case 'engine_compatibility':
            base['engineCompatibility'] = {
              'min': '1.0.0',
              'maxExclusive': '2.0.0'
            };
            break;
          case 'executable_discovery':
            final tool =
                Map<String, dynamic>.from(base['providerTool'] as Map? ?? {});
            final name = tool['name'] as String? ??
                context.workerMetadata['providerToolName'] as String? ??
                'provider';
            tool['executableCandidates'] = [name];
            final disc =
                Map<String, dynamic>.from(tool['discovery'] as Map? ?? {});
            disc['allowPathSearch'] = true;
            tool['discovery'] = disc;
            base['providerTool'] = tool;
            break;
          case 'cli_version':
            final tool =
                Map<String, dynamic>.from(base['providerTool'] as Map? ?? {});
            tool['versionProbe'] = {
              'arguments': ['--version'],
              'timeoutMs': 10000,
              'source': 'stdout',
              'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
            };
            tool['supportedVersions'] = <Map<String, String>>[];
            base['providerTool'] = tool;
            break;
          case 'passive_probe':
            final probe =
                Map<String, dynamic>.from(base['probe'] as Map? ?? {});
            probe['passive'] = {
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
            };
            base['probe'] = probe;
            break;
          case 'live_probe':
          case 'representative_thread_write':
            final exec =
                Map<String, dynamic>.from(base['execution'] as Map? ?? {});
            exec['arguments'] = ['run', '{{prompt}}'];
            base['execution'] = exec;
            break;
          // Session identifiers and resume arguments are provider Profile
          // data. A failed session scenario is diagnostic input, not evidence
          // for synthesizing a session format or command-line arguments.
        }
      }
    }

    // Heuristic assistant adjustments based on prompt / context:
    if (promptLower.contains('probe') || promptLower.contains('version')) {
      final probe = Map<String, dynamic>.from(
          base['passiveProbe'] as Map<String, dynamic>? ?? {});
      probe['argv'] = ['--version'];
      probe['exitCode'] = 0;
      base['passiveProbe'] = probe;
    }

    if (promptLower.contains('arg') ||
        promptLower.contains('flag') ||
        promptLower.contains('execution')) {
      final exec = Map<String, dynamic>.from(
          base['execution'] as Map<String, dynamic>? ?? {});
      final argv = List<String>.from(exec['argv'] as List? ?? ['run']);
      if (promptLower.contains('non-interactive') ||
          promptLower.contains('batch')) {
        if (!argv.contains('--non-interactive') && !argv.contains('-n')) {
          argv.add('--non-interactive');
        }
      }
      exec['argv'] = argv;
      base['execution'] = exec;
    }

    if (promptLower.contains('capability') ||
        promptLower.contains('capabilities')) {
      final caps = List<String>.from(base['capabilities'] as List? ?? []);
      if (!caps.contains('code_generation')) caps.add('code_generation');
      if (!caps.contains('tool_execution')) caps.add('tool_execution');
      base['capabilities'] = caps;
    }

    return base;
  }
}

/// Builds the read-only context shown in the model proposal interface.
/// Candidate generation belongs to ProfileLabModelProposalService.
class ProfileAiAssistantContextBuilder {
  const ProfileAiAssistantContextBuilder();

  AiAssistantContext gatherContext(ProfileLabController controller) =>
      const ProfileAiHeuristicRepairService().gatherContext(controller);
}

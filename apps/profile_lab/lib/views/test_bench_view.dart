import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';
import '../theme/profile_lab_theme.dart';
import 'ai_repair_loop_dialog.dart';
import 'provider_version_matrix_card.dart';

class TestBenchView extends StatelessWidget {
  const TestBenchView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final draft = c.currentDraft;

    if (draft == null) {
      return const Center(
        child: Text(
            'No draft selected. Please select a draft in the Drafts tab first.'),
      );
    }

    final providerTool = draft.profile['providerTool'] as Map<String, Object?>?;
    final toolName = providerTool?['name'] as String? ?? 'unknown';
    final detectedPath = c.detectedProviderPaths[toolName];

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Target information card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              draft.profileDefinitionId,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'v${draft.releaseVersion}',
                              style: const TextStyle(
                                  fontSize: 14, color: Color(0xFF94A3B8)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Provider CLI: $toolName (${detectedPath != null ? "found at $detectedPath" : "NOT found on PATH"})',
                          style: TextStyle(
                            fontSize: 12,
                            color: detectedPath != null
                                ? ProfileLabTheme.passColor
                                : ProfileLabTheme.warnColor,
                          ),
                        ),
                        Text(
                          'Payload Digest: ${draft.payloadDigest}',
                          style: const TextStyle(
                              fontFamily: 'Menlo',
                              fontSize: 11,
                              color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.swap_calls, size: 16),
                        label: const Text('Run Test Ladder'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ProfileLabTheme.primaryAccent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: c.isTesting ? null : () => c.runTestLadder(),
                      ),
                      if (c.isTesting) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.cancel_outlined, size: 14),
                          label: const Text('Cancel Engine Run'),
                          onPressed: c.cancelTest,
                        ),
                      ],
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.build_circle_outlined,
                            size: 14, color: ProfileLabTheme.warnColor),
                        label: const Text('Experimental Repair...',
                            style: TextStyle(
                                fontSize: 11,
                                color: ProfileLabTheme.warnColor)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                              color: ProfileLabTheme.warnColor),
                        ),
                        onPressed: c.isTesting
                            ? null
                            : () => AiRepairLoopDialog.show(context, c),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.speed, size: 14),
                        label: const Text('Passive Probe',
                            style: TextStyle(fontSize: 11)),
                        onPressed:
                            c.isTesting ? null : () => c.runTest(live: false),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.play_arrow, size: 14),
                        label: const Text('Live Probe',
                            style: TextStyle(fontSize: 11)),
                        onPressed:
                            c.isTesting ? null : () => c.runTest(live: true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Provider Version Test Matrix Card
          ProviderVersionMatrixCard(
            profile: draft.profile,
            evidenceList: c.currentEvidence,
          ),
          const SizedBox(height: 16),

          // Status & Result Bar
          if (c.testStatusMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: c.lastTestResult == 'pass'
                    ? ProfileLabTheme.passColor.withValues(alpha: 0.15)
                    : c.lastTestResult == 'fail'
                        ? ProfileLabTheme.failColor.withValues(alpha: 0.15)
                        : ProfileLabTheme.darkSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: c.lastTestResult == 'pass'
                      ? ProfileLabTheme.passColor
                      : c.lastTestResult == 'fail'
                          ? ProfileLabTheme.failColor
                          : const Color(0xFF334155),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    c.isTesting
                        ? Icons.sync
                        : c.lastTestResult == 'pass'
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                    color: c.lastTestResult == 'pass'
                        ? ProfileLabTheme.passColor
                        : c.lastTestResult == 'fail'
                            ? ProfileLabTheme.failColor
                            : Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      c.testStatusMessage!,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),

          // Progressive Test Ladder Stages View
          if (c.activeLadderStages.isNotEmpty) ...[
            Row(
              children: const [
                Text(
                  'PROGRESSIVE LOCAL TEST LADDER (11 STAGES)',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF94A3B8)),
                ),
                Spacer(),
                Text(
                  'Schema → Compat → Discovery → Version → Passive → Live → Exec → Session → Model → Cancel → Timeout',
                  style: TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: ProfileLabTheme.darkSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: c.activeLadderStages.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFF1E293B)),
                itemBuilder: (ctx, idx) {
                  final stage = c.activeLadderStages[idx];
                  return _StageRowTile(stage: stage, index: idx + 1);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Output console
          const Text(
            'EXECUTION OUTPUT & STREAMED EVENTS',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ProfileLabTheme.darkBackground,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: c.testLogs.isEmpty
                  ? const Center(
                      child: Text(
                        'Ready to test. Run Test Ladder to execute the 11 progressive stages.',
                        style:
                            TextStyle(color: Color(0xFF64748B), fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      itemCount: c.testLogs.length,
                      itemBuilder: (ctx, idx) {
                        final log = c.testLogs[idx];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${log.timestamp.toIso8601String().substring(11, 19)} ',
                                style: const TextStyle(
                                    fontFamily: 'Menlo',
                                    fontSize: 11,
                                    color: Color(0xFF64748B)),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: log.level == 'error'
                                      ? ProfileLabTheme.failColor
                                          .withValues(alpha: 0.2)
                                      : ProfileLabTheme.primaryAccent
                                          .withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  log.level.toUpperCase(),
                                  style: TextStyle(
                                    fontFamily: 'Menlo',
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: log.level == 'error'
                                        ? ProfileLabTheme.failColor
                                        : ProfileLabTheme.primaryAccent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  log.message,
                                  style: TextStyle(
                                    fontFamily: 'Menlo',
                                    fontSize: 11,
                                    color: log.level == 'error'
                                        ? const Color(0xFFFCA5A5)
                                        : const Color(0xFFE2E8F0),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StageRowTile extends StatelessWidget {
  const _StageRowTile({required this.stage, required this.index});

  final ProfileLabLadderStageResult stage;
  final int index;

  @override
  Widget build(BuildContext context) {
    final isPassed = stage.status == 'passed';
    final isFailed = stage.status == 'failed';

    final statusColor = isPassed
        ? ProfileLabTheme.passColor
        : isFailed
            ? ProfileLabTheme.failColor
            : const Color(0xFF94A3B8);

    final icon = isPassed
        ? Icons.check_circle
        : isFailed
            ? Icons.cancel
            : Icons.do_not_disturb_on;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: statusColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$index. ${stage.displayName}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        stage.status.toUpperCase(),
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: statusColor),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: stage.consumesQuota
                            ? const Color(0xFFEF4444).withValues(alpha: 0.15)
                            : const Color(0xFF10B981).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        stage.consumesQuota ? 'Quota' : 'No Quota',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                          color: stage.consumesQuota
                              ? const Color(0xFFFCA5A5)
                              : const Color(0xFF6EE7B7),
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${stage.durationMs}ms',
                      style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 10,
                          color: Color(0xFF64748B)),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  stage.diagnostics,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

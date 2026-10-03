import 'package:flutter/material.dart';
import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';

class EvidenceView extends StatelessWidget {
  const EvidenceView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final draft = c.currentDraft;

    if (draft == null) {
      return const Center(child: Text('No draft selected.'));
    }

    final hasPassivePass = c.currentEvidence.any(
      (ev) =>
          ev['testType'] == 'local_passive_probe' &&
          ev['normalizedResult'] == 'pass',
    );
    final hasLivePass = c.currentEvidence.any(
      (ev) =>
          ev['testType'] == 'local_live_probe' &&
          ev['normalizedResult'] == 'pass',
    );

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'EVIDENCE-BOUND PROMOTION STATUS',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF94A3B8)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Identity Triplet: (${draft.profileDefinitionId}, v${draft.releaseVersion}, ${draft.payloadDigest.substring(0, 16)}...)',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _GateStatusBadge(
                        label: 'Gate 1 (Passive Probe)',
                        passed: hasPassivePass,
                      ),
                      const SizedBox(width: 12),
                      _GateStatusBadge(
                        label: 'Gate 2 (Live Probe)',
                        passed: hasLivePass,
                      ),
                      const SizedBox(width: 12),
                      _GateStatusBadge(
                        label: 'Gate 3 (Promotion Ready)',
                        passed: hasPassivePass && hasLivePass,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Evidence records list
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'EVIDENCE RECORDS FOR ACTIVE DIGEST (${c.currentEvidence.length})',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF94A3B8)),
              ),
              TextButton.icon(
                icon: const Icon(Icons.cleaning_services, size: 14),
                label: const Text('Purge Stale Evidence'),
                onPressed: () async {
                  await c.store.clearEvidence(
                    profileDefinitionId: draft.profileDefinitionId,
                    retainPayloadDigest: draft.payloadDigest,
                  );
                  await c.refreshEvidence();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),

          Expanded(
            child: c.currentEvidence.isEmpty
                ? Container(
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.darkSurface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: const Center(
                      child: Text(
                        'No evidence collected yet for this exact payload digest.\nRun tests in the Test Workbench to collect cryptographic evidence.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: c.currentEvidence.length,
                    itemBuilder: (ctx, idx) {
                      final ev = c.currentEvidence[idx];
                      final isPass = ev['normalizedResult'] == 'pass';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(
                            isPass ? Icons.check_circle : Icons.cancel,
                            color: isPass
                                ? ProfileLabTheme.passColor
                                : ProfileLabTheme.failColor,
                          ),
                          title: Row(
                            children: [
                              Text(
                                ev['testType'] as String? ?? 'unknown',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isPass
                                      ? ProfileLabTheme.passColor
                                          .withValues(alpha: 0.2)
                                      : ProfileLabTheme.failColor
                                          .withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  (ev['normalizedResult'] as String? ?? '')
                                      .toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isPass
                                        ? ProfileLabTheme.passColor
                                        : ProfileLabTheme.failColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            'Provider CLI: ${ev["providerCliVersion"]} | Engine: ${ev["engineVersion"]} | Time: ${ev["startedAt"]}',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF94A3B8)),
                          ),
                          trailing: Text(
                            '${ev["durationMs"]} ms',
                            style: const TextStyle(
                                fontFamily: 'Menlo', fontSize: 11),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _GateStatusBadge extends StatelessWidget {
  const _GateStatusBadge({required this.label, required this.passed});

  final String label;
  final bool passed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: passed
            ? ProfileLabTheme.passColor.withValues(alpha: 0.15)
            : ProfileLabTheme.darkBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: passed ? ProfileLabTheme.passColor : const Color(0xFF475569),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            passed ? Icons.check : Icons.hourglass_empty,
            size: 14,
            color: passed ? ProfileLabTheme.passColor : const Color(0xFF94A3B8),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: passed ? Colors.white : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}

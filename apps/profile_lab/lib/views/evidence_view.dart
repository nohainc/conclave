import 'package:flutter/material.dart';
import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';
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

    final activeEvidence =
        c.currentEvidence.cast<Map<String, Object?>?>().firstWhere(
              (evidence) => evidence?['profileDigest'] == draft.payloadDigest,
              orElse: () => null,
            );
    final scenarios =
        (activeEvidence?['scenarios'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final hasPassivePass = scenarios['passive_probe'] == 'passed';
    final hasLivePass = scenarios['live_probe'] == 'passed';
    final isAcceptanceReady = activeEvidence != null &&
        ToolProfileAcceptanceEvidence.hasCloudContractShape(
          activeEvidence,
          profile: draft.profile,
        );
    final hasMatchingPublishedRelease = c.cloudReleases.any((release) =>
        release['releaseVersion'] == draft.releaseVersion &&
        release['payloadDigest'] == draft.payloadDigest &&
        release['publishedAt'] is String);

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
                        passed: isAcceptanceReady,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Evidence records list
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'EVIDENCE RECORDS FOR ACTIVE DIGEST (${c.currentEvidence.length})',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF94A3B8)),
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
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
                  ElevatedButton.icon(
                    icon: c.isSubmittingCloudEvidence
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_outlined, size: 15),
                    label: const Text('Submit to Cloud'),
                    onPressed: isAcceptanceReady &&
                            hasMatchingPublishedRelease &&
                            !c.isSubmittingCloudEvidence
                        ? () async {
                            try {
                              final result =
                                  await c.submitCloudAcceptanceEvidence(
                                activeEvidence,
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Cloud stored evidence ${result['id']}.',
                                    ),
                                  ),
                                );
                              }
                            } catch (error) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Evidence submission failed: $error',
                                    ),
                                  ),
                                );
                              }
                            }
                          }
                        : null,
                  ),
                ],
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
                        'No complete Cloud contract evidence exists for this exact payload digest. Failed and incomplete runs remain in the Test Workbench results.',
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
                      final scenarios =
                          (ev['scenarios'] as Map?)?.cast<String, Object?>() ??
                              const <String, Object?>{};
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(
                            Icons.verified,
                            color: ProfileLabTheme.passColor,
                          ),
                          title: Row(
                            children: [
                              Text(
                                'Cloud acceptance contract',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: ProfileLabTheme.passColor
                                      .withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'COMPLETE',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: ProfileLabTheme.passColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            'Provider CLI: ${ev["providerToolVersion"]} | Engine: ${ev["engineVersion"]} | Accepted: ${ev["acceptedAt"]} | Scenarios: ${scenarios.length}',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF94A3B8)),
                          ),
                          trailing: Text(
                            '${scenarios.length} scenarios',
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

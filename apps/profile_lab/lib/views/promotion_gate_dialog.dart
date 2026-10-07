import '../widgets/lab_components.dart';
import 'dart:convert';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';
import '../theme/profile_lab_theme.dart';
import 'profile_lab_step_up.dart';

class PromotionGateChecklistItem {
  const PromotionGateChecklistItem({
    required this.id,
    required this.title,
    required this.description,
    required this.isSecurityGate,
    required this.passed,
    this.failureDetails,
  });

  final String id;
  final String title;
  final String description;
  final bool isSecurityGate;
  final bool passed;
  final String? failureDetails;
}

/// Modal dialog showing the 7-item Promotion Gate Evidence Checklist for an exact payload digest.
class PromotionGateDialog extends StatefulWidget {
  const PromotionGateDialog({
    super.key,
    required this.controller,
    required this.release,
    required this.targetChannel,
  });

  final ProfileLabController controller;
  final Map<String, dynamic> release;
  final String targetChannel;

  static Future<void> show({
    required BuildContext context,
    required ProfileLabController controller,
    required Map<String, dynamic> release,
    required String targetChannel,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => PromotionGateDialog(
        controller: controller,
        release: release,
        targetChannel: targetChannel,
      ),
    );
  }

  @override
  State<PromotionGateDialog> createState() => _PromotionGateDialogState();
}

class _PromotionGateDialogState extends State<PromotionGateDialog> {
  Map<String, dynamic>? _findQualifyingCloudEvidence(
    Map<String, dynamic> release,
    Map<String, dynamic> profile,
  ) {
    final releaseVersion = release['releaseVersion'];
    final releaseDigest = release['payloadDigest'];
    if (releaseVersion is! int || releaseDigest is! String) return null;
    final now = DateTime.now().toUtc();
    for (final record in widget.controller.cloudEvidence) {
      final evidence = record['evidence'];
      if (record['releaseVersion'] != releaseVersion ||
          record['payloadDigest'] != releaseDigest ||
          record['id'] is! String ||
          evidence is! Map) {
        continue;
      }
      final contract = evidence.cast<String, Object?>();
      if (!ToolProfileAcceptanceEvidence.hasCloudContractShape(
        contract,
        profile: profile.cast<String, Object?>(),
      )) {
        continue;
      }
      final acceptedAt = DateTime.tryParse(contract['acceptedAt'] as String);
      if (acceptedAt == null ||
          acceptedAt.isAfter(now.add(const Duration(minutes: 5))) ||
          now.difference(acceptedAt) > const Duration(days: 90)) {
        continue;
      }
      return record;
    }
    return null;
  }

  List<PromotionGateChecklistItem> _buildChecklist() {
    final c = widget.controller;
    final r = widget.release;
    final payload =
        (r['profile'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    // Gate 1: Signature Validity (Security)
    final signature = r['signature'] as String?;
    final gate1Passed = signature != null && signature.isNotEmpty;

    // Gate 2: Schema Validity (Security)
    bool gate2Passed = false;
    String? gate2Error;
    try {
      if (payload.isNotEmpty) {
        EngineProfile.parse(utf8.encode(canonicalJson(payload)));
        gate2Passed = true;
      }
    } catch (e) {
      gate2Error = e.toString();
    }

    // Gate 3: Identity Consistency (Security)
    final releaseWorkerTypeId = (r['workerTypeId'] as String?) ??
        payload['logicalWorkerTypeId']?.toString();
    final catalogWorkerTypeId =
        c.selectedCloudWorker?['workerTypeId'] as String?;
    final gate3Passed = releaseWorkerTypeId != null &&
        (catalogWorkerTypeId == null ||
            releaseWorkerTypeId == catalogWorkerTypeId);

    // Gate 4: Engine Compatibility (Recommendation)
    final engineComp =
        payload['engineCompatibility'] as Map<String, dynamic>? ?? {};
    final gate4Passed =
        engineComp['min'] != null && engineComp['maxExclusive'] != null;

    final isStablePromotion = widget.targetChannel.toLowerCase() == 'stable';
    final releaseDigest = r['payloadDigest'] as String?;
    final cloudRecord =
        isStablePromotion ? _findQualifyingCloudEvidence(r, payload) : null;
    final activeEv = isStablePromotion
        ? (cloudRecord?['evidence'] as Map?)?.cast<String, Object?>()
        : c.currentEvidence.cast<Map<String, Object?>?>().firstWhere(
              (evidence) => evidence?['profileDigest'] == releaseDigest,
              orElse: () => null,
            );
    final scenarios =
        (activeEv?['scenarios'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final expectedScenarios =
        cloudAcceptanceScenarioStatuses(payload.cast<String, Object?>());
    final evidenceMatchesProfile = activeEv != null &&
        ToolProfileAcceptanceEvidence.hasCloudContractShape(
          activeEv,
          profile: payload.cast<String, Object?>(),
        );
    final gate5Passed = scenarios['passive_probe'] == 'passed';
    final gate6Passed = scenarios['live_probe'] == 'passed';
    final gate7Passed = evidenceMatchesProfile &&
        expectedScenarios != null &&
        const [
          'model_selection',
          'representative_workstream_write',
          'durable_session_start',
          'durable_session_resume',
          'cancellation',
          'timeout',
        ].every(
            (scenario) => scenarios[scenario] == expectedScenarios[scenario]);

    return [
      PromotionGateChecklistItem(
        id: 'signature',
        title: 'Ed25519 Signature Validity',
        description: 'Signed by Cloud Signing Boundary authority',
        isSecurityGate: true,
        passed: gate1Passed,
        failureDetails: gate1Passed
            ? null
            : 'Unsigned release. Publication by Cloud Signing Boundary required.',
      ),
      PromotionGateChecklistItem(
        id: 'schema',
        title: 'Tool Profile v1 Schema Validity',
        description: 'Strict canonical JSON parsing & structure verification',
        isSecurityGate: true,
        passed: gate2Passed,
        failureDetails: gate2Error ??
            (gate2Passed ? null : 'Invalid payload schema structure.'),
      ),
      PromotionGateChecklistItem(
        id: 'identity',
        title: 'Logical Worker Identity Consistency',
        description:
            'Logical worker type matches definition descriptor ($releaseWorkerTypeId)',
        isSecurityGate: true,
        passed: gate3Passed,
        failureDetails: gate3Passed ? null : 'Worker type ID mismatch.',
      ),
      PromotionGateChecklistItem(
        id: 'engine_compatibility',
        title: 'CLI Worker Engine Compatibility',
        description:
            'Engine min/max exclusive bounds defined (${engineComp["min"]} - ${engineComp["maxExclusive"]})',
        isSecurityGate: false,
        passed: gate4Passed,
        failureDetails:
            gate4Passed ? null : 'Engine compatibility range missing.',
      ),
      PromotionGateChecklistItem(
        id: 'passive_probe',
        title: 'Local Passive & Version Probe',
        description: 'Executable discovery and passive authentication checks',
        isSecurityGate: false,
        passed: gate5Passed,
        failureDetails: gate5Passed
            ? null
            : 'No sandbox acceptance evidence records a passing passive probe for this release digest.',
      ),
      PromotionGateChecklistItem(
        id: 'live_execution',
        title: 'Live Probe & Execution Test',
        description: 'Generic CLI Engine OK probe and prompt execution test',
        isSecurityGate: false,
        passed: gate6Passed,
        failureDetails: gate6Passed
            ? null
            : 'No sandbox acceptance evidence records a passing live probe for this release digest.',
      ),
      PromotionGateChecklistItem(
        id: 'scenarios',
        title: 'Worker-Specific Scenario Evidence',
        description: isStablePromotion
            ? 'Cloud stored evidence ID: ${cloudRecord?['id'] ?? 'missing'}'
            : 'Verified workstream, session, and cancellation scenario evidence',
        isSecurityGate: false,
        passed: gate7Passed,
        failureDetails: gate7Passed
            ? null
            : isStablePromotion
                ? 'A current, qualifying Cloud evidence record is required for this release.'
                : 'Sandbox acceptance evidence is missing required scenarios for this release digest.',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final r = widget.release;
    final ver = r['releaseVersion'] as int;
    final digest = (r['payloadDigest'] as String?) ?? 'n/a';
    final items = _buildChecklist();
    final isStablePromotion = widget.targetChannel.toLowerCase() == 'stable';
    final storedEvidence = isStablePromotion
        ? _findQualifyingCloudEvidence(
            r,
            (r['profile'] as Map<String, dynamic>?) ?? <String, dynamic>{},
          )
        : null;
    final storedEvidenceId = storedEvidence?['id'] as String?;

    final hasSecurityFailure =
        items.any((item) => item.isSecurityGate && !item.passed);
    final hasRecommendationFailure =
        items.any((item) => !item.isSecurityGate && !item.passed);

    final canConfirm = !hasSecurityFailure &&
        !hasRecommendationFailure &&
        (!isStablePromotion || storedEvidenceId != null);

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined,
                  color: ProfileLabTheme.primaryAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Promotion Gate Checklist: v$ver → ${widget.targetChannel.toUpperCase()}'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Exact Digest: ${digest.length > 20 ? "${digest.substring(0, 20)}..." : digest}',
            style: const TextStyle(
                fontFamily: 'Menlo', fontSize: 11, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isStablePromotion && storedEvidenceId == null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lock_outline, color: Colors.amber, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Stable promotion requires current acceptance evidence already stored and validated by Cloud. Submit the complete sandbox evidence from the Evidence view.',
                          style:
                              TextStyle(fontSize: 11, color: Color(0xFFE2E8F0)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              // Security Gates Section
              const Text('SECURITY CONSTRAINTS (NON-OVERRIDEABLE)',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: ProfileLabTheme.warnColor)),
              const SizedBox(height: 6),
              ...items
                  .where((i) => i.isSecurityGate)
                  .map((i) => _GateItemTile(item: i)),

              const SizedBox(height: 16),

              // Recommendation Gates Section
              const Text('RECOMMENDATION GATES (REQUIRED FOR BETA)',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: Color(0xFF94A3B8))),
              const SizedBox(height: 6),
              ...items
                  .where((i) => !i.isSecurityGate)
                  .map((i) => _GateItemTile(item: i)),

              if (hasSecurityFailure) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ProfileLabTheme.failColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: ProfileLabTheme.failColor),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.block,
                          color: ProfileLabTheme.failColor, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'PROMOTION BLOCKED: Security gates (signing validity, schema validity, identity consistency) CANNOT be overridden under any circumstances.',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: ProfileLabTheme.failColor),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (hasRecommendationFailure) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Colors.amber, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Promotion is blocked until all listed checks pass. Stable promotion additionally requires current evidence already validated and stored by Cloud.',
                          style:
                              TextStyle(fontSize: 11, color: Color(0xFFE2E8F0)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.arrow_forward, size: 14),
          label: Text(
              'Confirm Promotion to ${widget.targetChannel.toUpperCase()}',
              style: const TextStyle(fontSize: 11)),
          style: ElevatedButton.styleFrom(
            backgroundColor: ProfileLabTheme.primaryAccent,
            foregroundColor: Colors.white,
          ),
          onPressed: canConfirm
              ? () async {
                  Navigator.of(context).pop();
                  try {
                    await c.promoteCloudRelease(
                      releaseVersion: ver,
                      channel: widget.targetChannel,
                      acceptanceEvidenceId: storedEvidenceId,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: CopyableMessage(
                                'Successfully promoted release v$ver to ${widget.targetChannel}')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      showProfileLabOperationFailure(
                        context,
                        c,
                        'Promotion',
                        e,
                      );
                    }
                  }
                }
              : null,
        ),
      ],
    );
  }
}

class _GateItemTile extends StatelessWidget {
  const _GateItemTile({required this.item});

  final PromotionGateChecklistItem item;

  @override
  Widget build(BuildContext context) {
    final statusColor = item.passed
        ? ProfileLabTheme.passColor
        : (item.isSecurityGate ? ProfileLabTheme.failColor : Colors.amber);

    final statusIcon = item.passed
        ? Icons.check_circle_outline
        : (item.isSecurityGate
            ? Icons.cancel_outlined
            : Icons.warning_amber_rounded);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: statusColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(statusIcon, color: statusColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        item.passed
                            ? 'PASSED'
                            : (item.isSecurityGate
                                ? 'SECURITY FAIL'
                                : 'WARNING'),
                        style: TextStyle(
                            fontSize: 11,
                            color: statusColor,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(item.description,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF94A3B8))),
                if (!item.passed && item.failureDetails != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.failureDetails!,
                    style: TextStyle(
                        fontSize: 11,
                        color: statusColor,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

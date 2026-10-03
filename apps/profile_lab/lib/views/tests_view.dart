import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';
import '../theme/profile_lab_theme.dart';
import 'provider_version_matrix_card.dart';

/// The Tests surface displays local and Cloud recorded acceptance evidence.
class TestsView extends StatefulWidget {
  const TestsView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<TestsView> createState() => _TestsViewState();
}

class _TestsViewState extends State<TestsView> {
  int _selectedScope = 0; // 0: Local Evidence, 1: Cloud Evidence

  @override
  void initState() {
    super.initState();
    if (widget.controller.selectedDefinitionId != null &&
        widget.controller.currentSession != null) {
      widget.controller.fetchCloudEvidence();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final draft = c.currentDraft;

    if (draft == null && c.selectedDefinitionId == null) {
      return const Center(
        child: Text(
          'No Profile Definition selected. Select a Worker or Profile first.',
          style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
        ),
      );
    }

    final defId = c.selectedDefinitionId ?? draft?.profileDefinitionId ?? '';
    final version =
        draft?.releaseVersion ?? c.selectedCloudRelease?['releaseVersion'] ?? 1;
    final digest = draft?.payloadDigest ??
        c.selectedCloudRelease?['payloadDigest'] ??
        'Unavailable';
    final activeEvidence =
        c.currentEvidence.cast<Map<String, Object?>?>().firstWhere(
              (evidence) => evidence?['profileDigest'] == digest,
              orElse: () => null,
            );
    final acceptanceScenarios =
        (activeEvidence?['scenarios'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final hasPassivePass = acceptanceScenarios['passive_probe'] == 'passed';
    final hasLivePass = acceptanceScenarios['live_probe'] == 'passed';
    final expectedScenarios =
        draft == null ? null : cloudAcceptanceScenarioStatuses(draft.profile);
    final isPromotionReady = activeEvidence != null &&
        expectedScenarios != null &&
        ToolProfileAcceptanceEvidence.hasCloudContractShape(
          activeEvidence,
          profile: draft!.profile,
        );

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Promotion Readiness Status Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'EVIDENCE-BOUND ACCEPTANCE GATES',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF94A3B8)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Target Triplet: ($defId, v$version, ${digest.length > 16 ? "${digest.substring(0, 16)}..." : digest})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _GateBadge(
                          label: 'Gate 1: Passive Probe',
                          passed: hasPassivePass),
                      const SizedBox(width: 12),
                      _GateBadge(
                          label: 'Gate 2: Live Probe', passed: hasLivePass),
                      const SizedBox(width: 12),
                      _GateBadge(
                          label: 'Gate 3: Promotion Ready',
                          passed: isPromotionReady),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            color: Colors.amber.withValues(alpha: 0.10),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.amber, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Submit complete local evidence separately to the matching published release. Cloud stores it immutably; Stable promotion references the stored evidence ID.',
                      style: TextStyle(fontSize: 11, color: Color(0xFFE2E8F0)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          if (draft != null) ...[
            ProviderVersionMatrixCard(
              profile: draft.profile,
              evidenceList: c.currentEvidence,
            ),
            const SizedBox(height: 16),
          ],

          // Scope Selector Header
          Row(
            children: [
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                    value: 0,
                    label: Text('Local Evidence (${c.currentEvidence.length})',
                        style: const TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: 1,
                    label: Text('Cloud Evidence (${c.cloudEvidence.length})',
                        style: const TextStyle(fontSize: 11)),
                  ),
                ],
                selected: {_selectedScope},
                onSelectionChanged: (set) {
                  setState(() {
                    _selectedScope = set.first;
                  });
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Spacer(),
              if (_selectedScope == 0 && draft != null)
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
              if (_selectedScope == 1)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  tooltip: 'Refresh Cloud Evidence',
                  onPressed: () => c.fetchCloudEvidence(),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Records List
          Expanded(
            child: _selectedScope == 0
                ? _buildLocalEvidenceList(c)
                : _buildCloudEvidenceList(c),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalEvidenceList(ProfileLabController c) {
    if (c.currentEvidence.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: ProfileLabTheme.darkSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: const Center(
          child: Text(
            'No complete Cloud contract evidence exists for the active payload digest. Failed and incomplete runs remain available in the Test Workbench results.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: c.currentEvidence.length,
      itemBuilder: (ctx, i) {
        final ev = c.currentEvidence[i];
        final acceptedAt = ev['acceptedAt'] as String? ?? '';
        final digest = ev['profileDigest'] as String? ?? '';
        final scenarios = (ev['scenarios'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            dense: true,
            leading: Icon(
              Icons.verified,
              color: ProfileLabTheme.passColor,
              size: 20,
            ),
            title: Row(
              children: [
                const Text('Cloud acceptance contract',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: ProfileLabTheme.passColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
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
              'Accepted: $acceptedAt\nDigest: $digest\nScenarios: ${scenarios.length}',
              style: const TextStyle(
                  fontFamily: 'Menlo', fontSize: 10, color: Color(0xFF94A3B8)),
            ),
            isThreeLine: true,
          ),
        );
      },
    );
  }

  Widget _buildCloudEvidenceList(ProfileLabController c) {
    if (c.currentSession == null) {
      return Container(
        decoration: BoxDecoration(
          color: ProfileLabTheme.darkSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: const Center(
          child: Text(
            'Sign in to query Cloud recorded acceptance evidence.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
        ),
      );
    }

    if (c.cloudEvidence.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: ProfileLabTheme.darkSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: const Center(
          child: Text(
            'No Cloud acceptance evidence found for this release.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: c.cloudEvidence.length,
      itemBuilder: (ctx, i) {
        final ev = c.cloudEvidence[i];
        final id = ev['id'] as String? ?? '';
        final submittedBy = ev['submittedByUserId'] as String? ?? 'system';
        final acceptedAt = ev['acceptedAt'] as String? ?? '';
        final digest = ev['payloadDigest'] as String? ?? '';
        final engineVer = ev['engineVersion'] as String? ?? '';
        final toolVer = ev['providerToolVersion'] as String? ?? '';
        final evidenceData = ev['evidence'] as Map<String, dynamic>? ?? {};
        final scenarios =
            (evidenceData['scenarios'] as Map?)?.cast<String, dynamic>() ?? {};

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ExpansionTile(
            dense: true,
            leading: const Icon(Icons.verified,
                color: ProfileLabTheme.primaryAccent, size: 20),
            title: Row(
              children: [
                Text('Evidence ID: ${id.length > 8 ? id.substring(0, 8) : id}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: ProfileLabTheme.passColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('ACCEPTED',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: ProfileLabTheme.passColor)),
                ),
              ],
            ),
            subtitle: Text(
              'Accepted: $acceptedAt | Engine: $engineVer | Provider CLI: $toolVer | By: $submittedBy',
              style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Digest: $digest',
                        style: const TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 10,
                            color: Color(0xFFCBD5E1))),
                    const SizedBox(height: 8),
                    const Text('Validated Scenarios:',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: scenarios.entries.map((entry) {
                        final isPass = entry.value == 'passed';
                        final isNotApplicable = entry.value == 'not_applicable';
                        final scenarioColor = isNotApplicable
                            ? const Color(0xFF94A3B8)
                            : isPass
                                ? ProfileLabTheme.passColor
                                : ProfileLabTheme.failColor;
                        return Chip(
                          visualDensity: VisualDensity.compact,
                          backgroundColor:
                              scenarioColor.withValues(alpha: 0.15),
                          side: BorderSide(
                              color: scenarioColor.withValues(alpha: 0.5)),
                          label: Text(
                            '${entry.key}: ${entry.value}',
                            style:
                                TextStyle(fontSize: 10, color: scenarioColor),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GateBadge extends StatelessWidget {
  const _GateBadge({required this.label, required this.passed});

  final String label;
  final bool passed;

  @override
  Widget build(BuildContext context) {
    final color =
        passed ? ProfileLabTheme.passColor : ProfileLabTheme.failColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(passed ? Icons.check : Icons.close, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
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
    final isPromotionReady = hasPassivePass && hasLivePass;

    final defId = c.selectedDefinitionId ?? draft?.profileDefinitionId ?? '';
    final version =
        draft?.releaseVersion ?? c.selectedCloudRelease?['releaseVersion'] ?? 1;
    final digest = draft?.payloadDigest ??
        c.selectedCloudRelease?['payloadDigest'] ??
        'Unavailable';

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
                      if (c.currentEvidence.isNotEmpty &&
                          c.currentSession != null)
                        ElevatedButton.icon(
                          icon: const Icon(Icons.cloud_upload, size: 14),
                          label: const Text('Submit Evidence to Cloud',
                              style: TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ProfileLabTheme.primaryAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () async {
                            try {
                              await c.submitActiveEvidenceToCloud();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Evidence submitted successfully to Cloud')),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text('Submission failed: $e')),
                                );
                              }
                            }
                          },
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
            'No local evidence recorded for the active payload digest.\nRun Passive or Live Probe in the Profiles tab to generate evidence.',
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
        final testType = ev['testType'] as String? ?? 'unknown';
        final result = ev['normalizedResult'] as String? ?? 'fail';
        final isPass = result == 'pass';
        final recordedAt = ev['recordedAt'] as String? ?? '';
        final digest = ev['payloadDigest'] as String? ?? '';

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            dense: true,
            leading: Icon(
              isPass ? Icons.check_circle : Icons.cancel,
              color: isPass
                  ? ProfileLabTheme.passColor
                  : ProfileLabTheme.failColor,
              size: 20,
            ),
            title: Row(
              children: [
                Text(testType,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: (isPass
                            ? ProfileLabTheme.passColor
                            : ProfileLabTheme.failColor)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    result.toUpperCase(),
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
              'Recorded: $recordedAt\nDigest: $digest',
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
                        return Chip(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: (isPass
                                  ? ProfileLabTheme.passColor
                                  : ProfileLabTheme.failColor)
                              .withValues(alpha: 0.15),
                          side: BorderSide(
                              color: (isPass
                                      ? ProfileLabTheme.passColor
                                      : ProfileLabTheme.failColor)
                                  .withValues(alpha: 0.5)),
                          label: Text(
                            '${entry.key}: ${entry.value}',
                            style: TextStyle(
                                fontSize: 10,
                                color: isPass
                                    ? ProfileLabTheme.passColor
                                    : ProfileLabTheme.failColor),
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

import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import '../utils/ai_provenance.dart';

/// The Audit surface displays who or what created, published, promoted, rolled back, or revoked a release.
class AuditView extends StatefulWidget {
  const AuditView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<AuditView> createState() => _AuditViewState();
}

class _AuditViewState extends State<AuditView> {
  @override
  void initState() {
    super.initState();
    if (widget.controller.currentSession != null) {
      widget.controller.fetchCloudAudit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final events = c.cloudAuditEvents;

    return Column(
      children: [
        // Top Toolbar
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: ProfileLabTheme.darkSurface,
            border: Border(bottom: BorderSide(color: Color(0xFF334155))),
          ),
          child: Row(
            children: [
              const Text(
                'PROFILE ADMINISTRATIVE AUDIT TRAIL',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8),
              ),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                segments: [
                  const ButtonSegment(
                      value: false,
                      label:
                          Text('Global Audit', style: TextStyle(fontSize: 11))),
                  ButtonSegment(
                    value: true,
                    label: Text(
                      c.selectedDefinitionId != null
                          ? 'Definition: ${c.selectedDefinitionId}'
                          : 'Current Definition',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
                selected: {c.auditFilterCurrentDefinition},
                onSelectionChanged: (set) {
                  c.fetchCloudAudit(definitionOnly: set.first);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh Audit Trail',
                onPressed: () => c.fetchCloudAudit(),
              ),
            ],
          ),
        ),

        // Audit events list
        Expanded(
          child: c.currentSession == null
              ? const Center(
                  child: Text(
                    'Sign in to query the Cloud administrative audit log.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                )
              : events.isEmpty
                  ? const Center(
                      child: Text(
                        'No audit events recorded.',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: events.length,
                      itemBuilder: (ctx, i) {
                        final event = events[i];
                        final action = event['action'] as String? ?? 'unknown';
                        final actor =
                            event['actorUserId'] as String? ?? 'System';
                        final defId =
                            event['profileDefinitionId'] as String? ?? '';
                        final ver = event['releaseVersion']?.toString() ?? '';
                        final prevVer =
                            event['previousReleaseVersion']?.toString();
                        final channel = event['channel'] as String?;
                        final fromState = event['fromState'] as String?;
                        final toState = event['toState'] as String?;
                        final reason = event['reason'] as String?;
                        final createdAt = event['createdAt'] as String? ?? '';
                        final details =
                            event['details'] as Map<String, dynamic>? ?? {};

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _ActionBadge(action: action),
                                    const SizedBox(width: 8),
                                    Text(
                                      '$defId v$ver',
                                      style: const TextStyle(
                                          fontFamily: 'Menlo',
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12),
                                    ),
                                    if (prevVer != null &&
                                        prevVer.isNotEmpty) ...[
                                      const SizedBox(width: 4),
                                      Text(
                                        '(from v$prevVer)',
                                        style: const TextStyle(
                                            fontFamily: 'Menlo',
                                            fontSize: 11,
                                            color: Color(0xFF94A3B8)),
                                      ),
                                    ],
                                    const Spacer(),
                                    Text(
                                      createdAt,
                                      style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF64748B)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.person_outline,
                                        size: 14, color: Color(0xFF94A3B8)),
                                    const SizedBox(width: 4),
                                    Text('Actor: $actor',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFFCBD5E1))),
                                    if (channel != null) ...[
                                      const SizedBox(width: 16),
                                      const Icon(Icons.alt_route,
                                          size: 14, color: Color(0xFF94A3B8)),
                                      const SizedBox(width: 4),
                                      Text('Channel: $channel',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFFCBD5E1))),
                                    ],
                                    if (fromState != null ||
                                        toState != null) ...[
                                      const SizedBox(width: 16),
                                      const Icon(Icons.swap_horiz,
                                          size: 14, color: Color(0xFF94A3B8)),
                                      const SizedBox(width: 4),
                                      Text(
                                          '${fromState ?? "none"} → ${toState ?? "none"}',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFFCBD5E1))),
                                    ],
                                  ],
                                ),
                                if (reason != null &&
                                    reason.trim().isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    'Reason: $reason',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontStyle: FontStyle.italic,
                                        color: Color(0xFF94A3B8)),
                                  ),
                                ],
                                if (details.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    'Details: $details',
                                    style: const TextStyle(
                                        fontFamily: 'Menlo',
                                        fontSize: 10,
                                        color: Color(0xFF64748B)),
                                  ),
                                ],
                                Builder(
                                  builder: (ctx) {
                                    final provData = details['provenance']
                                            as Map<String, dynamic>? ??
                                        details['_provenance']
                                            as Map<String, dynamic>? ??
                                        (details['profile'] is Map
                                            ? (details['profile']
                                                    as Map)['_provenance']
                                                as Map<String, dynamic>?
                                            : null);
                                    if (provData == null) {
                                      return const SizedBox.shrink();
                                    }

                                    final provenance =
                                        AiProvenance.fromJson(provData);
                                    final summary =
                                        provenance.formatAuditSummary(
                                      releaseVersion: int.tryParse(ver) ?? 1,
                                      testedProviderVersion:
                                          details['testedProviderVersion']
                                              as String?,
                                      publishedBy: action == 'release.published'
                                          ? 'controlled signer'
                                          : null,
                                      promotedBy: action == 'release.promoted'
                                          ? actor
                                          : null,
                                      channel: channel,
                                    );

                                    return Container(
                                      margin: const EdgeInsets.only(top: 8),
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: provenance.isAiAssisted
                                            ? const Color(0xFF1E1B4B)
                                            : ProfileLabTheme.darkSurface,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: provenance.isAiAssisted
                                              ? ProfileLabTheme.primaryAccent
                                              : const Color(0xFF334155),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            provenance.isAiAssisted
                                                ? Icons.auto_awesome
                                                : Icons.person_outline,
                                            size: 14,
                                            color:
                                                ProfileLabTheme.primaryAccent,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              summary,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.white,
                                                  height: 1.3),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _ActionBadge extends StatelessWidget {
  const _ActionBadge({required this.action});

  final String action;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (action) {
      'draft_created' => ('DRAFT CREATED', Colors.cyanAccent),
      'published_for_testing' => ('PUBLISHED FOR TESTING', Colors.blueAccent),
      'promoted_to_beta' => ('PROMOTED TO BETA', Colors.purpleAccent),
      'promoted_to_stable' => ('PROMOTED TO STABLE', ProfileLabTheme.passColor),
      'stable_rollback' => ('STABLE ROLLBACK', ProfileLabTheme.warnColor),
      'channel_promoted' => ('CHANNEL PROMOTED', Colors.indigoAccent),
      'channel_cleared' => ('CHANNEL CLEARED', const Color(0xFF94A3B8)),
      'retired' => ('RETIRED', Colors.orangeAccent),
      'revoked' => ('REVOKED', ProfileLabTheme.failColor),
      _ => (action.toUpperCase().replaceAll('_', ' '), const Color(0xFF94A3B8)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}

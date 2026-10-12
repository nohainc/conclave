import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import '../utils/profile_activity_mapping_fixtures.dart';

/// Deterministic replay of the sanitized provider event fixture for the
/// current candidate. This is deliberately separate from live provider tests.
class EventMappingTestView extends StatelessWidget {
  const EventMappingTestView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  Widget build(BuildContext context) {
    final candidate = controller.currentDraft;
    if (candidate == null) return const SizedBox.shrink();
    final replay = controller.activityMappingTestMatchesDraft
        ? controller.lastActivityMappingReplay
        : null;
    final canRun = !controller.isTesting &&
        !controller.isPublishing &&
        !controller.isDirty &&
        controller.jsonValidationError == null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Event Mapping',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.replay, size: 16),
                  label: Text(replay == null ? 'Replay fixtures' : 'Rerun'),
                  onPressed:
                      canRun ? () => controller.runActivityMappingTest() : null,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Candidate digest · ${_shortDigest(candidate.payloadDigest)}',
              style: const TextStyle(
                color: ProfileLabTheme.secondaryText,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            if (replay == null)
              const Text(
                'Replay the sanitized Codex or agy event fixture to verify this Profile’s declarative mappings.',
              )
            else ...[
              _ReplayStatus(replay: replay),
              if (replay.events.isNotEmpty)
                Text(
                  '${replay.fixtureName} · ${replay.events.length} provider events · ${replay.activities.length} normalized activities',
                  style: const TextStyle(
                    color: ProfileLabTheme.secondaryText,
                    fontSize: 11,
                  ),
                ),
              if (replay.activities.isNotEmpty)
                SizedBox(
                  height: 220,
                  child: ListView.builder(
                    itemCount: replay.activities.length,
                    itemBuilder: (context, index) {
                      final activity = replay.activities[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          activity.status == 'failed'
                              ? Icons.error_outline
                              : activity.status == 'completed'
                                  ? Icons.check_circle_outline
                                  : Icons.bolt_outlined,
                          size: 18,
                          color: activity.status == 'failed'
                              ? ProfileLabTheme.failColor
                              : activity.status == 'completed'
                                  ? ProfileLabTheme.passColor
                                  : ProfileLabTheme.primaryAccent,
                        ),
                        title: Text(activity.title),
                        subtitle: Text(
                          [
                            activity.type,
                            activity.status,
                            if (activity.activityId != null)
                              'id=${activity.activityId}',
                            ...activity.details.entries.map(
                              (entry) => '${entry.key}=${entry.value}',
                            ),
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              if (replay.status == 'failed')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    replay.message,
                    style: const TextStyle(color: ProfileLabTheme.failColor),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReplayStatus extends StatelessWidget {
  const _ReplayStatus({required this.replay});

  final ProfileActivityMappingReplayResult replay;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(
            replay.status == 'passed'
                ? Icons.check_circle_outline
                : replay.status == 'failed'
                    ? Icons.error_outline
                    : Icons.remove_circle_outline,
            size: 18,
            color: replay.status == 'passed'
                ? ProfileLabTheme.passColor
                : replay.status == 'failed'
                    ? ProfileLabTheme.failColor
                    : ProfileLabTheme.secondaryText,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('${replay.status} · ${replay.message}')),
        ],
      );
}

String _shortDigest(String digest) =>
    digest.length <= 12 ? digest : digest.substring(0, 12);

import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import '../utils/profile_domain_diff.dart';
import 'profile_release_diff_view.dart';

/// Compact human confirmation before the toolbar's final Publish action.
class ProfilePublishConfirmationDialog extends StatelessWidget {
  const ProfilePublishConfirmationDialog({
    super.key,
    required this.controller,
  });

  final ProfileLabController controller;

  static Future<bool?> show(
    BuildContext context,
    ProfileLabController controller,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (_) => ProfilePublishConfirmationDialog(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final candidate = controller.currentDraft?.profile == null
        ? null
        : Map<String, dynamic>.from(controller.currentDraft!.profile);
    final current = controller.currentCloudProfileSnapshot?['profile'] is Map
        ? Map<String, dynamic>.from(
            controller.currentCloudProfileSnapshot!['profile'] as Map,
          )
        : null;
    final groups = ProfileDomainDiffCalculator.computeDiff(candidate, current);
    final changed = groups.where((group) => group.hasChanges).toList();
    final sensitive = changed
        .where((group) =>
            group.domainName.contains('Provider') ||
            group.domainName.contains('Environment') ||
            group.domainName.contains('Security'))
        .toList();
    final changes = changed.fold<int>(
      0,
      (total, group) => total + group.changeCount,
    );

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.publish_outlined, color: ProfileLabTheme.primaryAccent),
          SizedBox(width: 8),
          Text('Publish Profile'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              current == null
                  ? 'This will publish the first current Profile for this Worker.'
                  : 'This will publish the candidate as the next current revision.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Meta(
                    label: 'Current',
                    value: current == null
                        ? 'None'
                        : 'r${controller.currentProfileRevision}'),
                _Meta(
                  label: 'Candidate',
                  value: controller.currentDraft == null
                      ? 'Unavailable'
                      : controller.currentDraft!.payloadDigest.substring(0, 12),
                ),
                _Meta(label: 'Changes', value: '$changes'),
              ],
            ),
            const SizedBox(height: 12),
            if (sensitive.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ProfileLabTheme.warnColor.withValues(alpha: 0.12),
                  border: Border.all(
                    color: ProfileLabTheme.warnColor.withValues(alpha: 0.6),
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: ProfileLabTheme.warnColor,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Review sensitive changes: ${sensitive.map((group) => group.domainName).join(', ')}.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )
            else
              const Text(
                'No provider, environment, or security-boundary changes detected.',
                style: TextStyle(
                  color: ProfileLabTheme.secondaryText,
                  fontSize: 12,
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'Cloud will revalidate the exact digest, enforce the expected revision, sign the snapshot, and publish atomically.',
              style: TextStyle(
                color: ProfileLabTheme.secondaryText,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => ProfileReleaseDiffDialog.show(
            context,
            titleA: 'Candidate',
            payloadA: candidate,
            titleB: 'Current Profile',
            payloadB: current,
          ),
          child: const Text('Compare details'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Publish'),
        ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkSurface,
        border: Border.all(color: ProfileLabTheme.borderColor),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text('$label · $value', style: const TextStyle(fontSize: 12)),
    );
  }
}

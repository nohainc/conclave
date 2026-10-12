import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'profile_release_diff_view.dart';

/// On-demand history view for the one current Profile and its published snapshots.
class ProfileHistoryDialog extends StatefulWidget {
  const ProfileHistoryDialog({super.key, required this.controller});

  final ProfileLabController controller;

  static Future<void> show(
    BuildContext context,
    ProfileLabController controller,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => ProfileHistoryDialog(controller: controller),
    );
  }

  @override
  State<ProfileHistoryDialog> createState() => _ProfileHistoryDialogState();
}

class _ProfileHistoryDialogState extends State<ProfileHistoryDialog> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.fetchCurrentProfileHistory());
  }

  Future<void> _restore(Map<String, dynamic> snapshot) async {
    final targetRevision = (snapshot['revision'] as num?)?.toInt();
    if (targetRevision == null) return;
    final reason = await _askReason(targetRevision);
    if (!mounted || reason == null) return;
    try {
      await widget.controller.restoreCurrentProfileRevision(
        targetRevision: targetRevision,
        restorationReason: reason,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Revision $targetRevision restored as the new current Profile.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $error')),
        );
      }
    }
  }

  Future<String?> _askReason(int targetRevision) async {
    var reason = 'Restore known-good Profile revision $targetRevision';
    final reasonController = TextEditingController(text: reason);
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Restore revision $targetRevision?'),
          content: TextField(
            autofocus: true,
            maxLength: 512,
            controller: reasonController,
            onChanged: (value) => reason = value,
            decoration: const InputDecoration(
              labelText: 'Restoration reason',
              hintText: 'Why is this snapshot being restored?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(reason.trim()),
              child: const Text('Restore as current'),
            ),
          ],
        ),
      );
    } finally {
      reasonController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.history, color: ProfileLabTheme.primaryAccent),
          SizedBox(width: 8),
          Text('Profile history'),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 420,
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) {
            if (c.isLoadingProfileHistory) {
              return const Center(child: CircularProgressIndicator());
            }
            if (c.currentProfileHistory.isEmpty) {
              return const Center(
                child: Text('No previous published revisions are available.'),
              );
            }
            return ListView.separated(
              itemCount: c.currentProfileHistory.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final snapshot = c.currentProfileHistory[index];
                final revision = (snapshot['revision'] as num?)?.toInt() ?? 0;
                final digest = snapshot['digest'] as String? ?? 'unknown';
                final updatedAt = snapshot['publishedAt'] as String? ??
                    snapshot['updatedAt'] as String? ??
                    'Unknown time';
                final digestPreview =
                    digest.length <= 12 ? digest : digest.substring(0, 12);
                final profile = snapshot['profile'] is Map
                    ? Map<String, dynamic>.from(snapshot['profile'] as Map)
                    : null;
                return ListTile(
                  leading: CircleAvatar(
                    radius: 16,
                    child: Text('$revision'),
                  ),
                  title: Text('Revision $revision'),
                  subtitle: Text(
                    '$digestPreview · $updatedAt · Published',
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        tooltip: 'Compare with current Profile',
                        icon: const Icon(Icons.compare_arrows, size: 18),
                        onPressed: profile == null
                            ? null
                            : () => ProfileReleaseDiffDialog.show(
                                  context,
                                  titleA: 'Revision $revision',
                                  payloadA: profile,
                                  titleB: 'Current Profile',
                                  payloadB:
                                      c.currentCloudProfileSnapshot?['profile']
                                              is Map
                                          ? Map<String, dynamic>.from(
                                              c.currentCloudProfileSnapshot![
                                                  'profile'] as Map,
                                            )
                                          : null,
                                ),
                      ),
                      IconButton(
                        tooltip: 'Restore revision $revision',
                        icon: const Icon(Icons.restore, size: 18),
                        onPressed: c.isRestoringProfile || !c.canPublish
                            ? null
                            : () => _restore(snapshot),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => unawaited(c.fetchCurrentProfileHistory()),
          child: const Text('Refresh'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

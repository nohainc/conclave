import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';

/// Cloud evidence is scoped to one published release, never the local Draft.
class ReleaseEvidenceView extends StatelessWidget {
  const ReleaseEvidenceView(
      {super.key, required this.controller, required this.release});
  final ProfileLabController controller;
  final Map<String, dynamic> release;

  @override
  Widget build(BuildContext context) {
    final definition =
        release['profileDefinitionId'] ?? controller.selectedDefinitionId;
    final version = release['releaseVersion'];
    final digest = release['payloadDigest'];
    final profile = release['profile'];
    final records = controller.cloudEvidence.where((record) {
      final evidence = record['evidence'];
      return record['profileDefinitionId'] == definition &&
          record['releaseVersion'] == version &&
          record['payloadDigest'] == digest &&
          evidence is Map &&
          evidence['profileDefinitionId'] == definition &&
          evidence['releaseVersion'] == version &&
          evidence['profileDigest'] == digest &&
          ToolProfileAcceptanceEvidence.hasCloudContractShape(
              evidence.cast<String, Object?>(),
              profile: profile is Map ? profile.cast<String, Object?>() : null);
    }).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Cloud acceptance evidence',
          style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      if (controller.isLoadingEvidence)
        const OperationProgress(label: 'Loading…'),
      if (controller.evidenceError != null)
        ErrorState(
            message: controller.evidenceError!,
            onRetry: controller.isLoadingEvidence
                ? null
                : () => controller.fetchCloudEvidence(
                    profileDefinitionId: definition as String,
                    version: version as int))
      else if (!controller.isLoadingEvidence && records.isEmpty)
        const EmptyState(
            title: 'No Cloud acceptance evidence recorded for this release.'),
      for (final record in records)
        Card(
            child: ExpansionTile(
                key: ValueKey('release-evidence-${record['id']}'),
                title: Text('Evidence ${record['id']}'),
                subtitle: Text(
                    'Provider ${record['providerToolVersion']} · Engine ${record['engineVersion']}'),
                children: [
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Accepted: ${record['acceptedAt']}'),
                        SelectableText('Payload digest: $digest'),
                        for (final entry
                            in ((record['evidence'] as Map)['scenarios'] as Map)
                                .entries)
                          Text('${entry.key}: ${entry.value}'),
                      ]))
            ])),
    ]);
  }
}

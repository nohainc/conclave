import 'dart:convert';
import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';
import '../controllers/profile_lab_controller.dart';
import '../utils/activity_event_summary.dart';
import '../utils/ai_provenance.dart';

class AuditView extends StatelessWidget {
  const AuditView({super.key, required this.controller});
  final ProfileLabController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
        padding: const EdgeInsets.all(LabSpace.medium),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LabPageHeader(title: 'Activity', actions: [
            Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  ChoiceChip(
                      label: const Text('All events'),
                      selected: !c.auditFilterCurrentDefinition,
                      onSelected: c.isLoadingAudit
                          ? null
                          : (_) => c.fetchCloudAudit(definitionOnly: false)),
                  ChoiceChip(
                      label: Text(
                          c.selectedCloudWorker?['displayName'] as String? ??
                              'Current Worker'),
                      selected: c.auditFilterCurrentDefinition,
                      onSelected:
                          c.isLoadingAudit || c.selectedDefinitionId == null
                              ? null
                              : (_) => c.fetchCloudAudit(definitionOnly: true)),
                  IconButton(
                      tooltip: 'Refresh Activity (⌘R)',
                      icon: const Icon(Icons.refresh),
                      onPressed:
                          c.isLoadingAudit ? null : () => c.fetchCloudAudit())
                ])
          ]),
          if (c.isLoadingAudit) const OperationProgress(label: 'Loading…'),
          if (c.auditError != null)
            ErrorState(
                message: c.auditError!,
                onRetry: c.isLoadingAudit ? null : () => c.fetchCloudAudit()),
          Expanded(
              child: c.currentSession == null
                  ? const EmptyState(title: 'Sign in to view Activity.')
                  : c.cloudAuditEvents.isEmpty
                      ? const EmptyState(title: 'No activity recorded.')
                      : ListView.builder(
                          itemCount: c.cloudAuditEvents.length,
                          itemBuilder: (context, index) {
                            final event = c.cloudAuditEvents[index];
                            final worker = c.cloudWorkers
                                .where((w) =>
                                    w['profileDefinitionId'] ==
                                    event['profileDefinitionId'])
                                .firstOrNull;
                            final name =
                                event['workerDisplayName'] as String? ??
                                    worker?['displayName'] as String? ??
                                    event['profileDefinitionId'] as String? ??
                                    'Profile';
                            final actor =
                                event['actorDisplayName'] as String? ??
                                    (event['actorUserId'] ==
                                            c.currentSession?.userId
                                        ? c.currentSession?.displayName
                                        : null);
                            final details = event['details'] as Map? ?? {};
                            final prov = details['provenance'] ??
                                details['_provenance'] ??
                                (details['profile'] is Map
                                    ? (details['profile'] as Map)['_provenance']
                                    : null);
                            return Card(
                                child: ExpansionTile(
                                    key: ValueKey(event['id'] ?? index),
                                    title: Text(activityEventSummary(event,
                                        workerName: name, actorName: actor)),
                                    subtitle: Text(
                                        '${event['createdAt'] ?? 'Time unavailable'}'),
                                    children: [
                                  Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            if (prov is Map<String, dynamic>)
                                              Text(AiProvenance.fromJson(prov)
                                                  .formatAuditSummary(
                                                      releaseVersion:
                                                          event['releaseVersion']
                                                                  as int? ??
                                                              1)),
                                            const Text('Event details',
                                                style: TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            const SizedBox(height: 8),
                                            SelectableText(
                                                const JsonEncoder.withIndent(
                                                        '  ')
                                                    .convert(event),
                                                style: ConclaveTypography
                                                    .monoSmall)
                                          ]))
                                ]));
                          }))
        ]));
  }
}

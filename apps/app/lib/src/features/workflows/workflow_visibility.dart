import '../../ax/ax_models.dart';

/// Workflows that are currently supported for regular users.
const implementedWorkflowIds = <String>{'chat', 'direct', 'work'};

/// The account allowed to preview workflow definitions that are still under
/// development. This is a UI visibility rule; execution authorization remains
/// owned by Cloud.
const workflowPreviewAccountEmail = 'vitalii@nohainc.com';

bool canPreviewUnimplementedWorkflows(String? viewerEmail) =>
    viewerEmail?.trim().toLowerCase() == workflowPreviewAccountEmail;

List<AxBuiltinWorkflow> visibleWorkflowDefinitions(
  Iterable<AxBuiltinWorkflow> definitions, {
  String? viewerEmail,
}) {
  if (canPreviewUnimplementedWorkflows(viewerEmail)) {
    return definitions.toList(growable: false);
  }
  return definitions
      .where((definition) => implementedWorkflowIds.contains(definition.id))
      .toList(growable: false);
}

import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Compatibility surface for callers that still construct the old Workers
/// tab. Worker inventory and controls now live exclusively in Workspace cards.
@Deprecated('Workers are displayed inside their owning Workspace cards.')
class WorkersTab extends StatelessWidget {
  const WorkersTab({
    super.key,
    required this.workspaces,
    required this.plugins,
    this.workspaceWorkers = const [],
    this.onScheduling,
  });

  final List<StudioAgent> workspaces;
  final List<StudioPlugin> plugins;
  final List<StudioWorkspaceWorker> workspaceWorkers;
  final Future<void> Function(StudioWorkspaceWorker worker, String action)?
      onScheduling;

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Workers are shown inside their owning Workspace cards. Open Workspaces to view readiness and scheduling controls.',
        ),
      );
}

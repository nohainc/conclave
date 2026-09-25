import 'package:flutter/material.dart';

import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';
import 'studio_shell_context.dart';

/// Interactive Project Tree component for the Conclave AX App Sidebar.
class ProjectTree extends StatelessWidget {
  const ProjectTree({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onToggleProjectExpanded,
    required this.onCreateProject,
    this.onCreateWorkstream,
    this.compact = false,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final ValueChanged<String> onToggleProjectExpanded;
  final VoidCallback onCreateProject;
  final ValueChanged<StudioProject>? onCreateWorkstream;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shellContext.projects.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              'No projects yet',
              style: TextStyle(
                fontSize: 11.5,
                color: Colors.white38,
              ),
            ),
          ),
        ...shellContext.projects
            .map((project) => _buildProjectItem(context, project)),
      ],
    );
  }

  Widget _buildProjectItem(BuildContext context, StudioProject project) {
    final isProjectFocused =
        shellContext.navigation.projectId == project.id &&
            shellContext.navigation.kind == StudioRouteKind.project;
    final isExpanded = shellContext.isProjectExpanded(project.id);
    final visibleWorkstreams = project.workstreams
        .where((w) => w.status.toLowerCase() != 'archived')
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: isProjectFocused
                ? const Color(0xff29283c)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // Chevron: expands / collapses workstreams
              IconButton(
                onPressed: () => onToggleProjectExpanded(project.id),
                icon: Icon(
                  isExpanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: Colors.white54,
                ),
                tooltip:
                    isExpanded ? 'Collapse workstreams' : 'Expand workstreams',
                splashRadius: 12,
                padding: const EdgeInsets.all(4),
                constraints:
                    const BoxConstraints(minWidth: 24, minHeight: 24),
              ),
              // Project title row: navigates to /projects/:projectId; toggles expansion only when clicking again on the current active project
              Expanded(
                child: InkWell(
                  onTap: () {
                    if (isProjectFocused) {
                      onToggleProjectExpanded(project.id);
                    }
                    onNavigateTo(StudioNavigation.project(project.id));
                    if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 6),
                    child: Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isProjectFocused
                            ? Colors.white
                            : Colors.white70,
                        fontSize: 12.5,
                        fontWeight: isProjectFocused
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (isExpanded)
          ...visibleWorkstreams.map(
            (workstream) {
              final isWorkstreamSelected =
                  shellContext.navigation.workstreamId == workstream.id ||
                  shellContext.selectedWorkstream?.id == workstream.id;
              final statusIndicator =
                  _buildWorkstreamStatusIndicator(workstream.status);

              return InkWell(
                onTap: () {
                  onNavigateTo(StudioNavigation.workstream(
                      project.id, workstream.id));
                  if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 1),
                  padding: const EdgeInsets.fromLTRB(28, 6, 10, 6),
                  decoration: BoxDecoration(
                    color: isWorkstreamSelected
                        ? const Color(0xff302d4b)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          workstream.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isWorkstreamSelected
                                ? Colors.white
                                : Colors.white60,
                            fontSize: 11.5,
                            fontWeight: isWorkstreamSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (statusIndicator != null) ...[
                        const SizedBox(width: 8),
                        statusIndicator,
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget? _buildWorkstreamStatusIndicator(String status) {
    switch (status.toLowerCase()) {
      case 'running':
      case 'executing':
        return Container(
          width: 6.5,
          height: 6.5,
          decoration: const BoxDecoration(
            color: Color(0xffa78bfa),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x66a78bfa),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      case 'queued':
      case 'ready':
      case 'scheduled':
        return Container(
          width: 6.5,
          height: 6.5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xff94a3b8),
              width: 1.2,
            ),
          ),
        );
      case 'blocked':
      case 'failed':
      case 'attention':
      case 'needs_approval':
        return Container(
          width: 6.5,
          height: 6.5,
          decoration: const BoxDecoration(
            color: Color(0xfff59e0b),
            shape: BoxShape.circle,
          ),
        );
      case 'idle':
      case 'done':
      case 'completed':
      default:
        return null;
    }
  }
}

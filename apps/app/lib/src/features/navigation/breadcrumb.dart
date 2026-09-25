import 'package:flutter/material.dart';

import '../../navigation/studio_navigation.dart';
import 'studio_shell_context.dart';

/// Route-aware breadcrumb widget for Conclave AX HUD.
class AppBreadcrumb extends StatelessWidget {
  const AppBreadcrumb({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.inkColor,
    required this.mutedInk,
    this.compact = false,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final Color inkColor;
  final Color mutedInk;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final nav = shellContext.navigation;
    final project = shellContext.selectedProject;
    final workstream = shellContext.selectedWorkstream;

    final children = switch (nav.kind) {
      StudioRouteKind.home => [
          _breadcrumbText('Home', isCurrent: true),
        ],
      StudioRouteKind.projects => [
          _breadcrumbText('Projects', isCurrent: true),
        ],
      StudioRouteKind.project => [
          _breadcrumbText(project?.name ?? 'Project', isCurrent: true),
        ],
      StudioRouteKind.workstream => [
          if (project != null) ...[
            _breadcrumbLink(
              project.name,
              () => onNavigateTo(StudioNavigation.project(project.id)),
            ),
            _divider(),
          ] else ...[
            _breadcrumbLink(
              'Home',
              () => onNavigateTo(const StudioNavigation.home()),
            ),
            _divider(),
          ],
          _breadcrumbText(workstream?.name ?? 'Workstream', isCurrent: true),
        ],
      StudioRouteKind.run => [
          if (project != null) ...[
            _breadcrumbLink(
              project.name,
              () => onNavigateTo(StudioNavigation.project(project.id)),
            ),
            _divider(),
          ] else ...[
            _breadcrumbLink(
              'Projects',
              () => onNavigateTo(const StudioNavigation.projects()),
            ),
            _divider(),
          ],
          if (nav.workstreamId != null && project != null) ...[
            _breadcrumbLink(
              workstream?.name ?? 'Workstream',
              () => onNavigateTo(
                  StudioNavigation.workstream(project.id, nav.workstreamId!)),
            ),
            _divider(),
          ],
          _breadcrumbText('Run', isCurrent: true),
        ],
      StudioRouteKind.hosts => [
          _breadcrumbText('Execution', isCurrent: true),
        ],
      StudioRouteKind.workers => [
          _breadcrumbLink(
            'Execution',
            () => onNavigateTo(const StudioNavigation.hosts()),
          ),
          _divider(),
          _breadcrumbText('Workers', isCurrent: true),
        ],
      StudioRouteKind.usage => [
          _breadcrumbText('Usage', isCurrent: true),
        ],
      StudioRouteKind.profileSecurity => [
          _breadcrumbText('Profile & Security', isCurrent: true),
        ],
      StudioRouteKind.search => [
          _breadcrumbText('Search', isCurrent: true),
        ],
      _ => [
          _breadcrumbText('Conclave AX', isCurrent: true),
        ],
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _breadcrumbText(String text, {required bool isCurrent}) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 14.5,
        fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
        color: inkColor,
      ),
    );
  }

  Widget _breadcrumbLink(String text, VoidCallback onTap, {String? tooltip}) {
    final link = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: mutedInk,
          ),
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip, child: link);
    }
    return link;
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '/',
        style: TextStyle(fontSize: 13, color: mutedInk),
      ),
    );
  }
}

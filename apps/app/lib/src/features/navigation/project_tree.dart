import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import 'ax_shell_context.dart';
import '../../ax/sync/ax_query_builder.dart';

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

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final ValueChanged<String> onToggleProjectExpanded;
  final VoidCallback onCreateProject;
  final ValueChanged<AxProject>? onCreateWorkstream;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    Widget content(BuildContext context) {
      final invitations = shellContext.invitationsListenable;
      if (invitations != null) {
        return ValueListenableBuilder<List<AxProjectInvitation>>(
          valueListenable: invitations,
          builder: (context, _, __) => _tree(context),
        );
      }
      return _tree(context);
    }

    final projects = shellContext.projectListenable;
    if (projects != null) {
      return ValueListenableBuilder<List<AxProject>>(
        valueListenable: projects,
        builder: (context, _, __) => content(context),
      );
    }
    return content(context);
  }

  Widget _tree(BuildContext context) {
    final invitations = shellContext.invitations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (invitations.isNotEmpty) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: ConclaveBrand.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: ConclaveBrand.accent.withValues(alpha: 0.3),
              ),
            ),
            child: InkWell(
              onTap: () => onNavigateTo(const AxNavigation.home()),
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  const Icon(
                    Icons.mail_outline,
                    size: 14,
                    color: ConclaveBrand.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Pending invitations (${invitations.length})',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
        ],
        if (shellContext.projects.isEmpty && invitations.isEmpty)
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
        if (shellContext.ownedProjects.isNotEmpty) ...[
          if (shellContext.sharedProjects.isNotEmpty)
            _groupLabel('Your projects'),
          ...shellContext.ownedProjects
              .map((project) => _buildProjectItem(context, project)),
        ],
        if (shellContext.sharedProjects.isNotEmpty) ...[
          _groupLabel('Shared with you'),
          ...shellContext.sharedProjects
              .map((project) => _buildProjectItem(context, project)),
        ],
      ],
    );
  }

  Widget _groupLabel(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 8, 6),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white54)));

  Widget _buildProjectItem(BuildContext context, AxProject project) {
    final cache = shellContext.projectWorkstreams;
    if (cache != null && shellContext.isProjectExpanded(project.id)) {
      return AxQueryBuilder<List<AxWorkstream>>(
        key: ValueKey('project-workstreams-${project.id}'),
        engine: cache.engine,
        query: cache.query(project.id),
        builder: (context, state) => _projectItem(
            context, project, state.data ?? const [],
            loading: !state.hasData && state.isFetching,
            error: !state.hasData ? state.error : null),
      );
    }
    return _projectItem(context, project,
        shellContext.workstreamsByProject[project.id] ?? const []);
  }

  Widget _projectItem(
      BuildContext context, AxProject project, List<AxWorkstream> workstreams,
      {bool loading = false, Object? error}) {
    final isProjectFocused = shellContext.navigation.projectId == project.id &&
        shellContext.navigation.kind == AxRouteKind.project;
    final isExpanded = shellContext.isProjectExpanded(project.id);
    final visibleWorkstreams =
        workstreams.where((w) => w.status.toLowerCase() != 'archived').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: isProjectFocused
                ? ConclaveColors.navigationSelected
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: InkWell(
            onTap: project.id.startsWith('local-project-')
                ? null
                : () {
                    // Selecting an already-expanded other Project preserves expansion.
                    if (!isExpanded || isProjectFocused) {
                      onToggleProjectExpanded(project.id);
                    }
                    onNavigateTo(AxNavigation.project(project.id));
                    if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                  },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  ConclaveFolderIcon(
                    isExpanded: isExpanded,
                    size: 16,
                    color: isProjectFocused ? Colors.white : Colors.white54,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isProjectFocused ? Colors.white : Colors.white70,
                        fontSize: 12.5,
                        fontWeight: isProjectFocused
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded && loading)
          const Padding(
              padding: EdgeInsets.fromLTRB(34, 6, 10, 6),
              child: Text('Loading Workstreams…',
                  style: TextStyle(color: Colors.white60, fontSize: 11.5))),
        if (isExpanded && error != null)
          TextButton(
              onPressed: () => shellContext.projectWorkstreams
                  ?.ensure(project.id)
                  .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
              child: const Text('Retry Workstreams')),
        if (isExpanded)
          ...visibleWorkstreams.map(
            (workstream) {
              final isWorkstreamSelected =
                  shellContext.navigation.workstreamId == workstream.id ||
                      shellContext.selectedWorkstream?.id == workstream.id;
              final statusIndicator =
                  _buildWorkstreamStatusIndicator(workstream.status);

              return InkWell(
                onTap: workstream.id.startsWith('local-workstream-')
                    ? null
                    : () {
                        onNavigateTo(
                            AxNavigation.workstream(project.id, workstream.id));
                        if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                      },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 1),
                  padding: const EdgeInsets.fromLTRB(34, 6, 10, 6),
                  decoration: BoxDecoration(
                    color: isWorkstreamSelected
                        ? ConclaveColors.navigationSelected
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
          decoration: BoxDecoration(
            color: ConclaveColors.primaryForegroundDark,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:
                    ConclaveColors.primaryForegroundDark.withValues(alpha: 0.4),
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
              color: ConclaveColors.textSecondaryLight,
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
            color: ConclaveColors.warning,
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

/// Vector folder icon rendering clean line-art closed/open folder states.
class ConclaveFolderIcon extends StatelessWidget {
  const ConclaveFolderIcon({
    super.key,
    required this.isExpanded,
    this.size = 16,
    this.color,
  });

  final bool isExpanded;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color ?? Colors.white70;
    return CustomPaint(
      size: Size(size, size),
      painter: _FolderPainter(
        isExpanded: isExpanded,
        color: iconColor,
      ),
    );
  }
}

class _FolderPainter extends CustomPainter {
  const _FolderPainter({
    required this.isExpanded,
    required this.color,
  });

  final bool isExpanded;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale);

    if (!isExpanded) {
      // Clean modern closed folder stroke
      final path = Path()
        ..moveTo(3, 7)
        ..lineTo(3, 17)
        ..arcToPoint(const Offset(5, 19), radius: const Radius.circular(2))
        ..lineTo(19, 19)
        ..arcToPoint(const Offset(21, 17), radius: const Radius.circular(2))
        ..lineTo(21, 9)
        ..arcToPoint(const Offset(19, 7), radius: const Radius.circular(2))
        ..lineTo(13, 7)
        ..lineTo(11, 5)
        ..lineTo(5, 5)
        ..arcToPoint(const Offset(3, 7), radius: const Radius.circular(2))
        ..close();
      canvas.drawPath(path, paint);
    } else {
      // Clean modern open folder stroke with back tab and front open tray
      final backTab = Path()
        ..moveTo(4, 20)
        ..arcToPoint(const Offset(2, 18), radius: const Radius.circular(2))
        ..lineTo(2, 5)
        ..arcToPoint(const Offset(4, 3), radius: const Radius.circular(2))
        ..lineTo(7.9, 3)
        ..lineTo(9.6, 5)
        ..lineTo(18, 5)
        ..arcToPoint(const Offset(20, 7), radius: const Radius.circular(2))
        ..lineTo(20, 9);
      canvas.drawPath(backTab, paint);

      final frontTray = Path()
        ..moveTo(2, 18)
        ..lineTo(4.5, 10.5)
        ..arcToPoint(const Offset(6.5, 9.5), radius: const Radius.circular(1.5))
        ..lineTo(20, 9.5)
        ..arcToPoint(const Offset(21.8, 11.5),
            radius: const Radius.circular(1.5))
        ..lineTo(19.8, 17.8)
        ..arcToPoint(const Offset(18, 19.8), radius: const Radius.circular(1.8))
        ..lineTo(4, 19.8)
        ..arcToPoint(const Offset(2, 18), radius: const Radius.circular(1.8))
        ..close();
      canvas.drawPath(frontTray, paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_FolderPainter oldDelegate) =>
      oldDelegate.isExpanded != isExpanded || oldDelegate.color != color;
}

import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';
import 'studio_shell_context.dart';

/// Canonical Navigation Sidebar for Conclave AX.
class StudioSidebar extends StatelessWidget {
  const StudioSidebar({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onToggleProjectExpanded,
    required this.onCreateProject,
    required this.onLogout,
    required this.onOpenAbout,
    required this.onOpenExternal,
    this.compact = false,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final ValueChanged<String> onToggleProjectExpanded;
  final VoidCallback onCreateProject;
  final VoidCallback onLogout;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (sidebarContext) => Container(
        width: compact ? double.infinity : 240,
        color: ConclaveBrand.navigation,
        padding: const EdgeInsets.fromLTRB(10, 16, 10, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Brand header
            InkWell(
              onTap: onOpenAbout,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: ConclaveBrand.brandMark,
                      alignment: Alignment.center,
                      child: const Text(
                        'C',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text(
                        'Conclave AX',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          letterSpacing: -.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            // Top-level Navigation: Home
            _navItem(
              icon: Icons.home_outlined,
              label: 'Home',
              target: const StudioNavigation.home(),
              context: sidebarContext,
            ),
            const SizedBox(height: 16),

            // Navigation Sections
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // PROJECTS Section Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 2, 4),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'PROJECTS',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Create Project',
                            icon: const Icon(Icons.add_rounded, size: 16),
                            color: Colors.white60,
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints(minWidth: 22, minHeight: 22),
                            splashRadius: 14,
                            onPressed: onCreateProject,
                          ),
                        ],
                      ),
                    ),
                    if (shellContext.projects.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        child: Text(
                          'No projects yet',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    ...shellContext.projects
                        .map((project) => _projectItem(project, sidebarContext)),
                    const SizedBox(height: 16),

                    // EXECUTION Section Header
                    _sectionHeader('EXECUTION'),
                    _navItem(
                      icon: Icons.computer_outlined,
                      label: 'Workspaces',
                      target: const StudioNavigation.hosts(),
                      badge: shellContext.workspaces.isNotEmpty
                          ? '${shellContext.workspaces.length}'
                          : null,
                      context: sidebarContext,
                    ),
                    _navItem(
                      icon: Icons.extension_outlined,
                      label: 'Workers',
                      target: const StudioNavigation.workers(),
                      badge: shellContext.workers.isNotEmpty
                          ? '${shellContext.workers.length}'
                          : null,
                      context: sidebarContext,
                    ),
                    _navItem(
                      icon: Icons.account_circle_outlined,
                      label: 'AI Accounts',
                      target: const StudioNavigation.accounts(),
                      badge: shellContext.accounts.isNotEmpty
                          ? '${shellContext.accounts.length}'
                          : null,
                      context: sidebarContext,
                    ),
                    const SizedBox(height: 16),

                    // INSIGHTS Section Header
                    _sectionHeader('INSIGHTS'),
                    _navItem(
                      icon: Icons.analytics_outlined,
                      label: 'Usage',
                      target: const StudioNavigation.usage(),
                      context: sidebarContext,
                    ),
                  ],
                ),
              ),
            ),

            if (compact)
              _navItem(
                icon: Icons.close_rounded,
                label: 'Close menu',
                target: null,
                context: sidebarContext,
              ),

            _navItem(
              icon: Icons.person_outline_rounded,
              label: 'Profile & Security',
              target: const StudioNavigation.profileSecurity(),
              context: sidebarContext,
            ),
            const SizedBox(height: 6),

            // Viewer / Profile Row
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: const Color(0xffd8d2ff),
                  child: Text(
                    shellContext.viewerInitials,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Color(0xff4238a0),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    shellContext.viewerDisplayName ??
                        shellContext.viewerEmail ??
                        'Not signed in',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Account menu',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 28),
                  onSelected: (value) {
                    if (value == 'logout') onLogout();
                    if (value == 'about') onOpenAbout();
                    if (value == 'website') {
                      onOpenExternal(Uri.parse('https://conclaveax.com'));
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                        value: 'about', child: Text('About Conclave AX')),
                    PopupMenuItem(value: 'website', child: Text('Website')),
                    PopupMenuItem(value: 'logout', child: Text('Log out')),
                  ],
                  icon: const Icon(Icons.more_horiz,
                      color: Colors.white38, size: 16),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 0, 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _navItem({
    required IconData icon,
    required String label,
    required StudioNavigation? target,
    String? badge,
    required BuildContext context,
  }) {
    final active = shellContext.isNavActive(target);
    return InkWell(
      onTap: () {
        if (target != null) {
          onNavigateTo(target);
          if (compact) {
            Scaffold.maybeOf(context)?.closeDrawer();
          }
        } else if (compact) {
          Scaffold.maybeOf(context)?.closeDrawer();
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: active ? const Color(0xff302d4b) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: active ? const Color(0xffbcb3ff) : Colors.white54,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white60,
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (badge != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: const Color(0xff6254d9),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(color: Colors.white, fontSize: 9.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _projectItem(StudioProject project, BuildContext context) {
    final isProjectFocused =
        shellContext.navigation.projectId == project.id &&
            shellContext.navigation.kind == StudioRouteKind.project;
    final isExpanded = shellContext.isProjectExpanded(project.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            onNavigateTo(StudioNavigation.project(project.id));
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.fromLTRB(4, 5, 8, 5),
            decoration: BoxDecoration(
              color: isProjectFocused
                  ? const Color(0xff29283c)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                InkWell(
                  onTap: () => onToggleProjectExpanded(project.id),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      isExpanded
                          ? Icons.expand_more_rounded
                          : Icons.chevron_right_rounded,
                      size: 16,
                      color: Colors.white54,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    project.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isProjectFocused ? Colors.white : Colors.white70,
                      fontSize: 12,
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
        if (isExpanded)
          ...project.workstreams.map(
            (workstream) {
              final isWorkstreamSelected =
                  shellContext.navigation.workstreamId == workstream.id;
              final statusColor = _statusColor(workstream.status);

              return InkWell(
                onTap: () {
                  onNavigateTo(StudioNavigation.workstream(
                      project.id, workstream.id));
                  if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 1),
                  padding: const EdgeInsets.fromLTRB(28, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: isWorkstreamSelected
                        ? const Color(0xff302d4b)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
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
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'running':
      case 'executing':
        return const Color(0xff8c7dfd);
      case 'active':
      case 'queued':
      case 'ready':
        return const Color(0xff43b17f);
      case 'blocked':
      case 'failed':
        return const Color(0xffff6b6b);
      case 'completed':
      case 'done':
        return const Color(0xff70d6a5);
      default:
        return Colors.white38;
    }
  }
}

/// Compact Icon Rail when shell is collapsed or on tablet.
class StudioIconRail extends StatelessWidget {
  const StudioIconRail({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onOpenDrawer,
    required this.onLogout,
    required this.onOpenAbout,
    required this.onOpenExternal,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final VoidCallback onOpenDrawer;
  final VoidCallback onLogout;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      color: ConclaveBrand.navigation,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
      child: Column(
        children: [
          Tooltip(
            message: 'Conclave AX',
            child: InkWell(
              onTap: onOpenAbout,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 32,
                height: 32,
                decoration: ConclaveBrand.brandMark,
                alignment: Alignment.center,
                child: const Text(
                  'C',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _railItem(Icons.home_outlined, 'Home', const StudioNavigation.home()),
          _railItem(Icons.folder_outlined, 'Projects',
              const StudioNavigation.projects()),
          _railItem(Icons.computer_outlined, 'Workspaces',
              const StudioNavigation.hosts()),
          _railItem(Icons.extension_outlined, 'Workers',
              const StudioNavigation.workers()),
          _railItem(Icons.account_circle_outlined, 'AI Accounts',
              const StudioNavigation.accounts()),
          _railItem(Icons.analytics_outlined, 'Usage',
              const StudioNavigation.usage()),
          const Spacer(),
          Tooltip(
            message: 'Open project tree & menu',
            child: IconButton(
              icon: const Icon(Icons.menu_rounded,
                  color: Colors.white60, size: 20),
              onPressed: onOpenDrawer,
            ),
          ),
          const SizedBox(height: 6),
          _railItem(Icons.person_outline_rounded, 'Profile & Security',
              const StudioNavigation.profileSecurity()),
          const SizedBox(height: 6),
          PopupMenuButton<String>(
            tooltip: 'Account menu',
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == 'logout') onLogout();
              if (value == 'about') onOpenAbout();
              if (value == 'website') {
                onOpenExternal(Uri.parse('https://conclaveax.com'));
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'about', child: Text('About Conclave AX')),
              PopupMenuItem(value: 'website', child: Text('Website')),
              PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
            child: CircleAvatar(
              radius: 14,
              backgroundColor: const Color(0xffd8d2ff),
              child: Text(
                shellContext.viewerInitials,
                style: const TextStyle(
                  fontSize: 9,
                  color: Color(0xff4238a0),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _railItem(IconData icon, String label, StudioNavigation target) {
    final active = shellContext.isNavActive(target);
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: () => onNavigateTo(target),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 40,
          height: 36,
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: active ? const Color(0xff302d4b) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 18,
            color: active ? const Color(0xffbcb3ff) : Colors.white54,
          ),
        ),
      ),
    );
  }
}

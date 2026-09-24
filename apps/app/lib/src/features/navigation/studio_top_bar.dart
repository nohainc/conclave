import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import 'execution_status_popover.dart';
import 'studio_shell_context.dart';

/// Canonical Top Application Header Bar (HUD) for Conclave AX.
class StudioTopBar extends StatelessWidget implements PreferredSizeWidget {
  const StudioTopBar({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onOpenCommandPalette,
    required this.onOpenNotifications,
    this.onToggleTheme,
    this.onOpenAbout,
    this.onLogout,
    this.onOpenExternal,
    this.compact = false,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final VoidCallback onOpenCommandPalette;
  final VoidCallback onOpenNotifications;
  final VoidCallback? onToggleTheme;
  final VoidCallback? onOpenAbout;
  final VoidCallback? onLogout;
  final ValueChanged<Uri>? onOpenExternal;
  final bool compact;

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor =
        isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;
    final inkColor = isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk;
    final mutedInk =
        isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted;

    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 800 && !compact;
    final isMedium = screenWidth >= 600 && screenWidth < 800 && !compact;

    return Container(
      height: 60,
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
      decoration: BoxDecoration(
        color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // Drawer opener on compact screens
          if (compact) ...[
            Builder(
              builder: (innerContext) => IconButton(
                onPressed: () => Scaffold.of(innerContext).openDrawer(),
                icon: Icon(Icons.menu_rounded, color: inkColor),
                tooltip: 'Open menu',
                splashRadius: 20,
              ),
            ),
            const SizedBox(width: 4),
          ],

          // Breadcrumbs
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: _buildBreadcrumbs(inkColor, mutedInk),
              ),
            ),
          ),

          // Search / Jump to bar responsive affordance
          if (isDesktop) ...[
            InkWell(
              onTap: onOpenCommandPalette,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark
                      ? ConclaveBrand.darkPaper
                      : ConclaveBrand.lightPaper,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 16,
                      color: mutedInk,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Search or jump to...',
                      style: TextStyle(
                        fontSize: 12,
                        color: mutedInk,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark
                            ? ConclaveBrand.darkSurface
                            : ConclaveBrand.lightSurface,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: borderColor),
                      ),
                      child: Text(
                        '⌘K',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: mutedInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
          ] else if (isMedium) ...[
            InkWell(
              onTap: onOpenCommandPalette,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark
                      ? ConclaveBrand.darkPaper
                      : ConclaveBrand.lightPaper,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 16,
                      color: mutedInk,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Search',
                      style: TextStyle(
                        fontSize: 12,
                        color: mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
          ] else ...[
            IconButton(
              icon: Icon(Icons.search_rounded, size: 20, color: mutedInk),
              tooltip: 'Search (⌘K)',
              onPressed: onOpenCommandPalette,
              splashRadius: 20,
            ),
          ],

          // Execution Status Popover Trigger
          if (!compact) ...[
            OutlinedButton.icon(
              onPressed: () => _openExecutionStatusPopover(context),
              icon: Icon(
                Icons.circle,
                size: 7,
                color: shellContext.executionStatusTone.color(isDark),
              ),
              label: Text(
                shellContext.executionStatusLabel,
                style: const TextStyle(fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: inkColor,
                side: BorderSide(color: borderColor),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                minimumSize: Size.zero,
              ),
            ),
            const SizedBox(width: 8),
          ] else ...[
            IconButton(
              tooltip: shellContext.executionStatusLabel,
              onPressed: () => _openExecutionStatusPopover(context),
              icon: Icon(
                Icons.circle,
                size: 8,
                color: shellContext.executionStatusTone.color(isDark),
              ),
              splashRadius: 18,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
            const SizedBox(width: 4),
          ],

          // Notifications Bell
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                tooltip: 'Notifications',
                onPressed: onOpenNotifications,
                icon: Icon(Icons.notifications_none_rounded,
                    size: 21, color: mutedInk),
                splashRadius: 20,
              ),
              if (shellContext.unreadNotificationCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Semantics(
                    label:
                        '${shellContext.unreadNotificationCount} unread notifications',
                    child: Container(
                      constraints:
                          const BoxConstraints(minWidth: 15, minHeight: 15),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: const BoxDecoration(
                        color: ConclaveBrand.accent,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        shellContext.unreadNotificationCount > 9
                            ? '9+'
                            : '${shellContext.unreadNotificationCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // Mobile / Compact Account & Avatar menu
          if (compact) ...[
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: 'Account menu',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 190),
              onSelected: (value) {
                if (value == 'profile') {
                  onNavigateTo(const StudioNavigation.profileSecurity());
                }
                if (value == 'theme') onToggleTheme?.call();
                if (value == 'about') onOpenAbout?.call();
                if (value == 'website') {
                  onOpenExternal?.call(Uri.parse('https://conclaveax.com'));
                }
                if (value == 'logout') onLogout?.call();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'profile',
                  child: Row(
                    children: [
                      const Icon(Icons.person_outline_rounded, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        shellContext.viewerDisplayName ??
                            shellContext.viewerEmail ??
                            'Profile & Security',
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'theme',
                  child: Row(
                    children: [
                      Icon(
                        shellContext.isDarkTheme
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        shellContext.isDarkTheme
                            ? 'Switch to light mode'
                            : 'Switch to dark mode',
                      ),
                    ],
                  ),
                ),
                if (onOpenAbout != null)
                  const PopupMenuItem(
                    value: 'about',
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded, size: 16),
                        SizedBox(width: 8),
                        Text('About Conclave AX'),
                      ],
                    ),
                  ),
                if (onOpenExternal != null)
                  const PopupMenuItem(
                    value: 'website',
                    child: Row(
                      children: [
                        Icon(Icons.open_in_new_rounded, size: 16),
                        SizedBox(width: 8),
                        Text('Website'),
                      ],
                    ),
                  ),
                if (onLogout != null) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(Icons.logout_rounded, size: 16),
                        SizedBox(width: 8),
                        Text('Log out'),
                      ],
                    ),
                  ),
                ],
              ],
              child: CircleAvatar(
                radius: 13,
                backgroundColor: isDark
                    ? ConclaveBrand.accentWashDark
                    : const Color(0xffd8d2ff),
                child: Text(
                  shellContext.viewerInitials,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: isDark
                        ? ConclaveBrand.accent
                        : const Color(0xff4238a0),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildBreadcrumbs(Color inkColor, Color mutedInk) {
    final nav = shellContext.navigation;
    final project = shellContext.selectedProject;
    final workstream = shellContext.selectedWorkstream;

    switch (nav.kind) {
      case StudioRouteKind.home:
        return [
          _breadcrumbText('Home', isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.projects:
        return [
          _breadcrumbText('Projects', isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.project:
        final name = project?.name ?? 'Project';
        return [
          _breadcrumbLink(
            'Projects',
            () => onNavigateTo(const StudioNavigation.projects()),
            mutedInk: mutedInk,
          ),
          _divider(mutedInk),
          _breadcrumbText(name, isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.workstream:
        final projectName = project?.name ?? 'Project';
        final workstreamName = workstream?.name ?? 'Workstream';
        return [
          if (compact) ...[
            _breadcrumbLink(
              '…',
              () => project != null
                  ? onNavigateTo(StudioNavigation.project(project.id))
                  : onNavigateTo(const StudioNavigation.projects()),
              mutedInk: mutedInk,
              tooltip: projectName,
            ),
            _divider(mutedInk),
          ] else ...[
            if (project != null) ...[
              _breadcrumbLink(
                projectName,
                () => onNavigateTo(StudioNavigation.project(project.id)),
                mutedInk: mutedInk,
              ),
              _divider(mutedInk),
            ] else ...[
              _breadcrumbLink(
                'Projects',
                () => onNavigateTo(const StudioNavigation.projects()),
                mutedInk: mutedInk,
              ),
              _divider(mutedInk),
            ],
          ],
          _breadcrumbText(workstreamName,
              isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.run:
        final projectName = project?.name ?? 'Project';
        final workstreamName = workstream?.name ?? 'Workstream';
        final workstreamId = workstream?.id ?? nav.workstreamId;
        return [
          if (compact) ...[
            _breadcrumbLink(
              '…',
              () => (workstreamId != null && project != null)
                  ? onNavigateTo(
                      StudioNavigation.workstream(project.id, workstreamId))
                  : onNavigateTo(const StudioNavigation.projects()),
              mutedInk: mutedInk,
              tooltip: workstreamName,
            ),
            _divider(mutedInk),
          ] else ...[
            if (project != null) ...[
              _breadcrumbLink(
                projectName,
                () => onNavigateTo(StudioNavigation.project(project.id)),
                mutedInk: mutedInk,
              ),
              _divider(mutedInk),
            ] else ...[
              _breadcrumbLink(
                'Projects',
                () => onNavigateTo(const StudioNavigation.projects()),
                mutedInk: mutedInk,
              ),
              _divider(mutedInk),
            ],
            if (workstreamId != null && project != null) ...[
              _breadcrumbLink(
                workstreamName,
                () => onNavigateTo(
                    StudioNavigation.workstream(project.id, workstreamId)),
                mutedInk: mutedInk,
              ),
              _divider(mutedInk),
            ],
          ],
          _breadcrumbText('Run', isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.hosts:
        return [
          _breadcrumbText('Workspaces', isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.workers:
        return [
          _breadcrumbText('Workers', isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.accounts:
        return [
          _breadcrumbText('AI Accounts', isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.usage:
        return [
          _breadcrumbText('Usage', isCurrent: true, inkColor: inkColor),
        ];

      case StudioRouteKind.profileSecurity:
        return [
          _breadcrumbText('Profile & Security',
              isCurrent: true, inkColor: inkColor),
        ];

      default:
        return [
          _breadcrumbText('Conclave AX', isCurrent: true, inkColor: inkColor),
        ];
    }
  }

  Widget _breadcrumbText(String text,
      {required bool isCurrent, required Color inkColor}) {
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

  Widget _breadcrumbLink(
    String text,
    VoidCallback onTap, {
    required Color mutedInk,
    String? tooltip,
  }) {
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

  Widget _divider(Color mutedInk) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '/',
        style: TextStyle(fontSize: 13, color: mutedInk),
      ),
    );
  }

  void _openExecutionStatusPopover(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (dialogContext) => ExecutionStatusPopover(
        shellContext: shellContext,
        onNavigateTo: onNavigateTo,
      ),
    );
  }
}

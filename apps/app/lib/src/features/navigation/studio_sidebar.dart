import 'package:flutter/material.dart';
import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';

/// Navigation Sidebar and Drawer for Conclave AX
class StudioSidebar extends StatelessWidget {
  const StudioSidebar({
    super.key,
    required this.snapshot,
    required this.selectedProjectId,
    required this.selectedChatId,
    required this.onSelectProject,
    required this.onSelectChat,
    required this.routeKind,
    required this.onNavigateTo,
    required this.expandedProjectIds,
    required this.onToggleProjectExpanded,
    required this.onNewGoal,
  });

  final StudioSnapshot snapshot;
  final String? selectedProjectId;
  final String? selectedChatId;
  final ValueChanged<String> onSelectProject;
  final void Function(String projectId, String chatId) onSelectChat;
  final StudioRouteKind routeKind;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final Set<String> expandedProjectIds;
  final ValueChanged<String> onToggleProjectExpanded;
  final VoidCallback onNewGoal;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface;
    final borderColor =
        isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // New Goal CTA
          Padding(
            padding: const EdgeInsets.all(12),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('New goal',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: ConclaveBrand.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: onNewGoal,
            ),
          ),
          // Navigation Sections
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                const _NavSectionHeader(title: 'EXECUTION'),
                _NavItem(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: 'Conversation',
                  isSelected: {
                    StudioRouteKind.home,
                    StudioRouteKind.projects,
                    StudioRouteKind.project,
                    StudioRouteKind.chat,
                  }.contains(routeKind),
                  onTap: () => onNavigateTo(const StudioNavigation.home()),
                ),
                _NavItem(
                  icon: Icons.dns_outlined,
                  label: 'Hosts',
                  isSelected: routeKind == StudioRouteKind.hosts,
                  badge: '${snapshot.hosts.length}',
                  onTap: () => onNavigateTo(const StudioNavigation.hosts()),
                ),
                _NavItem(
                  icon: Icons.extension_outlined,
                  label: 'Workers',
                  isSelected: routeKind == StudioRouteKind.workers,
                  badge: '${snapshot.workers.length}',
                  onTap: () => onNavigateTo(const StudioNavigation.workers()),
                ),
                _NavItem(
                  icon: Icons.key_outlined,
                  label: 'Accounts',
                  isSelected: routeKind == StudioRouteKind.accounts,
                  badge: '${snapshot.accounts.length}',
                  onTap: () => onNavigateTo(const StudioNavigation.accounts()),
                ),
                const SizedBox(height: 16),
                const _NavSectionHeader(title: 'PROJECTS & CHATS'),
                if (snapshot.projects.isEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(
                      'No projects yet',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? ConclaveBrand.darkInkMuted
                            : ConclaveBrand.lightInkMuted,
                      ),
                    ),
                  ),
                ...snapshot.projects.map((project) {
                  final isExpanded = expandedProjectIds.contains(project.id);
                  final isProjectSelected = project.id == selectedProjectId;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Project Item
                      InkWell(
                        onTap: () {
                          onSelectProject(project.id);
                          onToggleProjectExpanded(project.id);
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(
                            color: isProjectSelected &&
                                    {
                                      StudioRouteKind.home,
                                      StudioRouteKind.projects,
                                      StudioRouteKind.project,
                                      StudioRouteKind.chat,
                                    }.contains(routeKind)
                                ? (isDark
                                    ? ConclaveBrand.darkSurfaceHover
                                    : ConclaveBrand.lightSurfaceHover)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isExpanded
                                    ? Icons.folder_open_rounded
                                    : Icons.folder_rounded,
                                size: 16,
                                color: isProjectSelected
                                    ? ConclaveBrand.accent
                                    : (isDark
                                        ? ConclaveBrand.darkInkMuted
                                        : ConclaveBrand.lightInkMuted),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  project.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: isProjectSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isDark
                                        ? ConclaveBrand.darkInk
                                        : ConclaveBrand.lightInk,
                                  ),
                                ),
                              ),
                              Icon(
                                isExpanded
                                    ? Icons.expand_more_rounded
                                    : Icons.chevron_right_rounded,
                                size: 16,
                                color: isDark
                                    ? ConclaveBrand.darkInkMuted
                                    : ConclaveBrand.lightInkMuted,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Project Chats
                      if (isExpanded)
                        Padding(
                          padding: const EdgeInsets.only(
                              left: 20, top: 2, bottom: 4),
                          child: Column(
                            children: project.chats.map((chat) {
                              final isChatSelected = chat.id == selectedChatId;
                              return InkWell(
                                onTap: () {
                                  onSelectChat(project.id, chat.id);
                                  onNavigateTo(const StudioNavigation.home());
                                },
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isChatSelected &&
                                            {
                                              StudioRouteKind.home,
                                              StudioRouteKind.projects,
                                              StudioRouteKind.project,
                                              StudioRouteKind.chat,
                                            }.contains(routeKind)
                                        ? (isDark
                                            ? ConclaveBrand.accentWashDark
                                            : ConclaveBrand.accentWash)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.chat_bubble_outline_rounded,
                                        size: 13,
                                        color: isChatSelected
                                            ? ConclaveBrand.accent
                                            : (isDark
                                                ? ConclaveBrand.darkInkMuted
                                                : ConclaveBrand.lightInkMuted),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          chat.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: isChatSelected
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color: isChatSelected
                                                ? ConclaveBrand.accent
                                                : (isDark
                                                    ? ConclaveBrand.darkInk
                                                    : ConclaveBrand.lightInk),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavSectionHeader extends StatelessWidget {
  const _NavSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color:
              isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    this.badge,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark
                  ? ConclaveBrand.accentWashDark
                  : ConclaveBrand.accentWash)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: isSelected
                  ? ConclaveBrand.accent
                  : (isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? ConclaveBrand.accent
                      : (isDark
                          ? ConclaveBrand.darkInk
                          : ConclaveBrand.lightInk),
                ),
              ),
            ),
            if (badge != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: isSelected
                      ? ConclaveBrand.accent
                      : (isDark
                          ? ConclaveBrand.darkLine
                          : ConclaveBrand.lightLine),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge!,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Colors.white
                        : (isDark
                            ? ConclaveBrand.darkInkMuted
                            : ConclaveBrand.lightInkMuted),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

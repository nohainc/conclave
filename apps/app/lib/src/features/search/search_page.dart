import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';
import '../common/command_palette.dart';

/// Full-page search view rendered in the main workspace content area.
class SearchPage extends StatelessWidget {
  const SearchPage({
    super.key,
    required this.query,
    required this.snapshot,
    required this.onNavigateTo,
    required this.onSelectProject,
    required this.onSelectChat,
    required this.onClearSearch,
    this.onToggleTheme,
    this.onNewGoal,
  });

  final String query;
  final StudioSnapshot snapshot;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final ValueChanged<String> onSelectProject;
  final void Function(String projectId, String chatId) onSelectChat;
  final VoidCallback onClearSearch;
  final VoidCallback? onToggleTheme;
  final VoidCallback? onNewGoal;

  List<CommandPaletteAction> _buildAllActions(BuildContext context) {
    final actions = <CommandPaletteAction>[
      // Navigation Actions
      CommandPaletteAction(
        title: 'Home',
        subtitle: 'Overview, recent activity, and system status',
        icon: Icons.home_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.home());
        },
      ),
      CommandPaletteAction(
        title: 'Workspaces',
        subtitle: 'Manage local and remote machines',
        icon: Icons.computer_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.hosts());
        },
      ),
      CommandPaletteAction(
        title: 'Workers',
        subtitle: 'View worker catalog and capabilities',
        icon: Icons.extension_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.workers());
        },
      ),
      CommandPaletteAction(
        title: 'AI Accounts',
        subtitle: 'Credential profiles and authorization',
        icon: Icons.account_circle_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.accounts());
        },
      ),
      CommandPaletteAction(
        title: 'Usage',
        subtitle: 'Token usage, cost analytics, and quotas',
        icon: Icons.analytics_outlined,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.usage());
        },
      ),
      CommandPaletteAction(
        title: 'Profile & Security',
        subtitle: 'Profile, passkeys, and account settings',
        icon: Icons.person_outline_rounded,
        category: 'Navigation',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.profileSecurity());
        },
      ),
    ];

    if (onToggleTheme != null) {
      actions.add(CommandPaletteAction(
        title: 'Toggle Theme',
        subtitle: 'Switch between light and dark modes',
        icon: Icons.dark_mode_outlined,
        category: 'Actions',
        onSelect: () {
          onClearSearch();
          onToggleTheme!();
        },
      ));
    }

    if (onNewGoal != null) {
      actions.add(CommandPaletteAction(
        title: 'New Work Request',
        subtitle: 'Create a new automated work request',
        icon: Icons.add_task_rounded,
        category: 'Actions',
        onSelect: () {
          onClearSearch();
          onNewGoal!();
        },
      ));
    }

    // Projects & Workstreams & Chats
    for (final project in snapshot.projects) {
      actions.add(CommandPaletteAction(
        title: project.name,
        subtitle: project.repository.isNotEmpty
            ? project.repository
            : (project.description.isNotEmpty
                ? project.description
                : 'Project'),
        icon: Icons.folder_outlined,
        category: 'Projects',
        onSelect: () {
          onClearSearch();
          onSelectProject(project.id);
        },
      ));

      for (final workstream in project.workstreams) {
        actions.add(CommandPaletteAction(
          title: workstream.name,
          subtitle: '${project.name} · ${workstream.status}',
          icon: Icons.alt_route_rounded,
          category: 'Workstreams',
          onSelect: () {
            onClearSearch();
            onNavigateTo(StudioNavigation.workstream(project.id, workstream.id));
          },
        ));
      }

      for (final chat in project.chats) {
        actions.add(CommandPaletteAction(
          title: chat.title,
          subtitle: 'in ${project.name}',
          icon: Icons.chat_bubble_outline_rounded,
          category: 'Chats',
          onSelect: () {
            onClearSearch();
            onSelectChat(project.id, chat.id);
          },
        ));
      }
    }

    // Active Run
    final activeRun = snapshot.run;
    if (activeRun != null) {
      final projectId = snapshot.projects.firstOrNull?.id ?? '';
      actions.add(CommandPaletteAction(
        title: activeRun.objective.isNotEmpty
            ? activeRun.objective
            : 'Active Run: ${activeRun.id}',
        subtitle:
            '${activeRun.status.name} · ${activeRun.completedTaskCount}/${activeRun.taskCount} tasks',
        icon: Icons.play_circle_outline_rounded,
        category: 'Runs',
        onSelect: () {
          onClearSearch();
          onNavigateTo(StudioNavigation.run(
            projectId,
            activeRun.id,
            workstreamId: activeRun.workstreamId,
          ));
        },
      ));
    }

    // Workspaces / Agents
    for (final agent in snapshot.agents) {
      actions.add(CommandPaletteAction(
        title: agent.name,
        subtitle: '${agent.hostname} · ${agent.status}',
        icon: Icons.computer_outlined,
        category: 'Workspaces',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.hosts());
        },
      ));
    }

    // Workers
    for (final worker in snapshot.workers) {
      actions.add(CommandPaletteAction(
        title: worker.name,
        subtitle: '${worker.provider} · ${worker.role}',
        icon: Icons.extension_outlined,
        category: 'Workers',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.workers());
        },
      ));
    }

    // Accounts
    for (final account in snapshot.accounts) {
      actions.add(CommandPaletteAction(
        title: account.displayName,
        subtitle: '${account.worker} · ${account.status}',
        icon: Icons.account_circle_outlined,
        category: 'Accounts',
        onSelect: () {
          onClearSearch();
          onNavigateTo(const StudioNavigation.accounts());
        },
      ));
    }

    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return actions;

    return actions.where((action) {
      final matchesTitle = action.title.toLowerCase().contains(trimmed);
      final matchesSubtitle =
          action.subtitle?.toLowerCase().contains(trimmed) ?? false;
      final matchesCategory = action.category.toLowerCase().contains(trimmed);
      return matchesTitle || matchesSubtitle || matchesCategory;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final results = _buildAllActions(context);

    // Group results by category
    final grouped = <String, List<CommandPaletteAction>>{};
    for (final action in results) {
      grouped.putIfAbsent(action.category, () => []).add(action);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search Header
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xff29273c)
                              : const Color(0xffede9fe),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.search_rounded,
                          size: 22,
                          color: isDark
                              ? const Color(0xffa78bfa)
                              : ConclaveBrand.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Search Results',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.4,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    query.trim().isEmpty
                        ? 'Showing all items across Conclave AX'
                        : 'Found ${results.length} ${results.length == 1 ? "result" : "results"} for "${query.trim()}"',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : const Color(0xff64748b),
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: onClearSearch,
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('Clear Search'),
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark ? Colors.white70 : const Color(0xff475569),
                side: BorderSide(
                  color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Results or Empty State
        if (results.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
            decoration: BoxDecoration(
              color: isDark
                  ? ConclaveBrand.darkSurface
                  : ConclaveBrand.lightSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_off_rounded,
                  size: 48,
                  color: isDark ? Colors.white30 : const Color(0xff94a3b8),
                ),
                const SizedBox(height: 16),
                Text(
                  'No results found for "${query.trim()}"',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Try searching for project names, workstreams, workers, or navigation destinations.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : const Color(0xff64748b),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onClearSearch,
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('Back to previous page'),
                  style: FilledButton.styleFrom(
                    backgroundColor: ConclaveBrand.accent,
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in grouped.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 10),
                  child: Row(
                    children: [
                      Text(
                        entry.key.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: isDark
                              ? const Color(0xff94a3b8)
                              : const Color(0xff64748b),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xff29283c)
                              : const Color(0xfff1f5f9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${entry.value.length}',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white60
                                : const Color(0xff64748b),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: entry.value.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final item = entry.value[index];
                    return _SearchResultTile(
                      action: item,
                      isDark: isDark,
                    );
                  },
                ),
                const SizedBox(height: 18),
              ],
            ],
          ),
      ],
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.action,
    required this.isDark,
  });

  final CommandPaletteAction action;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: action.onSelect,
      borderRadius: BorderRadius.circular(10),
      hoverColor: isDark ? const Color(0xff252438) : const Color(0xfff8fafc),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isDark
              ? ConclaveBrand.darkSurface
              : ConclaveBrand.lightSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xff201f30)
                    : const Color(0xfff1f5f9),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDark
                      ? ConclaveBrand.darkLine
                      : ConclaveBrand.lightLine,
                ),
              ),
              child: Icon(
                action.icon,
                size: 18,
                color: isDark ? Colors.white70 : const Color(0xff475569),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xff0f172a),
                    ),
                  ),
                  if (action.subtitle != null && action.subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      action.subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? Colors.white54
                            : const Color(0xff64748b),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xff252438)
                    : const Color(0xfff1f5f9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                action.category,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white60 : const Color(0xff64748b),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: isDark ? Colors.white30 : const Color(0xff94a3b8),
            ),
          ],
        ),
      ),
    );
  }
}

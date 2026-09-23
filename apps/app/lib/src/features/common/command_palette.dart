import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';

/// Item in the command palette search results
class CommandPaletteAction {
  const CommandPaletteAction({
    required this.title,
    this.subtitle,
    required this.icon,
    required this.onSelect,
    this.category = 'General',
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onSelect;
  final String category;
}

/// Global Command Palette Modal Dialog (`Cmd+K` / `Ctrl+K`)
class CommandPaletteDialog extends StatefulWidget {
  const CommandPaletteDialog({
    super.key,
    required this.snapshot,
    required this.onSelectProject,
    required this.onSelectChat,
    required this.onNavigateTo,
    required this.onToggleTheme,
    required this.onNewGoal,
  });

  final StudioSnapshot snapshot;
  final ValueChanged<String> onSelectProject;
  final void Function(String projectId, String chatId) onSelectChat;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final VoidCallback onToggleTheme;
  final VoidCallback onNewGoal;

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  final _searchController = TextEditingController();
  String _query = '';
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
        _highlightedIndex = 0;
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<CommandPaletteAction> _buildActions() {
    final actions = <CommandPaletteAction>[
      // Navigation Actions
      CommandPaletteAction(
        title: 'Open Hosts',
        subtitle: 'Manage local and remote machines',
        icon: Icons.dns_outlined,
        category: 'Navigation',
        onSelect: () {
          Navigator.of(context).pop();
          widget.onNavigateTo(const StudioNavigation.hosts());
        },
      ),
      CommandPaletteAction(
        title: 'Open Workers',
        subtitle: 'View worker catalog and capabilities',
        icon: Icons.extension_outlined,
        category: 'Navigation',
        onSelect: () {
          Navigator.of(context).pop();
          widget.onNavigateTo(const StudioNavigation.workers());
        },
      ),
      CommandPaletteAction(
        title: 'Open Accounts',
        subtitle: 'Credential profiles and authorization',
        icon: Icons.key_outlined,
        category: 'Navigation',
        onSelect: () {
          Navigator.of(context).pop();
          widget.onNavigateTo(const StudioNavigation.accounts());
        },
      ),
      CommandPaletteAction(
        title: 'Account & Security',
        subtitle: 'Profile, Passkeys, and MFA settings',
        icon: Icons.person_outline_rounded,
        category: 'Navigation',
        onSelect: () {
          Navigator.of(context).pop();
          widget.onNavigateTo(const StudioNavigation.profileSecurity());
        },
      ),
      // Quick Actions
      CommandPaletteAction(
        title: 'New Goal',
        subtitle: 'Create a new orchestration goal',
        icon: Icons.add_circle_outline_rounded,
        category: 'Actions',
        onSelect: () {
          Navigator.of(context).pop();
          widget.onNewGoal();
        },
      ),
      CommandPaletteAction(
        title: 'Toggle Theme',
        subtitle: 'Switch between light and dark modes',
        icon: Icons.dark_mode_outlined,
        category: 'Actions',
        onSelect: () {
          Navigator.of(context).pop();
          widget.onToggleTheme();
        },
      ),
    ];

    // Add Projects
    for (final project in widget.snapshot.projects) {
      actions.add(CommandPaletteAction(
        title: 'Project: ${project.name}',
        subtitle:
            project.repository.isNotEmpty ? project.repository : project.branch,
        icon: Icons.folder_outlined,
        category: 'Projects',
        onSelect: () {
          Navigator.of(context).pop();
          widget.onSelectProject(project.id);
        },
      ));

      // Add Project Chats
      for (final chat in project.chats) {
        actions.add(CommandPaletteAction(
          title: 'Chat: ${chat.title}',
          subtitle: 'in ${project.name}',
          icon: Icons.chat_bubble_outline_rounded,
          category: 'Chats',
          onSelect: () {
            Navigator.of(context).pop();
            widget.onSelectChat(project.id, chat.id);
          },
        ));
      }
    }

    if (_query.isEmpty) return actions;

    return actions.where((action) {
      final matchesTitle = action.title.toLowerCase().contains(_query);
      final matchesSubtitle =
          action.subtitle?.toLowerCase().contains(_query) ?? false;
      final matchesCategory = action.category.toLowerCase().contains(_query);
      return matchesTitle || matchesSubtitle || matchesCategory;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final actions = _buildActions();

    return Dialog(
      backgroundColor:
          isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine),
      ),
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent || actions.isEmpty) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            setState(() =>
                _highlightedIndex = (_highlightedIndex + 1) % actions.length);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            setState(() => _highlightedIndex =
                (_highlightedIndex - 1 + actions.length) % actions.length);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter) {
            actions[_highlightedIndex].onSelect();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          width: 580,
          constraints: const BoxConstraints(maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search Input Header
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: TextStyle(
                    fontSize: 14,
                    color:
                        isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Type a command, project, or chat...',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: isDark
                            ? ConclaveBrand.darkLine
                            : ConclaveBrand.lightLine,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'ESC',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? ConclaveBrand.darkInkMuted
                              : ConclaveBrand.lightInkMuted,
                        ),
                      ),
                    ),
                    filled: true,
                    fillColor: isDark
                        ? ConclaveBrand.darkPaper
                        : ConclaveBrand.lightPaper,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              Divider(
                  height: 1,
                  color: isDark
                      ? ConclaveBrand.darkLine
                      : ConclaveBrand.lightLine),
              // Results List
              Flexible(
                child: actions.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No results found for "$_query"',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark
                                ? ConclaveBrand.darkInkMuted
                                : ConclaveBrand.lightInkMuted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: actions.length,
                        itemBuilder: (context, index) {
                          final action = actions[index];
                          return ListTile(
                            dense: true,
                            selected: index == _highlightedIndex,
                            selectedTileColor: isDark
                                ? ConclaveBrand.accentWashDark
                                : ConclaveBrand.accentWash,
                            leading: Icon(action.icon,
                                size: 18, color: ConclaveBrand.accent),
                            title: Text(
                              action.title,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: isDark
                                    ? ConclaveBrand.darkInk
                                    : ConclaveBrand.lightInk,
                              ),
                            ),
                            subtitle: action.subtitle != null
                                ? Text(
                                    action.subtitle!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? ConclaveBrand.darkInkMuted
                                          : ConclaveBrand.lightInkMuted,
                                    ),
                                  )
                                : null,
                            trailing: Text(
                              action.category,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: isDark
                                    ? ConclaveBrand.darkInkMuted
                                    : ConclaveBrand.lightInkMuted,
                              ),
                            ),
                            onTap: action.onSelect,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

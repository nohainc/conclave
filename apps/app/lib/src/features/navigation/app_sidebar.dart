import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';
import 'app_menu.dart';
import 'project_tree.dart';
import 'studio_shell_context.dart';

/// Canonical Application Sidebar for Conclave AX.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onToggleProjectExpanded,
    required this.onCreateProject,
    this.onCreateWorkstream,
    this.searchController,
    this.searchFocusNode,
    this.onSearchChanged,
    this.onClearSearch,
    this.onOpenCommandPalette,
    this.onOpenNotifications,
    this.onToggleTheme,
    this.onSetThemeMode,
    required this.onLogout,
    required this.onOpenAbout,
    required this.onOpenExternal,
    this.compact = false,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final ValueChanged<String> onToggleProjectExpanded;
  final VoidCallback onCreateProject;
  final ValueChanged<StudioProject>? onCreateWorkstream;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onClearSearch;
  final VoidCallback? onOpenCommandPalette;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback onLogout;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (sidebarContext) => Container(
        width: compact ? double.infinity : 248,
        color: ConclaveBrand.navigation,
        padding: const EdgeInsets.fromLTRB(10, 16, 10, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Brand header — clicking navigates to Home
            Tooltip(
              message: 'Conclave AX — Home',
              child: InkWell(
                onTap: () {
                  onNavigateTo(const StudioNavigation.home());
                  if (compact) {
                    Scaffold.maybeOf(sidebarContext)?.closeDrawer();
                  }
                },
                borderRadius: BorderRadius.circular(8),
                hoverColor: const Color(0xff29283c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ConclaveBrand.logoMark(size: 28),
                      const SizedBox(width: 10),
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
            ),
            const SizedBox(height: 10),

            // Search control, Add Project icon button & Notifications Alarm button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: 'Search or jump to... (⌘K)',
                      child: Container(
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xff181724),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xff2d2b40)),
                        ),
                        child: ListenableBuilder(
                          listenable:
                              searchController ?? TextEditingController(),
                          builder: (context, _) {
                            final hasText =
                                searchController?.text.isNotEmpty ?? false;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(left: 8, right: 4),
                                child: Icon(
                                  Icons.search_rounded,
                                  size: 15,
                                  color: Colors.white54,
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: searchController,
                                  focusNode: searchFocusNode,
                                  onChanged: onSearchChanged,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                  ),
                                  cursorColor: ConclaveBrand.accent,
                                  cursorHeight: 14,
                                  decoration: const InputDecoration(
                                    hintText: 'Search...',
                                    hintStyle: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white38,
                                    ),
                                    isDense: true,
                                    contentPadding:
                                        EdgeInsets.symmetric(vertical: 7),
                                    border: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    errorBorder: InputBorder.none,
                                    disabledBorder: InputBorder.none,
                                  ),
                                ),
                              ),
                              if (hasText)
                                InkWell(
                                  onTap: onClearSearch,
                                  borderRadius: BorderRadius.circular(10),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 4),
                                    child: Icon(
                                      Icons.close_rounded,
                                      size: 14,
                                      color: Colors.white54,
                                    ),
                                  ),
                                )
                              else
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Text(
                                    '⌘K',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white24,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                  Tooltip(
                    message: 'New Project',
                    child: IconButton(
                      onPressed: onCreateProject,
                      icon: const Icon(
                        Icons.add_rounded,
                        size: 18,
                        color: Colors.white60,
                      ),
                      splashRadius: 14,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xff181724),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xff2d2b40)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'Notifications',
                    child: IconButton(
                      onPressed: onOpenNotifications,
                      icon: const Icon(
                        Icons.notifications_none_rounded,
                        size: 18,
                        color: Colors.white60,
                      ),
                      splashRadius: 14,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xff181724),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xff2d2b40)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Navigation Centerpiece: Full Project Tree
            Expanded(
              child: SingleChildScrollView(
                child: ProjectTree(
                  shellContext: shellContext,
                  onNavigateTo: onNavigateTo,
                  onToggleProjectExpanded: onToggleProjectExpanded,
                  onCreateProject: onCreateProject,
                  onCreateWorkstream: onCreateWorkstream,
                  compact: compact,
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

            const SizedBox(height: 6),

            // Bottom Profile Button + ⋯ Global Application Menu
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: 'Profile & Settings',
                    waitDuration: const Duration(milliseconds: 600),
                    child: InkWell(
                      onTap: () {
                        onNavigateTo(const StudioNavigation.profileSecurity());
                        if (compact) {
                          Scaffold.maybeOf(sidebarContext)?.closeDrawer();
                        }
                      },
                      borderRadius: BorderRadius.circular(8),
                      hoverColor: const Color(0xff29283c),
                      focusColor: const Color(0xff302d4b),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6),
                        decoration: BoxDecoration(
                          color: shellContext.isNavActive(
                                  const StudioNavigation.profileSecurity())
                              ? const Color(0xff302d4b)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
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
                                style: TextStyle(
                                  color: shellContext.isNavActive(
                                          const StudioNavigation.profileSecurity())
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 11.5,
                                  fontWeight: shellContext.isNavActive(
                                          const StudioNavigation.profileSecurity())
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
                ),
                const SizedBox(width: 4),
                GlobalAppMenu(
                  shellContext: shellContext,
                  onNavigateTo: onNavigateTo,
                  onToggleTheme: onToggleTheme,
                  onSetThemeMode: onSetThemeMode,
                  onOpenAbout: onOpenAbout,
                  onOpenExternal: onOpenExternal,
                  onLogout: onLogout,
                  compact: compact,
                ),
              ],
            ),
          ],
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
}

/// Compact Icon Rail when shell is collapsed or on tablet.
class AppIconRail extends StatelessWidget {
  const AppIconRail({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onOpenDrawer,
    this.onToggleTheme,
    this.onSetThemeMode,
    required this.onLogout,
    required this.onOpenAbout,
    required this.onOpenExternal,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final VoidCallback onOpenDrawer;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback onLogout;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      color: ConclaveBrand.navigation,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
      child: Column(
        children: [
          Tooltip(
            message: 'Conclave AX — Home',
            child: InkWell(
              onTap: () => onNavigateTo(const StudioNavigation.home()),
              borderRadius: BorderRadius.circular(8),
              hoverColor: const Color(0xff29283c),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: ConclaveBrand.logoMark(size: 32),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Spacer(),
          Tooltip(
            message: shellContext.viewerDisplayName ??
                shellContext.viewerEmail ??
                'Profile & Security',
            child: InkWell(
              onTap: () =>
                  onNavigateTo(const StudioNavigation.profileSecurity()),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: shellContext.isNavActive(
                          const StudioNavigation.profileSecurity())
                      ? Border.all(color: const Color(0xffbcb3ff), width: 2)
                      : null,
                ),
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
            ),
          ),
          const SizedBox(height: 6),
          GlobalAppMenu(
            shellContext: shellContext,
            onNavigateTo: onNavigateTo,
            onToggleTheme: onToggleTheme,
            onSetThemeMode: onSetThemeMode,
            onOpenAbout: onOpenAbout,
            onOpenExternal: onOpenExternal,
            onLogout: onLogout,
          ),
        ],
      ),
    );
  }
}

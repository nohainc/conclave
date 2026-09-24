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

            // Top-level Navigation: Home and Projects
            _navItem(
              icon: Icons.home_outlined,
              label: 'Home',
              target: const StudioNavigation.home(),
              context: sidebarContext,
            ),
            _navItem(
              icon: Icons.folder_outlined,
              label: 'Projects',
              target: const StudioNavigation.projects(),
              context: sidebarContext,
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

  Widget _railItem(IconData icon, String tooltip, StudioNavigation target) {
    final active = shellContext.isNavActive(target);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => onNavigateTo(target),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 44,
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: active ? const Color(0xff302d4b) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: active ? const Color(0xffbcb3ff) : Colors.white60,
          ),
        ),
      ),
    );
  }
}

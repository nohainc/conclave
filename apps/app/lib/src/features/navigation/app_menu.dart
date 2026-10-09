import 'package:flutter/material.dart';

import '../../brand.dart';
import '../common/external_links.dart';
import '../../navigation/ax_navigation.dart';
import 'ax_shell_context.dart';

/// Global application menu anchor (⋯) providing destinations, preferences,
/// product information, and session logout.
class GlobalAppMenu extends StatelessWidget {
  const GlobalAppMenu({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    this.onToggleTheme,
    this.onSetThemeMode,
    required this.onOpenAbout,
    required this.onOpenExternal,
    required this.onLogout,
    this.onOpenArchivedSpaces,
    this.compact = false,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;
  final VoidCallback onLogout;
  final VoidCallback? onOpenArchivedSpaces;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final activeThemeMode = shellContext.themeMode;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(
        ConclaveColors.navigationRaised(isDark),
      ),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(12),
      shadowColor: WidgetStatePropertyAll(
        Colors.black.withValues(alpha: isDark ? 0.7 : 0.18),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: ConclaveColors.navigationBorder(isDark),
            width: 1,
          ),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      ),
    );

    ButtonStyle itemStyle({bool isDestructive = false}) {
      return ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(196, 36)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            if (isDestructive) {
              return ConclaveColors.error.withValues(alpha: 0.12);
            }
            return ConclaveColors.navigationHover(isDark);
          }
          return null;
        }),
      );
    }

    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Divider(
            height: 1,
            thickness: 1,
            color: ConclaveColors.navigationBorder(isDark),
          ),
        );

    final menuIconColor = isDark ? Colors.white70 : Colors.black87;

    return MenuAnchor(
      style: menuStyle,
      builder: (context, controller, child) {
        return IconButton(
          tooltip: 'Application menu',
          icon: const Icon(
            Icons.menu_rounded,
            color: Colors.white60,
            size: 18,
          ),
          splashRadius: 14,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
        );
      },
      menuChildren: [
        // 1. Application destinations
        MenuItemButton(
            style: itemStyle(),
            leadingIcon:
                Icon(Icons.people_outline, size: 16, color: menuIconColor),
            onPressed: () {
              onNavigateTo(const AxNavigation.people());
              if (compact) Scaffold.maybeOf(context)?.closeDrawer();
            },
            child: const Text('People',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500))),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon:
              Icon(Icons.account_tree_outlined, size: 16, color: menuIconColor),
          onPressed: () {
            onNavigateTo(const AxNavigation.workflows());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text('Workflows',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.grid_view_rounded,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: () {
            onNavigateTo(const AxNavigation.workspaces());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text(
            'Workspaces',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.archive_outlined,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: onOpenArchivedSpaces,
          child: const Text(
            'Archived Spaces',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        divider(),

        // 2. Preferences
        SubmenuButton(
          style: itemStyle(),
          menuStyle: menuStyle,
          leadingIcon: Icon(
            Icons.contrast_rounded,
            size: 16,
            color: menuIconColor,
          ),
          menuChildren: [
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.system
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 15,
                color: activeThemeMode == ThemeMode.system
                    ? (isDark ? Colors.white : Colors.black87)
                    : (isDark ? Colors.white38 : Colors.black38),
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.system);
                } else {
                  onToggleTheme?.call();
                }
              },
              child: const Text(
                'System',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.light
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 15,
                color: activeThemeMode == ThemeMode.light
                    ? (isDark ? Colors.white : Colors.black87)
                    : (isDark ? Colors.white38 : Colors.black38),
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.light);
                } else if (shellContext.isDarkTheme) {
                  onToggleTheme?.call();
                }
              },
              child: const Text(
                'Light',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.dark
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 15,
                color: activeThemeMode == ThemeMode.dark
                    ? (isDark ? Colors.white : Colors.black87)
                    : (isDark ? Colors.white38 : Colors.black38),
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.dark);
                } else if (!shellContext.isDarkTheme) {
                  onToggleTheme?.call();
                }
              },
              child: const Text(
                'Dark',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          ],
          child: const Text(
            'Appearance',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.download_outlined,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: () => onOpenExternal(Uri.parse(conclaveDownloadsUrl)),
          child: const Text(
            'Downloads',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.menu_book_rounded,
            size: 16,
            color: menuIconColor,
          ),
          onPressed: () => onOpenExternal(Uri.parse(conclaveDocumentationUrl)),
          child: const Text(
            'Documentation',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: ConclaveBrand.logoMark(size: 16),
          onPressed: onOpenAbout,
          child: const Text(
            'About Conclave AX',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        divider(),

        // 3. Session action
        MenuItemButton(
          style: itemStyle(isDestructive: true),
          leadingIcon: const Icon(
            Icons.logout_rounded,
            size: 16,
            color: ConclaveColors.error,
          ),
          onPressed: onLogout,
          child: const Text(
            'Log out',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: ConclaveColors.error,
            ),
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import 'studio_shell_context.dart';

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
    this.compact = false,
  });

  final StudioShellContext shellContext;
  final ValueChanged<StudioNavigation> onNavigateTo;
  final VoidCallback? onToggleTheme;
  final ValueChanged<ThemeMode>? onSetThemeMode;
  final VoidCallback onOpenAbout;
  final ValueChanged<Uri> onOpenExternal;
  final VoidCallback onLogout;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final activeThemeMode = shellContext.themeMode;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(
        isDark ? const Color(0xff181726) : Colors.white,
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
            color: isDark ? const Color(0xff2d2b42) : const Color(0xffe5e3f0),
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
              return const Color(0xffef4444).withValues(alpha: 0.12);
            }
            return isDark
                ? const Color(0xff2a2840)
                : const Color(0xfff0effa);
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
            color: isDark ? const Color(0xff28263c) : const Color(0xffeceaf4),
          ),
        );

    return MenuAnchor(
      style: menuStyle,
      builder: (context, controller, child) {
        return IconButton(
          tooltip: 'Application menu',
          icon: const Icon(
            Icons.more_horiz_rounded,
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
          leadingIcon: const Icon(
            Icons.grid_view_rounded,
            size: 16,
            color: Color(0xff9e95ff),
          ),
          onPressed: () {
            onNavigateTo(const StudioNavigation.hosts());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text(
            'Workspaces',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: const Icon(
            Icons.pie_chart_outline_rounded,
            size: 16,
            color: Color(0xff60a5fa),
          ),
          onPressed: () {
            onNavigateTo(const StudioNavigation.usage());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text(
            'Usage',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        divider(),

        // 2. Preferences
        SubmenuButton(
          style: itemStyle(),
          menuStyle: menuStyle,
          leadingIcon: const Icon(
            Icons.contrast_rounded,
            size: 16,
            color: Color(0xffc084fc),
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
                    ? const Color(0xff9e95ff)
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
                    ? const Color(0xff9e95ff)
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
                    ? const Color(0xff9e95ff)
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
        divider(),

        // 3. Product information
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: ConclaveBrand.logoMark(size: 16),
          onPressed: onOpenAbout,
          child: const Text(
            'About Conclave AX',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        MenuItemButton(
          style: itemStyle(),
          leadingIcon: Icon(
            Icons.open_in_new_rounded,
            size: 16,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
          onPressed: () => onOpenExternal(Uri.parse('https://conclaveax.com')),
          child: const Text(
            'Website',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        divider(),

        // 4. Session action
        MenuItemButton(
          style: itemStyle(isDestructive: true),
          leadingIcon: const Icon(
            Icons.logout_rounded,
            size: 16,
            color: Color(0xffef4444),
          ),
          onPressed: onLogout,
          child: const Text(
            'Log out',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: Color(0xffef4444),
            ),
          ),
        ),
      ],
    );
  }
}

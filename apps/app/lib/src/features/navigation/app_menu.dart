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

    return MenuAnchor(
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
          leadingIcon: const Icon(Icons.grid_view_rounded, size: 16),
          onPressed: () {
            onNavigateTo(const StudioNavigation.hosts());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text('Workspaces'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.pie_chart_outline_rounded, size: 16),
          onPressed: () {
            onNavigateTo(const StudioNavigation.usage());
            if (compact) Scaffold.maybeOf(context)?.closeDrawer();
          },
          child: const Text('Usage'),
        ),
        const Divider(height: 1),

        // 2. Preferences
        SubmenuButton(
          leadingIcon: const Icon(Icons.contrast_rounded, size: 16),
          menuChildren: [
            MenuItemButton(
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.system
                    ? Icons.check_rounded
                    : null,
                size: 16,
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.system);
                } else {
                  onToggleTheme?.call();
                }
              },
              child: const Text('System'),
            ),
            MenuItemButton(
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.light ? Icons.check_rounded : null,
                size: 16,
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.light);
                } else if (shellContext.isDarkTheme) {
                  onToggleTheme?.call();
                }
              },
              child: const Text('Light'),
            ),
            MenuItemButton(
              leadingIcon: Icon(
                activeThemeMode == ThemeMode.dark ? Icons.check_rounded : null,
                size: 16,
              ),
              onPressed: () {
                if (onSetThemeMode != null) {
                  onSetThemeMode!(ThemeMode.dark);
                } else if (!shellContext.isDarkTheme) {
                  onToggleTheme?.call();
                }
              },
              child: const Text('Dark'),
            ),
          ],
          child: const Text('Appearance'),
        ),
        const Divider(height: 1),

        // 3. Product information
        MenuItemButton(
          leadingIcon: ConclaveBrand.logoMark(size: 16),
          onPressed: onOpenAbout,
          child: const Text('About Conclave AX'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.open_in_new_rounded, size: 16),
          onPressed: () => onOpenExternal(Uri.parse('https://conclaveax.com')),
          child: const Text('Website'),
        ),
        const Divider(height: 1),

        // 4. Session action
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout_rounded, size: 16),
          onPressed: onLogout,
          child: const Text('Log out'),
        ),
      ],
    );
  }
}

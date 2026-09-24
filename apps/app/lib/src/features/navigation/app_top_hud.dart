import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import 'breadcrumb.dart';
import 'execution_health.dart';
import 'studio_shell_context.dart';

/// Canonical Top Application Header Bar (HUD) for Conclave AX.
class AppTopHud extends StatelessWidget implements PreferredSizeWidget {
  const AppTopHud({
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
    final isDesktop = ConclaveBrand.isDesktop(screenWidth) && !compact;
    final isTablet = ConclaveBrand.isTablet(screenWidth) && !compact;

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

          // Route-Aware Breadcrumbs
          Expanded(
            child: AppBreadcrumb(
              shellContext: shellContext,
              onNavigateTo: onNavigateTo,
              inkColor: inkColor,
              mutedInk: mutedInk,
              compact: compact,
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
          ] else if (isTablet) ...[
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

          // Operational Execution Status Popover Trigger (desktop/expanded only)
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
        ],
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

import 'package:flutter/material.dart';
import '../../brand.dart';
import '../../studio/studio_models.dart';

/// Top Application Header Bar for Conclave AX
class StudioTopBar extends StatelessWidget implements PreferredSizeWidget {
  const StudioTopBar({
    super.key,
    required this.workspaces,
    required this.activeWorkspaceId,
    required this.onWorkspaceSelected,
    required this.unreadNotificationCount,
    required this.onOpenNotifications,
    required this.onOpenCommandPalette,
    required this.isDarkTheme,
    required this.onToggleTheme,
    required this.onOpenAbout,
    required this.onOpenAccount,
    this.viewerEmail,
  });

  final List<StudioWorkspace> workspaces;
  final String? activeWorkspaceId;
  final ValueChanged<String> onWorkspaceSelected;
  final int unreadNotificationCount;
  final VoidCallback onOpenNotifications;
  final VoidCallback onOpenCommandPalette;
  final bool isDarkTheme;
  final VoidCallback onToggleTheme;
  final VoidCallback onOpenAbout;
  final VoidCallback onOpenAccount;
  final String? viewerEmail;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;

    final activeWorkspace = workspaces
        .where((w) => w.id == activeWorkspaceId)
        .firstOrNull ?? (workspaces.isNotEmpty ? workspaces.first : null);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // Logo & Brand Mark
          InkWell(
            onTap: onOpenAbout,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: ConclaveBrand.brandMark,
                  child: const Center(
                    child: Text(
                      'C',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Conclave AX',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // Workspace Selector
          if (workspaces.isNotEmpty) ...[
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: isDark ? ConclaveBrand.darkPaper : ConclaveBrand.lightPaper,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: borderColor),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: activeWorkspace?.id,
                  icon: Icon(
                    Icons.unfold_more_rounded,
                    size: 16,
                    color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                  ),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
                  ),
                  items: workspaces.map((w) {
                    return DropdownMenuItem(
                      value: w.id,
                      child: Text(w.name),
                    );
                  }).toList(),
                  onChanged: (id) {
                    if (id != null) onWorkspaceSelected(id);
                  },
                ),
              ),
            ),
          ],
          const Spacer(),
          // Command Palette Search Button
          InkWell(
            onTap: onOpenCommandPalette,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark ? ConclaveBrand.darkPaper : ConclaveBrand.lightPaper,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Search or jump to...',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: borderColor),
                    ),
                    child: Text(
                      '⌘K',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Theme Toggle (Light / Dark)
          IconButton(
            icon: Icon(
              isDarkTheme ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 19,
              color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
            ),
            tooltip: isDarkTheme ? 'Switch to light mode' : 'Switch to dark mode',
            splashRadius: 18,
            onPressed: onToggleTheme,
          ),
          // Notifications Bell
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                icon: Icon(
                  Icons.notifications_outlined,
                  size: 20,
                  color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
                ),
                tooltip: 'Notifications',
                splashRadius: 18,
                onPressed: onOpenNotifications,
              ),
              if (unreadNotificationCount > 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                      color: ConclaveBrand.accent,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                    child: Text(
                      '$unreadNotificationCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 4),
          // User Avatar / Account
          IconButton(
            icon: Icon(
              Icons.account_circle_outlined,
              size: 22,
              color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
            ),
            tooltip: viewerEmail ?? 'Account & Security',
            splashRadius: 18,
            onPressed: onOpenAccount,
          ),
        ],
      ),
    );
  }
}

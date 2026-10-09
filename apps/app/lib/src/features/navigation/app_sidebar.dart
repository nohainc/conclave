import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import 'app_menu.dart';
import 'space_tree.dart';
import 'ax_shell_context.dart';

/// Canonical Application Sidebar for Conclave AX.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    ValueChanged<String>? onToggleSpaceExpanded,
    VoidCallback? onCreateSpace,
    this.onCreateThread,
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
    this.onOpenArchivedSpaces,
    this.onToggleCollapse,
    this.compact = false,
  })  : onToggleSpaceExpanded = onToggleSpaceExpanded ?? _noopString,
        onCreateSpace = onCreateSpace ?? _noopVoid;

  static void _noopString(String _) {}
  static void _noopVoid() {}

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final ValueChanged<String> onToggleSpaceExpanded;
  final VoidCallback onCreateSpace;
  final ValueChanged<AxSpace>? onCreateThread;
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
  final VoidCallback? onOpenArchivedSpaces;
  final VoidCallback? onToggleCollapse;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (sidebarContext) => Container(
        width: compact ? double.infinity : 248,
        color: ConclaveColors.navigationBackgroundDark,
        padding: const EdgeInsets.fromLTRB(10, 16, 10, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Brand header — clicking navigates to Home, with toggle sidebar icon on the right
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: 'Conclave AX — Home',
                    child: InkWell(
                      onTap: () {
                        onNavigateTo(const AxNavigation.home());
                        if (compact) {
                          Scaffold.maybeOf(sidebarContext)?.closeDrawer();
                        }
                      },
                      borderRadius: BorderRadius.circular(ConclaveRadius.sm),
                      hoverColor: ConclaveColors.navigationHoverDark,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            ConclaveBrand.logoMark(size: 28),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                'Conclave AX',
                                overflow: TextOverflow.ellipsis,
                                style: ConclaveTypography.wordmark.copyWith(
                                  color: Colors.white,
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
                Tooltip(
                  message: compact ? 'Close sidebar' : 'Hide sidebar',
                  child: IconButton(
                    onPressed: () {
                      if (compact) {
                        Scaffold.maybeOf(sidebarContext)?.closeDrawer();
                      } else if (onToggleCollapse != null) {
                        onToggleCollapse!();
                      }
                    },
                    icon: const Icon(
                      Icons.menu_open_rounded,
                      size: 20,
                      color: Colors.white70,
                    ),
                    splashRadius: 16,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    style: IconButton.styleFrom(
                      hoverColor: ConclaveColors.navigationHoverDark,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(ConclaveRadius.sm),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Search control, Add Space icon button & Notifications Alarm button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: 'Search or jump to...',
                      child: Container(
                        height: 32,
                        decoration: BoxDecoration(
                          color: ConclaveColors.navigationBackgroundDark,
                          borderRadius:
                              BorderRadius.circular(ConclaveRadius.sm),
                          border: Border.all(color: ConclaveColors.borderDark),
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
                                  child: CallbackShortcuts(
                                    bindings: {
                                      const SingleActivator(
                                          LogicalKeyboardKey.escape): () {
                                        searchController?.clear();
                                        onSearchChanged?.call('');
                                        onClearSearch?.call();
                                      },
                                    },
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
                                        filled: true,
                                        fillColor: Colors.transparent,
                                        hoverColor: Colors.transparent,
                                        focusColor: Colors.transparent,
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
                    message: 'New Space',
                    child: IconButton(
                      onPressed: onCreateSpace,
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
                        hoverColor: ConclaveColors.navigationHoverDark,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(ConclaveRadius.sm),
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
                        hoverColor: ConclaveColors.navigationHoverDark,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(ConclaveRadius.sm),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Navigation Centerpiece: Full Space Tree
            Expanded(
              child: SingleChildScrollView(
                child: SpaceTree(
                  shellContext: shellContext,
                  onNavigateTo: onNavigateTo,
                  onToggleSpaceExpanded: onToggleSpaceExpanded,
                  onCreateSpace: onCreateSpace,
                  onCreateThread: onCreateThread,
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
                        onNavigateTo(const AxNavigation.profileSecurity());
                        if (compact) {
                          Scaffold.maybeOf(sidebarContext)?.closeDrawer();
                        }
                      },
                      borderRadius: BorderRadius.circular(ConclaveRadius.sm),
                      hoverColor: ConclaveColors.navigationHoverDark,
                      focusColor: ConclaveColors.navigationSelected,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6),
                        decoration: BoxDecoration(
                          color: shellContext.isNavActive(
                                  const AxNavigation.profileSecurity())
                              ? ConclaveColors.navigationSelected
                              : Colors.transparent,
                          borderRadius:
                              BorderRadius.circular(ConclaveRadius.sm),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 13,
                              backgroundColor: ConclaveColors.primarySoft,
                              backgroundImage: shellContext.viewerAvatarImage,
                              child: shellContext.viewerAvatarImage == null
                                  ? Text(
                                      shellContext.viewerInitials,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: ConclaveColors.primaryPressed,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
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
                                          const AxNavigation.profileSecurity())
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 11.5,
                                  fontWeight: shellContext.isNavActive(
                                          const AxNavigation.profileSecurity())
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
                  onOpenArchivedSpaces: onOpenArchivedSpaces,
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
    required AxNavigation? target,
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
      borderRadius: BorderRadius.circular(ConclaveRadius.sm),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color:
              active ? ConclaveColors.navigationSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(ConclaveRadius.sm),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: active
                  ? ConclaveColors.primaryForegroundDark
                  : ConclaveColors.navigationTextMutedDark,
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
                  color: ConclaveColors.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
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
    this.onCreateSpace,
    this.onCreateThread,
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
    this.onOpenArchivedSpaces,
    this.onToggleCollapse,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final VoidCallback onOpenDrawer;
  final VoidCallback? onCreateSpace;
  final ValueChanged<AxSpace>? onCreateThread;
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
  final VoidCallback? onOpenArchivedSpaces;
  final VoidCallback? onToggleCollapse;

  Widget _railIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Widget? iconWidget,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: iconWidget ?? Icon(icon, size: 20, color: Colors.white70),
        splashRadius: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        style: IconButton.styleFrom(
          hoverColor: ConclaveColors.navigationHoverDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ConclaveRadius.sm),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(
        ConclaveColors.surface(isDark),
      ),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(12),
      shadowColor: WidgetStatePropertyAll(
        Colors.black.withValues(alpha: isDark ? 0.7 : 0.18),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ConclaveRadius.lg),
          side: BorderSide(
            color: ConclaveColors.border(isDark),
            width: 1,
          ),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      ),
    );

    ButtonStyle itemStyle() {
      return ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(200, 36)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ConclaveRadius.sm)),
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return ConclaveColors.surfaceHover(isDark);
          }
          return null;
        }),
      );
    }

    return Container(
      width: 50,
      color: ConclaveColors.navigationBackgroundDark,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
      child: Column(
        children: [
          // Logo navigates to Home
          Tooltip(
            message: 'Conclave AX — Home',
            child: InkWell(
              onTap: () => onNavigateTo(const AxNavigation.home()),
              borderRadius: BorderRadius.circular(ConclaveRadius.sm),
              hoverColor: ConclaveColors.navigationHoverDark,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: ConclaveBrand.logoMark(size: 32),
              ),
            ),
          ),
          if (onToggleCollapse != null) ...[
            const SizedBox(height: 6),
            _railIconButton(
              icon: Icons.menu_open_rounded,
              iconWidget: Transform.flip(
                flipX: true,
                child: const Icon(
                  Icons.menu_open_rounded,
                  size: 20,
                  color: Colors.white70,
                ),
              ),
              tooltip: 'Expand sidebar',
              onPressed: onToggleCollapse,
            ),
          ],
          const SizedBox(height: 10),

          // Search popup control that opens an input popup and closes on focus loss
          _RailSearchMenuAnchor(
            menuStyle: menuStyle,
            searchController: searchController,
            searchFocusNode: searchFocusNode,
            onSearchChanged: onSearchChanged,
            onClearSearch: onClearSearch,
            onNavigateTo: onNavigateTo,
            isDark: isDark,
          ),
          const SizedBox(height: 6),

          // Add Space icon
          if (onCreateSpace != null) ...[
            _railIconButton(
              icon: Icons.add_rounded,
              tooltip: 'Add Space',
              onPressed: onCreateSpace,
            ),
            const SizedBox(height: 6),
          ],

          // Notifications Alarm icon
          _railIconButton(
            icon: Icons.notifications_outlined,
            tooltip: 'Notifications',
            onPressed: onOpenNotifications,
            iconWidget: shellContext.watchNotifications(
                () => shellContext.unreadNotificationCount > 0
                    ? Badge.count(
                        count: shellContext.unreadNotificationCount,
                        child: const Icon(
                          Icons.notifications_outlined,
                          size: 20,
                          color: Colors.white70,
                        ),
                      )
                    : const Icon(
                        Icons.notifications_outlined,
                        size: 20,
                        color: Colors.white70,
                      )),
          ),
          const SizedBox(height: 6),

          // Space & Thread Switcher MenuAnchor using matching popup style
          shellContext.watchSpacesAndThreads(() => Column(children: [
                for (final group in [
                  (
                    label: 'YOUR SPACES',
                    spaces: shellContext.ownedSpaces,
                    icon: Icons.folder_outlined
                  ),
                  (
                    label: 'SHARED WITH YOU',
                    spaces: shellContext.sharedSpaces,
                    icon: Icons.folder_shared_outlined
                  ),
                ])
                  if (group.spaces.isNotEmpty)
                    MenuAnchor(
                      style: menuStyle,
                      builder: (context, controller, child) {
                        return _railIconButton(
                          icon: group.icon,
                          tooltip: group.label,
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
                        for (final space in group.spaces) ...[
                          MenuItemButton(
                            style: itemStyle(),
                            leadingIcon: ConclaveFolderIcon(
                              isExpanded: true,
                              size: 16,
                              color: shellContext
                                      .isNavActive(AxNavigation.space(space.id))
                                  ? ConclaveColors.primaryForegroundDark
                                  : (isDark ? Colors.white70 : Colors.black87),
                            ),
                            onPressed: () =>
                                onNavigateTo(AxNavigation.space(space.id)),
                            child: Text(
                              space.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: shellContext.isNavActive(
                                        AxNavigation.space(space.id))
                                    ? FontWeight.bold
                                    : FontWeight.w600,
                                color: shellContext.isNavActive(
                                        AxNavigation.space(space.id))
                                    ? ConclaveColors.primaryForegroundDark
                                    : (isDark ? Colors.white : Colors.black87),
                              ),
                            ),
                          ),
                          for (final thread
                              in (shellContext.spaceThreads?.peek(space.id) ??
                                  shellContext.threadsBySpace[space.id] ??
                                  const <AxThread>[]))
                            MenuItemButton(
                              style: itemStyle(),
                              onPressed: () => onNavigateTo(
                                  AxNavigation.thread(space.id, thread.id)),
                              child: Padding(
                                padding: const EdgeInsets.only(left: 24),
                                child: Text(
                                  thread.title,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: shellContext.isNavActive(
                                            AxNavigation.thread(
                                                space.id, thread.id))
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: shellContext.isNavActive(
                                            AxNavigation.thread(
                                                space.id, thread.id))
                                        ? ConclaveColors.primaryForegroundDark
                                        : (isDark
                                            ? Colors.white70
                                            : Colors.black87),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
              ])),

          const Spacer(),

          // Application menu icon above user avatar
          GlobalAppMenu(
            shellContext: shellContext,
            onNavigateTo: onNavigateTo,
            onToggleTheme: onToggleTheme,
            onSetThemeMode: onSetThemeMode,
            onOpenAbout: onOpenAbout,
            onOpenExternal: onOpenExternal,
            onLogout: onLogout,
            onOpenArchivedSpaces: onOpenArchivedSpaces,
          ),
          const SizedBox(height: 8),

          // User Profile & Security avatar
          Tooltip(
            message: shellContext.viewerDisplayName ??
                shellContext.viewerEmail ??
                'Profile & Security',
            child: InkWell(
              onTap: () => onNavigateTo(const AxNavigation.profileSecurity()),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: shellContext
                          .isNavActive(const AxNavigation.profileSecurity())
                      ? Border.all(
                          color: ConclaveColors.primaryForegroundDark, width: 2)
                      : null,
                ),
                child: CircleAvatar(
                  radius: 14,
                  backgroundColor: ConclaveColors.primarySoft,
                  backgroundImage: shellContext.viewerAvatarImage,
                  child: shellContext.viewerAvatarImage == null
                      ? Text(
                          shellContext.viewerInitials,
                          style: const TextStyle(
                            fontSize: 11,
                            color: ConclaveColors.primaryPressed,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Popover Search field anchored to the Search icon button in collapsed rail.
class _RailSearchMenuAnchor extends StatefulWidget {
  const _RailSearchMenuAnchor({
    required this.menuStyle,
    required this.searchController,
    required this.searchFocusNode,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onNavigateTo,
    required this.isDark,
  });

  final MenuStyle menuStyle;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onClearSearch;
  final ValueChanged<AxNavigation> onNavigateTo;
  final bool isDark;

  @override
  State<_RailSearchMenuAnchor> createState() => _RailSearchMenuAnchorState();
}

class _RailSearchMenuAnchorState extends State<_RailSearchMenuAnchor> {
  final MenuController _menuController = MenuController();
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _ownsController = false;
  bool _ownsFocusNode = false;

  @override
  void initState() {
    super.initState();
    if (widget.searchController != null) {
      _controller = widget.searchController!;
    } else {
      _controller = TextEditingController();
      _ownsController = true;
    }
    if (widget.searchFocusNode != null) {
      _focusNode = widget.searchFocusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  void _openSearchMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
    } else {
      _menuController.open();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _handleClearAndClose() {
    _controller.clear();
    widget.onSearchChanged?.call('');
    widget.onClearSearch?.call();
    _menuController.close();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menuController,
      style: widget.menuStyle,
      builder: (context, controller, child) {
        return Tooltip(
          message: 'Search...',
          child: IconButton(
            onPressed: _openSearchMenu,
            icon: const Icon(
              Icons.search_rounded,
              size: 20,
              color: Colors.white70,
            ),
            splashRadius: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            style: IconButton.styleFrom(
              hoverColor: ConclaveColors.navigationHoverDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ConclaveRadius.sm),
              ),
            ),
          ),
        );
      },
      menuChildren: [
        Container(
          width: 260,
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 36,
                decoration: BoxDecoration(
                  color: ConclaveColors.canvas(widget.isDark),
                  borderRadius: BorderRadius.circular(ConclaveRadius.sm),
                  border: Border.all(
                    color: ConclaveColors.border(widget.isDark),
                  ),
                ),
                child: ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) {
                    final hasText = _controller.text.isNotEmpty;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(left: 8, right: 4),
                          child: Icon(
                            Icons.search_rounded,
                            size: 16,
                            color: Colors.white54,
                          ),
                        ),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(LogicalKeyboardKey.escape):
                                  _handleClearAndClose,
                            },
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              onChanged: widget.onSearchChanged,
                              onSubmitted: (text) {
                                widget
                                    .onNavigateTo(const AxNavigation.search());
                                _menuController.close();
                              },
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.isDark
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                              cursorColor: ConclaveBrand.accent,
                              cursorHeight: 14,
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: Colors.transparent,
                                hoverColor: Colors.transparent,
                                focusColor: Colors.transparent,
                                hintText: 'Search or jump to...',
                                hintStyle: TextStyle(
                                  fontSize: 12,
                                  color: widget.isDark
                                      ? Colors.white38
                                      : Colors.black38,
                                ),
                                isDense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                border: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                errorBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                        if (hasText)
                          IconButton(
                            onPressed: _handleClearAndClose,
                            tooltip: 'Clear and close',
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: Colors.white54,
                            ),
                            splashRadius: 14,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            constraints: const BoxConstraints(
                                minWidth: 24, minHeight: 24),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

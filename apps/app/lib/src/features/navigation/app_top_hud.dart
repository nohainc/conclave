import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import 'breadcrumb.dart';
import 'execution_health.dart';
import 'studio_shell_context.dart';

/// Canonical Top Application Header Bar (HUD) for Conclave AX.
class AppTopHud extends StatefulWidget implements PreferredSizeWidget {
  const AppTopHud({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    required this.onOpenCommandPalette,
    required this.onOpenNotifications,
    this.searchController,
    this.searchFocusNode,
    this.onSearchChanged,
    this.onClearSearch,
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
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onClearSearch;
  final VoidCallback? onToggleTheme;
  final VoidCallback? onOpenAbout;
  final VoidCallback? onLogout;
  final ValueChanged<Uri>? onOpenExternal;
  final bool compact;

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  State<AppTopHud> createState() => _AppTopHudState();
}

class _AppTopHudState extends State<AppTopHud> {
  bool _isSearchExpanded = false;
  final TextEditingController _fallbackController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.searchFocusNode?.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(AppTopHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFocusNode != widget.searchFocusNode) {
      oldWidget.searchFocusNode?.removeListener(_onFocusChange);
      widget.searchFocusNode?.addListener(_onFocusChange);
    }
    if (widget.shellContext.navigation.kind != StudioRouteKind.search) {
      if (_isSearchExpanded) {
        _isSearchExpanded = false;
      }
    }
  }

  void _onFocusChange() {
    if (widget.searchFocusNode != null && !widget.searchFocusNode!.hasFocus) {
      if (widget.shellContext.navigation.kind != StudioRouteKind.search ||
          (widget.searchController?.text.isEmpty ?? true)) {
        if (_isSearchExpanded && mounted) {
          setState(() => _isSearchExpanded = false);
        }
      }
    }
  }

  @override
  void dispose() {
    widget.searchFocusNode?.removeListener(_onFocusChange);
    _fallbackController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor =
        isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;
    final inkColor = isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk;
    final mutedInk =
        isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted;

    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = ConclaveBrand.isDesktop(screenWidth) && !widget.compact;

    final controller = widget.searchController ?? _fallbackController;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final isSearchRoute =
            widget.shellContext.navigation.kind == StudioRouteKind.search;
        final showInlineSearch =
            _isSearchExpanded || (isSearchRoute && controller.text.isNotEmpty);

        return Container(
          height: 60,
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 12 : 24),
          decoration: BoxDecoration(
            color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
            border: Border(bottom: BorderSide(color: borderColor)),
          ),
          child: Row(
            children: [
              // Drawer opener on compact screens
              if (widget.compact) ...[
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

              // Route-Aware Breadcrumbs or Expanded Search Input
              if (showInlineSearch) ...[
                Expanded(
                  child: Container(
                    height: 34,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xff181724)
                          : const Color(0xfff0effa),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xff2d2b40)
                            : const Color(0xffdcd9ee),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8, right: 6),
                          child: Icon(
                            Icons.search_rounded,
                            size: 16,
                            color: mutedInk,
                          ),
                        ),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(LogicalKeyboardKey.escape): () {
                                widget.onClearSearch?.call();
                                widget.searchController?.clear();
                                setState(() => _isSearchExpanded = false);
                                widget.searchFocusNode?.unfocus();
                              },
                            },
                            child: TextField(
                              controller: widget.searchController,
                              focusNode: widget.searchFocusNode,
                              onChanged: widget.onSearchChanged,
                              autofocus: true,
                              style: TextStyle(
                                fontSize: 13,
                                color: inkColor,
                              ),
                              cursorColor: ConclaveBrand.accent,
                              cursorHeight: 14,
                              decoration: InputDecoration(
                                hintText: 'Search...',
                                hintStyle: TextStyle(
                                  fontSize: 13,
                                  color: mutedInk,
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
                        InkWell(
                          onTap: () {
                            widget.onClearSearch?.call();
                            widget.searchController?.clear();
                            setState(() => _isSearchExpanded = false);
                            widget.searchFocusNode?.unfocus();
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: mutedInk,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
            Expanded(
              child: AppBreadcrumb(
                shellContext: widget.shellContext,
                onNavigateTo: widget.onNavigateTo,
                inkColor: inkColor,
                mutedInk: mutedInk,
                compact: widget.compact,
              ),
            ),

            // Search affordance
            if (isDesktop) ...[
              InkWell(
                onTap: widget.onOpenCommandPalette,
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
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
            ] else ...[
              IconButton(
                icon: Icon(Icons.search_rounded, size: 20, color: mutedInk),
                tooltip: 'Search',
                onPressed: () {
                  if (widget.searchController != null ||
                      widget.searchFocusNode != null) {
                    setState(() => _isSearchExpanded = true);
                    widget.searchFocusNode?.requestFocus();
                  } else {
                    widget.onOpenCommandPalette();
                  }
                },
                splashRadius: 20,
              ),
            ],
          ],

          // Operational Execution Status Popover Trigger (desktop/expanded only)
          if (!widget.compact) ...[
            OutlinedButton.icon(
              onPressed: () => _openExecutionStatusPopover(context),
              icon: Icon(
                Icons.circle,
                size: 7,
                color: widget.shellContext.executionStatusTone.color(isDark),
              ),
              label: Text(
                widget.shellContext.executionStatusLabel,
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
                onPressed: widget.onOpenNotifications,
                icon: Icon(Icons.notifications_none_rounded,
                    size: 21, color: mutedInk),
                splashRadius: 20,
              ),
              if (widget.shellContext.unreadNotificationCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Semantics(
                    label:
                        '${widget.shellContext.unreadNotificationCount} unread notifications',
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
                        widget.shellContext.unreadNotificationCount > 9
                            ? '9+'
                            : '${widget.shellContext.unreadNotificationCount}',
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
      },
    );
  }

  void _openExecutionStatusPopover(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (dialogContext) => ExecutionStatusPopover(
        shellContext: widget.shellContext,
        onNavigateTo: widget.onNavigateTo,
      ),
    );
  }
}

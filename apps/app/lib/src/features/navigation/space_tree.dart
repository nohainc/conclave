import 'dart:async';
import '../common/quiet_notices.dart';

import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import 'ax_shell_context.dart';
import '../../ax/sync/ax_query_builder.dart';

/// Width reserved at the right of every row for the menu button, so activity
/// indicators keep a fixed position whether or not the row is selected.
const double _menuSlotWidth = 28;
const double _sidebarRowHeight = 30;

/// Interactive Space Tree component for the Conclave AX App Sidebar.
class SpaceTree extends StatelessWidget {
  const SpaceTree({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    this.onToggleSpaceExpanded,
    this.onCreateSpace,
    this.onCreateThread,
    this.onEditSpace,
    this.onArchiveSpace,
    this.onDeleteSpace,
    this.onRenameThread,
    this.onSetThreadArchived,
    this.onClearChatHistory,
    this.onClearWorkHistory,
    this.onDeleteThread,
    this.onReorderThreads,
    this.compact = false,
    this.narrow = false,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final ValueChanged<String>? onToggleSpaceExpanded;
  final VoidCallback? onCreateSpace;
  final ValueChanged<AxSpace>? onCreateThread;
  final Future<void> Function(AxSpace space)? onEditSpace;
  final Future<void> Function(AxSpace space)? onArchiveSpace;
  final Future<void> Function(AxSpace space)? onDeleteSpace;
  final Future<void> Function(AxThread thread, String name)? onRenameThread;
  final Future<void> Function(AxThread thread, bool archived)?
      onSetThreadArchived;
  final Future<void> Function(AxThread thread)? onClearChatHistory;
  final Future<void> Function(AxThread thread)? onClearWorkHistory;
  final Future<void> Function(AxThread thread)? onDeleteThread;

  /// Persists a Space's Thread order (visible Thread ids, top to bottom).
  final Future<void> Function(AxSpace space, List<String> orderedThreadIds)?
      onReorderThreads;
  final bool compact;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    Widget content(BuildContext context) {
      final invitations = shellContext.invitationsListenable;
      if (invitations != null) {
        return ValueListenableBuilder<List<AxSpaceInvitation>>(
          valueListenable: invitations,
          builder: (context, _, __) => _tree(context),
        );
      }
      return _tree(context);
    }

    final spaces = shellContext.spaceListenable;
    if (spaces != null) {
      return ValueListenableBuilder<List<AxSpace>>(
        valueListenable: spaces,
        builder: (context, _, __) => content(context),
      );
    }
    return content(context);
  }

  Widget _tree(BuildContext context) {
    final invitations = shellContext.invitations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (invitations.isNotEmpty) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: ConclaveBrand.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: ConclaveBrand.accent.withValues(alpha: 0.3),
              ),
            ),
            child: InkWell(
              onTap: () => onNavigateTo(const AxNavigation.home()),
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  const Icon(
                    Icons.mail_outline,
                    size: 14,
                    color: ConclaveBrand.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Pending invitations (${invitations.length})',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
        ],
        if (shellContext.spaces.isEmpty && invitations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              'No spaces yet',
              style: TextStyle(
                fontSize: 11.5,
                color: Colors.white38,
              ),
            ),
          ),
        if (shellContext.ownedSpaces.isNotEmpty) ...[
          if (shellContext.sharedSpaces.isNotEmpty) _groupLabel('YOUR SPACES'),
          ...shellContext.ownedSpaces
              .map((space) => _buildSpaceItem(context, space)),
        ],
        if (shellContext.sharedSpaces.isNotEmpty) ...[
          _groupLabel('SHARED WITH YOU'),
          ...shellContext.sharedSpaces
              .map((space) => _buildSpaceItem(context, space)),
        ],
      ],
    );
  }

  Widget _groupLabel(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 8, 6),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white54)));

  Widget _buildSpaceItem(BuildContext context, AxSpace space) {
    final cache = shellContext.spaceThreads;
    if (cache != null && shellContext.isSpaceExpanded(space.id)) {
      return AxQueryBuilder<List<AxThread>>(
        key: ValueKey('space-threads-${space.id}'),
        engine: cache.engine,
        query: cache.query(space.id),
        builder: (context, state) => _spaceItem(
            context, space, state.data ?? const [],
            loading: !state.hasData && state.isFetching,
            error: !state.hasData ? state.error : null),
      );
    }
    return _spaceItem(
        context, space, shellContext.threadsBySpace[space.id] ?? const []);
  }

  Widget _spaceItem(BuildContext context, AxSpace space, List<AxThread> threads,
      {bool loading = false, Object? error}) {
    final isSpaceFocused = shellContext.navigation.spaceId == space.id &&
        const {
          AxRouteKind.space,
          AxRouteKind.spaceMembers,
        }.contains(shellContext.navigation.kind);
    final isExpanded = shellContext.isSpaceExpanded(space.id);
    final sortedThreads = applyAxThreadOrder(
        sortAxThreadsByLastUpdate(threads), space.settings['threadOrder']);
    final visibleThreads = sortedThreads
        .where((t) => t.status.toLowerCase() != 'archived')
        .toList();
    final archivedThreads = sortedThreads
        .where((t) => t.status.toLowerCase() == 'archived')
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: _sidebarRowHeight,
          decoration: BoxDecoration(
            color: isSpaceFocused
                ? ConclaveColors.navigationSelected
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: InkWell(
            onTap: space.id.startsWith('local-space-') ||
                    space.id.startsWith('local-space-')
                ? null
                : () {
                    // Selecting an already-expanded other Space preserves expansion.
                    if (!isExpanded || isSpaceFocused) {
                      onToggleSpaceExpanded?.call(space.id);
                    }
                    onNavigateTo(AxNavigation.space(space.id));
                    if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                  },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 2),
              child: Row(
                children: [
                  ConclaveFolderIcon(
                    isExpanded: isExpanded,
                    size: 16,
                    color: isSpaceFocused ? Colors.white : Colors.white54,
                  ),
                  SizedBox(width: narrow ? 2 : 8),
                  Expanded(
                    child: Text(
                      space.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                  _ActivityIndicators(
                    running: threads.isNotEmpty
                        ? threads.any((t) => t.hasActiveWork)
                        : space.hasActiveWork,
                    unread: threads.isNotEmpty
                        ? threads.any((t) => t.hasUnread)
                        : space.hasUnread,
                  ),
                  isSpaceFocused
                      ? _spaceMenu(context, space)
                      : const SizedBox(width: _menuSlotWidth),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded && loading)
          const Padding(
              padding: EdgeInsets.fromLTRB(34, 6, 10, 6),
              child: Text('Loading Threads…',
                  style: TextStyle(color: Colors.white60, fontSize: 11.5))),
        if (isExpanded && error != null)
          TextButton(
              onPressed: () => shellContext.spaceThreads
                  ?.ensure(space.id)
                  .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
              child: const Text('Retry Threads')),
        if (isExpanded)
          ...visibleThreads.map(
            (thread) {
              final isThreadSelected =
                  shellContext.navigation.threadId == thread.id ||
                      shellContext.selectedThread?.id == thread.id;
              final statusIndicator =
                  _buildThreadStatusIndicator(thread.status);

              return InkWell(
                onTap: thread.id.startsWith('local-thread-') ||
                        thread.id.startsWith('local-thread-')
                    ? null
                    : () {
                        onNavigateTo(AxNavigation.thread(space.id, thread.id));
                        if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                      },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  height: _sidebarRowHeight,
                  padding: EdgeInsets.only(left: narrow ? 8 : 34, right: 2),
                  decoration: BoxDecoration(
                    color: isThreadSelected
                        ? ConclaveColors.navigationSelected
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      _ActivityIndicators(
                        running: thread.hasActiveWork,
                        unread: thread.hasUnread && !isThreadSelected,
                      ),
                      if (statusIndicator != null) ...[
                        const SizedBox(width: 8),
                        statusIndicator,
                      ],
                      isThreadSelected
                          ? _threadMenu(context, space, thread,
                              visibleThreads.map((t) => t.id).toList())
                          : const SizedBox(width: _menuSlotWidth),
                    ],
                  ),
                ),
              );
            },
          ),
        if (isExpanded && archivedThreads.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(34, 8, 10, 4),
            child: Row(
              children: [
                const Icon(Icons.archive_outlined,
                    size: 12, color: Colors.white38),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Archived (${archivedThreads.length})',
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: Colors.white38,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (isExpanded)
          ...archivedThreads.map(
            (thread) {
              final isThreadSelected =
                  shellContext.navigation.threadId == thread.id ||
                      shellContext.selectedThread?.id == thread.id;

              return InkWell(
                onTap: thread.id.startsWith('local-thread-') ||
                        thread.id.startsWith('local-thread-')
                    ? null
                    : () {
                        onNavigateTo(AxNavigation.thread(space.id, thread.id));
                        if (compact) Scaffold.maybeOf(context)?.closeDrawer();
                      },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  height: _sidebarRowHeight,
                  padding: EdgeInsets.only(left: narrow ? 16 : 48, right: 2),
                  decoration: BoxDecoration(
                    color: isThreadSelected
                        ? ConclaveColors.navigationSelected
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      isThreadSelected
                          ? _threadMenu(context, space, thread)
                          : const SizedBox(width: _menuSlotWidth),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _threadMenu(BuildContext context, AxSpace space, AxThread thread,
      [List<String> visibleOrder = const []]) {
    final position = visibleOrder.indexOf(thread.id);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isArchived =
        thread.archived || thread.status.toLowerCase() == 'archived';
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

    void select(String action) =>
        _handleThreadMenuItem(context, space, thread, action);

    return SizedBox(
      width: 28,
      height: 28,
      child: MenuAnchor(
        style: menuStyle,
        builder: (context, controller, child) {
          return IconButton(
            tooltip: 'Thread menu',
            icon: const Icon(
              Icons.more_vert,
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
          if (onReorderThreads != null && position > 0)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(Icons.arrow_upward_rounded,
                  size: 16, color: menuIconColor),
              onPressed: () => _moveThread(space, visibleOrder, position, -1),
              child: const Text(
                'Move Up',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          if (onReorderThreads != null &&
              position >= 0 &&
              position < visibleOrder.length - 1)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(Icons.arrow_downward_rounded,
                  size: 16, color: menuIconColor),
              onPressed: () => _moveThread(space, visibleOrder, position, 1),
              child: const Text(
                'Move Down',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          MenuItemButton(
            style: itemStyle(),
            leadingIcon:
                Icon(Icons.edit_outlined, size: 16, color: menuIconColor),
            onPressed: () => select('rename'),
            child: const Text(
              'Rename Thread',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ),
          MenuItemButton(
            style: itemStyle(),
            leadingIcon: Icon(
              isArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
              size: 16,
              color: menuIconColor,
            ),
            onPressed: () => select(isArchived ? 'unarchive' : 'archive'),
            child: Text(
              isArchived ? 'Unarchive Thread' : 'Archive Thread',
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ),
          divider(),
          MenuItemButton(
            style: itemStyle(),
            leadingIcon:
                Icon(Icons.delete_outline, size: 16, color: menuIconColor),
            onPressed: () => select('clearChat'),
            child: const Text(
              'Clear Chat History',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ),
          MenuItemButton(
            style: itemStyle(),
            leadingIcon:
                Icon(Icons.delete_outline, size: 16, color: menuIconColor),
            onPressed: () => select('clearWork'),
            child: const Text(
              'Clear Work History',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
            ),
          ),
          divider(),
          MenuItemButton(
            style: itemStyle(isDestructive: true),
            leadingIcon: Icon(
              Icons.delete_rounded,
              size: 16,
              color: ConclaveColors.errorText(isDark),
            ),
            onPressed: () => select('delete'),
            child: Text(
              'Delete Thread',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: ConclaveColors.errorText(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _spaceMenu(BuildContext context, AxSpace space) {
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

    ButtonStyle itemStyle({bool isDestructive = false}) => ButtonStyle(
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
              return isDestructive
                  ? ConclaveColors.error.withValues(alpha: 0.12)
                  : ConclaveColors.navigationHover(isDark);
            }
            return null;
          }),
        );

    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Divider(
            height: 1,
            color: ConclaveColors.navigationBorder(isDark),
          ),
        );

    final iconColor = isDark ? Colors.white70 : Colors.black87;
    void select(String action) {
      switch (action) {
        case 'edit':
          unawaited(onEditSpace?.call(space));
          break;
        case 'archive':
          unawaited(onArchiveSpace?.call(space));
          break;
        case 'delete':
          unawaited(onDeleteSpace?.call(space));
          break;
        case 'members':
          onNavigateTo(AxNavigation.spaceMembers(space.id));
          break;
      }
    }

    return SizedBox(
      width: 28,
      height: 28,
      child: MenuAnchor(
        style: menuStyle,
        builder: (context, controller, child) => IconButton(
          tooltip: 'Space menu',
          icon: const Icon(Icons.more_vert, color: Colors.white60, size: 18),
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
        ),
        menuChildren: [
          MenuItemButton(
            style: itemStyle(),
            leadingIcon: Icon(Icons.edit_outlined, size: 16, color: iconColor),
            onPressed: () => select('edit'),
            child: const Text('Edit Space'),
          ),
          MenuItemButton(
            style: itemStyle(),
            leadingIcon:
                Icon(Icons.archive_outlined, size: 16, color: iconColor),
            onPressed: () => select('archive'),
            child: const Text('Archive Space'),
          ),
          divider(),
          MenuItemButton(
            style: itemStyle(),
            leadingIcon: Icon(Icons.people_outline, size: 16, color: iconColor),
            onPressed: () => select('members'),
            child: const Text('Members'),
          ),
          divider(),
          MenuItemButton(
            style: itemStyle(isDestructive: true),
            leadingIcon: Icon(Icons.delete_rounded,
                size: 16, color: ConclaveColors.errorText(isDark)),
            onPressed: () => select('delete'),
            child: Text('Delete Space',
                style: TextStyle(color: ConclaveColors.errorText(isDark))),
          ),
        ],
      ),
    );
  }

  void _moveThread(AxSpace space, List<String> order, int position, int delta) {
    final next = [...order];
    next.insert(position + delta, next.removeAt(position));
    unawaited(onReorderThreads!(space, next).catchError((Object _) {}));
  }

  void _handleThreadMenuItem(
      BuildContext context, AxSpace space, AxThread thread, String action) {
    switch (action) {
      case 'rename':
        unawaited(_showRenameDialog(context, thread));
        break;
      case 'archive':
      case 'unarchive':
        unawaited(_showArchiveDialog(context, thread, action == 'archive'));
        break;
      case 'clearChat':
        unawaited(_showClearChatDialog(context, thread));
        break;
      case 'clearWork':
        unawaited(_showClearWorkDialog(context, thread));
        break;
      case 'delete':
        unawaited(_showDeleteThreadDialog(context, thread));
        break;
    }
  }

  Future<void> _showRenameDialog(BuildContext context, AxThread thread) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameThreadDialog(initialTitle: thread.title),
    );
    if (name == null || name.trim().isEmpty || name.trim() == thread.title) {
      return;
    }
    try {
      await onRenameThread?.call(thread, name.trim());
    } catch (error) {
      if (context.mounted) {
        _showThreadActionError(context, 'rename', error);
      }
    }
  }

  Future<void> _showArchiveDialog(
      BuildContext context, AxThread thread, bool isArchiving) {
    final title = isArchiving ? 'Archive Thread' : 'Unarchive Thread';
    final content = isArchiving
        ? 'This Thread will be moved to archived Threads.'
        : 'This Thread will be moved back to active Threads.';

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(isArchiving ? 'Archive' : 'Unarchive'),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed != true) return;
      try {
        await onSetThreadArchived?.call(thread, isArchiving);
      } catch (error) {
        if (context.mounted) {
          _showThreadActionError(
              context, isArchiving ? 'archive' : 'unarchive', error);
        }
      }
    });
  }

  Future<void> _showClearChatDialog(
      BuildContext context, AxThread thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear Chat History'),
        content: const Text(
          'Delete all chat messages? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear Chat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await onClearChatHistory?.call(thread);
    } catch (error) {
      if (context.mounted) {
        _showThreadActionError(context, 'clear chat history', error);
      }
    }
  }

  Future<void> _showClearWorkDialog(
      BuildContext context, AxThread thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear Work History'),
        content: const Text(
          'Delete all work requests and reset Work context? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear Work'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await onClearWorkHistory?.call(thread);
    } catch (error) {
      if (context.mounted) {
        _showThreadActionError(context, 'clear work history', error);
      }
    }
  }

  Future<void> _showDeleteThreadDialog(
      BuildContext context, AxThread thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Thread'),
        content: const Text(
          'Permanently delete this Thread and all its history? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: ConclaveColors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await onDeleteThread?.call(thread);
    } catch (error) {
      if (context.mounted) {
        _showThreadActionError(context, 'delete thread', error);
      }
    }
  }

  void _showThreadActionError(
      BuildContext context, String action, Object error) {
    ScaffoldMessenger.maybeOf(context)?.showNotice(
      SnackBar(
        content: Text('Failed to $action: $error'),
        backgroundColor: ConclaveColors.error,
      ),
    );
  }

  Widget? _buildThreadStatusIndicator(String status) {
    switch (status.toLowerCase()) {
      case 'running':
      case 'executing':
        return Container(
          width: 6.5,
          height: 6.5,
          decoration: BoxDecoration(
            color: ConclaveColors.primaryForegroundDark,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color:
                    ConclaveColors.primaryForegroundDark.withValues(alpha: 0.4),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      case 'queued':
      case 'ready':
      case 'scheduled':
        return Container(
          width: 6.5,
          height: 6.5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: ConclaveColors.textSecondaryLight,
              width: 1.2,
            ),
          ),
        );
      case 'blocked':
      case 'failed':
      case 'attention':
      case 'needs_approval':
        return Container(
          width: 6.5,
          height: 6.5,
          decoration: const BoxDecoration(
            color: ConclaveColors.warning,
            shape: BoxShape.circle,
          ),
        );
      case 'idle':
      case 'done':
      case 'completed':
      default:
        return null;
    }
  }
}

class _RenameThreadDialog extends StatefulWidget {
  const _RenameThreadDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameThreadDialog> createState() => _RenameThreadDialogState();
}

class _RenameThreadDialogState extends State<_RenameThreadDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename Thread'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) {
            Navigator.pop(context, value);
          }
        },
        decoration: const InputDecoration(
          labelText: 'Thread name',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _controller.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Vector folder icon rendering clean line-art closed/open folder states.
class ConclaveFolderIcon extends StatelessWidget {
  const ConclaveFolderIcon({
    super.key,
    required this.isExpanded,
    this.size = 16,
    this.color,
  });

  final bool isExpanded;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color ?? Colors.white70;
    return CustomPaint(
      size: Size(size, size),
      painter: _FolderPainter(
        isExpanded: isExpanded,
        color: iconColor,
      ),
    );
  }
}

/// Sidebar activity markers share one dot: solid for unread messages, and a
/// slow, faint fade in and out while Work is running, so it stays in the
/// periphery. Both are exposed to assistive technology.
class _ActivityIndicators extends StatefulWidget {
  const _ActivityIndicators({required this.running, required this.unread});
  final bool running;
  final bool unread;

  @override
  State<_ActivityIndicators> createState() => _ActivityIndicatorsState();
}

class _ActivityIndicatorsState extends State<_ActivityIndicators>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2800));

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_ActivityIndicators oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.running) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _dot(Key key, String label, Widget Function(Widget dot) wrap) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Semantics(
        label: label,
        child: Tooltip(
          message: label,
          child: wrap(Container(
            key: key,
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: ConclaveBrand.accent,
              shape: BoxShape.circle,
            ),
          )),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.running && !widget.unread) return const SizedBox.shrink();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.running)
          _dot(
            const ValueKey('sidebar-running-indicator'),
            'Running',
            (dot) => reduceMotion
                ? Opacity(opacity: 0.4, child: dot)
                : FadeTransition(
                    opacity: Tween<double>(begin: 0.12, end: 0.55).animate(
                        CurvedAnimation(
                            parent: _pulse, curve: Curves.easeInOut)),
                    child: dot,
                  ),
          ),
        if (widget.unread)
          _dot(const ValueKey('sidebar-unread-indicator'), 'Unread messages',
              (dot) => dot),
      ],
    );
  }
}

class _FolderPainter extends CustomPainter {
  const _FolderPainter({
    required this.isExpanded,
    required this.color,
  });

  final bool isExpanded;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale);

    if (!isExpanded) {
      // Clean modern closed folder stroke
      final path = Path()
        ..moveTo(3, 7)
        ..lineTo(3, 17)
        ..arcToPoint(const Offset(5, 19), radius: const Radius.circular(2))
        ..lineTo(19, 19)
        ..arcToPoint(const Offset(21, 17), radius: const Radius.circular(2))
        ..lineTo(21, 9)
        ..arcToPoint(const Offset(19, 7), radius: const Radius.circular(2))
        ..lineTo(13, 7)
        ..lineTo(11, 5)
        ..lineTo(5, 5)
        ..arcToPoint(const Offset(3, 7), radius: const Radius.circular(2))
        ..close();
      canvas.drawPath(path, paint);
    } else {
      // Clean modern open folder stroke with back tab and front open tray
      final backTab = Path()
        ..moveTo(4, 20)
        ..arcToPoint(const Offset(2, 18), radius: const Radius.circular(2))
        ..lineTo(2, 5)
        ..arcToPoint(const Offset(4, 3), radius: const Radius.circular(2))
        ..lineTo(7.9, 3)
        ..lineTo(9.6, 5)
        ..lineTo(18, 5)
        ..arcToPoint(const Offset(20, 7), radius: const Radius.circular(2))
        ..lineTo(20, 9);
      canvas.drawPath(backTab, paint);

      final frontTray = Path()
        ..moveTo(2, 18)
        ..lineTo(4.5, 10.5)
        ..arcToPoint(const Offset(6.5, 9.5), radius: const Radius.circular(1.5))
        ..lineTo(20, 9.5)
        ..arcToPoint(const Offset(21.8, 11.5),
            radius: const Radius.circular(1.5))
        ..lineTo(19.8, 17.8)
        ..arcToPoint(const Offset(18, 19.8), radius: const Radius.circular(1.8))
        ..lineTo(4, 19.8)
        ..arcToPoint(const Offset(2, 18), radius: const Radius.circular(1.8))
        ..close();
      canvas.drawPath(frontTray, paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_FolderPainter oldDelegate) =>
      oldDelegate.isExpanded != isExpanded || oldDelegate.color != color;
}

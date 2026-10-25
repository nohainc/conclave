import 'dart:async';
import '../common/quiet_notices.dart';
import '../common/thread_dialogs.dart';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

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
    this.onDeleteThread,
    this.onReorderThreads,
    this.onSetSpacePinned,
    this.onSetThreadPinned,
    this.onReorderPinnedSpaces,
    this.onReorderPinnedThreads,
    this.compact = false,
    this.pageLayout = false,
    this.spaceIdFilter,
    this.onOpenInvitations,
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
  final Future<void> Function(AxThread thread)? onDeleteThread;

  /// Persists a Space's Thread order (visible Thread ids, top to bottom).
  final Future<void> Function(AxSpace space, List<String> orderedThreadIds)?
      onReorderThreads;

  /// Pins or unpins for the signed-in user only.
  final Future<void> Function(AxSpace space, bool pinned)? onSetSpacePinned;
  final Future<void> Function(AxThread thread, bool pinned)? onSetThreadPinned;

  /// Stores the user's order of pinned Spaces / of a Space's pinned Threads.
  final Future<void> Function(List<String> orderedIds)? onReorderPinnedSpaces;
  final Future<void> Function(AxSpace space, List<String> orderedIds)?
      onReorderPinnedThreads;
  final bool compact;
  final bool pageLayout;
  final String? spaceIdFilter;
  final VoidCallback? onOpenInvitations;
  final bool narrow;

  @override
  Widget build(BuildContext context) =>
      SidebarPulse(child: Builder(builder: _buildContent));

  Widget _buildContent(BuildContext context) {
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
    final invitations =
        spaceIdFilter == null ? shellContext.invitations : const [];
    // Pinned Spaces lead the list; the rest keep their usual groups.
    final pinnedSpaces = [
      for (final space in shellContext.spaces)
        if (space.isPinned &&
            (spaceIdFilter == null || space.id == spaceIdFilter))
          space
    ]..sort(compareAxPins);
    final ownedSpaces = shellContext.ownedSpaces
        .where((space) =>
            !space.isPinned &&
            (spaceIdFilter == null || space.id == spaceIdFilter))
        .toList();
    final sharedSpaces = shellContext.sharedSpaces
        .where((space) =>
            !space.isPinned &&
            (spaceIdFilter == null || space.id == spaceIdFilter))
        .toList();
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
              onTap: onOpenInvitations ??
                  () => onNavigateTo(const AxNavigation.home()),
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
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 14,
                    color: ConclaveColors.navigationTextMuted(
                        Theme.of(context).brightness == Brightness.dark),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (shellContext.spaces.isEmpty && invitations.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              'No spaces yet',
              style: TextStyle(
                fontSize: 11.5,
                color: ConclaveColors.navigationTextMuted(
                    Theme.of(context).brightness == Brightness.dark),
              ),
            ),
          ),
        // Pinned Spaces lead the list, without a group of their own.
        ...pinnedSpaces.map((space) => _buildSpaceItem(context, space)),
        if (ownedSpaces.isNotEmpty) ...[
          if (sharedSpaces.isNotEmpty) _groupLabel(context, 'YOUR SPACES'),
          ...ownedSpaces.map((space) => _buildSpaceItem(context, space)),
        ],
        if (sharedSpaces.isNotEmpty) ...[
          _groupLabel(context, 'SHARED WITH YOU'),
          ...sharedSpaces.map((space) => _buildSpaceItem(context, space)),
        ],
      ],
    );
  }

  Widget _groupLabel(BuildContext context, String label) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 8, 6),
      child: Text(label,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: ConclaveColors.navigationTextMuted(
                  Theme.of(context).brightness == Brightness.dark))));

  Widget _buildSpaceItem(BuildContext context, AxSpace space) {
    final cache = shellContext.spaceThreads;
    if (cache != null) {
      return AxQueryBuilder<List<AxThread>>(
        key: ValueKey('space-threads-${space.id}'),
        engine: cache.engine,
        query: cache.query(space.id),
        ensure: shellContext.isSpaceExpanded(space.id),
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
    final sortedThreads = applyAxThreadPins(sortAxThreadsByLastUpdate(threads));
    final visibleThreads = sortedThreads
        .where((t) => !t.archived && t.status.toLowerCase() != 'archived')
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SidebarHoverRow(
          key: ValueKey('sidebar-space-row-${space.id}'),
          actionsLabel: 'Space actions',
          enabled: !space.id.startsWith('local-space-'),
          builder: (context, hovered, menuOpenChanged, menuController) {
            final isSpaceActive = isSpaceFocused ||
                hovered ||
                (pageLayout && shellContext.selectedSpace?.id == space.id);
            return Container(
              height: pageLayout ? 52 : _sidebarRowHeight,
              decoration: BoxDecoration(
                color: isSpaceActive
                    ? ConclaveColors.navigationSelectedColor(
                        Theme.of(context).brightness == Brightness.dark)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: InkWell(
                hoverColor: Colors.transparent,
                onTap: space.id.startsWith('local-space-') ||
                        space.id.startsWith('local-space-')
                    ? null
                    : () {
                        if (pageLayout) {
                          onToggleSpaceExpanded?.call(space.id);
                          return;
                        }
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
                      Builder(builder: (context) {
                        // Collapsed Spaces hide their Threads, so the folder
                        // carries the roll-up: running stays visible until work ends.
                        final anyUnread = threads.isNotEmpty
                            ? threads.any((t) => t.hasUnread)
                            : space.hasUnread;
                        final anyRunning = space.hasActiveWork ||
                            threads.any((t) => t.hasActiveWork);
                        return SizedBox(
                          width: 16,
                          height: 16,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ConclaveFolderIcon(
                                isExpanded: isExpanded,
                                size: 16,
                                color: ConclaveColors.navigationTextMuted(
                                    Theme.of(context).brightness ==
                                        Brightness.dark),
                              ),
                              if (!isExpanded)
                                Positioned(
                                  right: -3,
                                  top: -2,
                                  child: SidebarActivityIndicators(
                                    running: anyRunning,
                                    unread: anyUnread,
                                    gap: 0,
                                  ),
                                ),
                            ],
                          ),
                        );
                      }),
                      SizedBox(width: narrow ? 2 : 8),
                      Expanded(
                        child: Text(
                          space.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ConclaveColors.navigationTextMuted(
                                Theme.of(context).brightness ==
                                    Brightness.dark),
                            fontSize: pageLayout ? 15 : 12.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      if (space.isPinned && isSpaceActive)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.push_pin_outlined,
                              size: 12,
                              color: ConclaveColors.navigationTextMuted(
                                  Theme.of(context).brightness ==
                                      Brightness.dark)),
                        ),
                      if (pageLayout &&
                          isSpaceActive &&
                          onCreateThread != null &&
                          space.effectivePermissions.manageOwnThreads)
                        IconButton(
                          tooltip: 'New Thread',
                          icon: const Icon(Icons.add_rounded, size: 20),
                          onPressed: () => onCreateThread!(space),
                        ),
                      isSpaceActive
                          ? _spaceMenu(
                              context, space, menuOpenChanged, menuController)
                          : const SizedBox(width: _menuSlotWidth),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        if (isExpanded && loading)
          Padding(
              padding: const EdgeInsets.fromLTRB(34, 6, 10, 6),
              child: Text('Loading Threads…',
                  style: TextStyle(
                      color: ConclaveColors.navigationTextMuted(
                          Theme.of(context).brightness == Brightness.dark),
                      fontSize: 11.5))),
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

              return _SidebarHoverRow(
                key: ValueKey('sidebar-thread-row-${thread.id}'),
                actionsLabel: 'Thread actions',
                enabled: !thread.id.startsWith('local-thread-'),
                builder: (context, hovered, menuOpenChanged, menuController) {
                  final isThreadActive = isThreadSelected || hovered;
                  return InkWell(
                    hoverColor: Colors.transparent,
                    onTap: thread.id.startsWith('local-thread-') ||
                            thread.id.startsWith('local-thread-')
                        ? null
                        : () {
                            onNavigateTo(
                                AxNavigation.thread(space.id, thread.id));
                            if (compact) {
                              Scaffold.maybeOf(context)?.closeDrawer();
                            }
                          },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      height: pageLayout ? 52 : _sidebarRowHeight,
                      padding: const EdgeInsets.only(left: 8, right: 2),
                      decoration: BoxDecoration(
                        color: isThreadActive
                            ? ConclaveColors.navigationSelectedColor(
                                Theme.of(context).brightness == Brightness.dark)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          // Leading slot sits under the Space folder icon, so the
                          // title stays put and the right edge stays clear.
                          SizedBox(
                            width: narrow ? 10 : 26,
                            child: SidebarActivityIndicators(
                              running: thread.hasActiveWork,
                              unread: thread.hasUnread && !isThreadSelected,
                              gap: narrow ? 0 : 4,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              thread.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ConclaveColors.navigationTextMuted(
                                    Theme.of(context).brightness ==
                                        Brightness.dark),
                                fontSize: pageLayout ? 15 : 11.5,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          if (statusIndicator != null) ...[
                            const SizedBox(width: 8),
                            statusIndicator,
                          ],
                          // Like the menu, only on the active row; same spot as
                          // the Space pin, just left of the menu slot.
                          if (thread.isPinned && isThreadActive)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.push_pin_outlined,
                                  size: 12,
                                  color: ConclaveColors.navigationTextMuted(
                                      Theme.of(context).brightness ==
                                          Brightness.dark)),
                            ),
                          isThreadActive
                              ? _threadMenu(
                                  context,
                                  space,
                                  thread,
                                  menuOpenChanged,
                                  menuController,
                                  visibleThreads.map((t) => t.id).toList(),
                                  visibleThreads
                                      .where((t) => t.isPinned)
                                      .map((t) => t.id)
                                      .toList())
                              : const SizedBox(width: _menuSlotWidth),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }

  Widget _threadMenu(BuildContext context, AxSpace space, AxThread thread,
      ValueChanged<bool> menuOpenChanged, MenuController menuController,
      [List<String> visibleOrder = const [],
      List<String> pinnedOrder = const []]) {
    final isPinnedHere = thread.isPinned && pinnedOrder.contains(thread.id);
    // Only pinned Threads move, among the pinned ones (your own order).
    final group = isPinnedHere ? pinnedOrder : const <String>[];
    final canReorder = isPinnedHere && onReorderPinnedThreads != null;
    final position = group.indexOf(thread.id);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isArchived =
        thread.archived || thread.status.toLowerCase() == 'archived';
    final menuStyle = ConclaveMenuStyle.surface(isDark);
    ButtonStyle itemStyle({bool isDestructive = false}) =>
        ConclaveMenuStyle.item(isDark, isDestructive: isDestructive);

    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Divider(
            height: 1,
            thickness: 1,
            color: ConclaveColors.navigationBorder(isDark),
          ),
        );

    final menuIconColor = ConclaveColors.textPrimary(isDark);

    void select(String action) =>
        _handleThreadMenuItem(context, space, thread, action);

    return SizedBox(
      width: pageLayout ? 44 : 28,
      height: pageLayout ? 44 : 28,
      child: MenuAnchor(
        controller: menuController,
        style: menuStyle,
        onOpen: () => menuOpenChanged(true),
        onClose: () => menuOpenChanged(false),
        builder: (context, controller, child) {
          return Semantics(
              label: 'Thread menu',
              child: Tooltip(
                  message: 'Thread menu',
                  excludeFromSemantics: true,
                  child: IconButton(
                    icon: Icon(
                      Icons.more_vert,
                      color: ConclaveColors.navigationTextMuted(
                          Theme.of(context).brightness == Brightness.dark),
                      size: 18,
                    ),
                    splashRadius: 14,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    },
                  )));
        },
        menuChildren: [
          // Only offer moves that can change the pinned order.
          if (canReorder && position > 0)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(Icons.arrow_upward_rounded,
                  size: 16, color: menuIconColor),
              onPressed: () => _moveThread(space, group, position, -1),
              child: const Text(
                'Move Up',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          if (canReorder && position >= 0 && position < group.length - 1)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(Icons.arrow_downward_rounded,
                  size: 16, color: menuIconColor),
              onPressed: () => _moveThread(space, group, position, 1),
              child: const Text(
                'Move Down',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          if (onSetThreadPinned != null && !isArchived)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                  thread.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 16,
                  color: menuIconColor),
              onPressed: () => select(thread.isPinned ? 'unpin' : 'pin'),
              child: Text(
                thread.isPinned ? 'Unpin Thread' : 'Pin Thread',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w500),
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

  Widget _spaceMenu(BuildContext context, AxSpace space,
      ValueChanged<bool> menuOpenChanged, MenuController menuController) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pinnedOrder = ([
      for (final item in shellContext.spaces)
        if (item.isPinned) item
    ]..sort(compareAxPins))
        .map((item) => item.id)
        .toList();
    final pinnedPosition = pinnedOrder.indexOf(space.id);
    final canReorderPins = space.isPinned && onReorderPinnedSpaces != null;
    final menuStyle = ConclaveMenuStyle.surface(isDark);
    ButtonStyle itemStyle({bool isDestructive = false}) =>
        ConclaveMenuStyle.item(isDark, isDestructive: isDestructive);

    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Divider(
            height: 1,
            color: ConclaveColors.navigationBorder(isDark),
          ),
        );

    final iconColor = ConclaveColors.textPrimary(isDark);
    void select(String action) {
      switch (action) {
        case 'pin':
        case 'unpin':
          unawaited(onSetSpacePinned?.call(space, action == 'pin'));
          break;
        case 'edit':
          unawaited(onEditSpace?.call(space));
          break;
        case 'archive':
          unawaited(onArchiveSpace?.call(space));
          break;
        case 'delete':
          unawaited(onDeleteSpace?.call(space));
          break;
      }
    }

    return SizedBox(
      width: pageLayout ? 44 : 28,
      height: pageLayout ? 44 : 28,
      child: MenuAnchor(
        controller: menuController,
        style: menuStyle,
        onOpen: () => menuOpenChanged(true),
        onClose: () => menuOpenChanged(false),
        builder: (context, controller, child) => Semantics(
            label: 'Space menu',
            child: Tooltip(
                message: 'Space menu',
                excludeFromSemantics: true,
                child: IconButton(
                  icon: Icon(Icons.more_vert,
                      color: ConclaveColors.navigationTextMuted(
                          Theme.of(context).brightness == Brightness.dark),
                      size: 18),
                  splashRadius: 14,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                ))),
        menuChildren: [
          if (canReorderPins && pinnedPosition > 0)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon:
                  Icon(Icons.arrow_upward_rounded, size: 16, color: iconColor),
              onPressed: () => _moveSpace(pinnedOrder, pinnedPosition, -1),
              child: const Text('Move Up'),
            ),
          if (canReorderPins &&
              pinnedPosition >= 0 &&
              pinnedPosition < pinnedOrder.length - 1)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(Icons.arrow_downward_rounded,
                  size: 16, color: iconColor),
              onPressed: () => _moveSpace(pinnedOrder, pinnedPosition, 1),
              child: const Text('Move Down'),
            ),
          if (onSetSpacePinned != null)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: Icon(
                  space.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 16,
                  color: iconColor),
              onPressed: () => select(space.isPinned ? 'unpin' : 'pin'),
              child: Text(space.isPinned ? 'Unpin Space' : 'Pin Space'),
            ),
          if (pageLayout)
            MenuItemButton(
              style: itemStyle(),
              leadingIcon: const Icon(Icons.settings_outlined, size: 16),
              onPressed: () => onNavigateTo(AxNavigation.space(space.id)),
              child: const Text('Open Space'),
            ),
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

  void _moveThread(
      AxSpace space, List<String> pinnedOrder, int position, int delta) {
    final next = [...pinnedOrder];
    next.insert(position + delta, next.removeAt(position));
    unawaited(onReorderPinnedThreads!(space, next));
  }

  void _moveSpace(List<String> order, int position, int delta) {
    final next = [...order];
    next.insert(position + delta, next.removeAt(position));
    unawaited(onReorderPinnedSpaces!(next));
  }

  void _handleThreadMenuItem(
      BuildContext context, AxSpace space, AxThread thread, String action) {
    switch (action) {
      case 'pin':
      case 'unpin':
        unawaited(onSetThreadPinned?.call(thread, action == 'pin'));
        break;
      case 'rename':
        unawaited(_showRenameDialog(context, thread));
        break;
      case 'archive':
      case 'unarchive':
        unawaited(_showArchiveDialog(context, thread, action == 'archive'));
        break;
      case 'delete':
        unawaited(_showDeleteThreadDialog(context, thread));
        break;
    }
  }

  Future<void> _showRenameDialog(BuildContext context, AxThread thread) async {
    final name = await showRenameThreadDialog(
      context,
      currentName: thread.title,
    );
    if (name == null) return;
    try {
      await onRenameThread?.call(thread, name);
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
        constraints: ConclaveDialogStyle.small,
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

  Future<void> _showDeleteThreadDialog(
      BuildContext context, AxThread thread) async {
    if (!await confirmDeleteThread(context)) return;
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
        return const SidebarActivityIndicators(
            running: true, unread: false, gap: 0);
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

/// Vector folder icon rendering clean line-art closed/open folder states.
/// Tracks pointer hover for a sidebar row so it shows the selected
/// background, pin, and menu like the active row. A row stays active while
/// its menu is open, so moving into the menu does not dismiss it.
class _SidebarHoverRow extends StatefulWidget {
  const _SidebarHoverRow({
    super.key,
    required this.builder,
    required this.actionsLabel,
    this.enabled = true,
  });

  final String actionsLabel;
  final bool enabled;

  final Widget Function(
      BuildContext context,
      bool hovered,
      ValueChanged<bool> menuOpenChanged,
      MenuController menuController) builder;

  @override
  State<_SidebarHoverRow> createState() => _SidebarHoverRowState();
}

class _SidebarHoverRowState extends State<_SidebarHoverRow> {
  final _menuController = MenuController();
  bool _hovered = false;
  bool _menuOpen = false;

  void _openMenu() {
    // Mount the hover-only anchor before asking it to open.
    setState(() => _menuOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuController.open();
    });
  }

  void _menuOpenChanged(bool open) {
    if (!mounted || _menuOpen == open) return;
    setState(() => _menuOpen = open);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          customSemanticsActions: widget.enabled
              ? {CustomSemanticsAction(label: widget.actionsLabel): _openMenu}
              : null,
          child: GestureDetector(
            onLongPress: widget.enabled ? _openMenu : null,
            child: widget.builder(context, _hovered || _menuOpen,
                _menuOpenChanged, _menuController),
          ),
        ),
      );
}

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
    final iconColor = color ??
        IconTheme.of(context).color ??
        ConclaveColors.navigationTextMuted(
            Theme.of(context).brightness == Brightness.dark);
    return CustomPaint(
      size: Size(size, size),
      painter: _FolderPainter(
        isExpanded: isExpanded,
        color: iconColor,
      ),
    );
  }
}

/// One clock per sidebar, so newly mounted dots join the current pulse.
class SidebarPulse extends StatefulWidget {
  const SidebarPulse({super.key, required this.child});
  final Widget child;

  @override
  State<SidebarPulse> createState() => _SidebarPulseState();
}

class _SidebarPulseState extends State<SidebarPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity = Tween<double>(begin: 0.4, end: 1)
      .chain(CurveTween(curve: Curves.easeInOut))
      .animate(_controller);

  int _users = 0;

  @override
  void initState() {
    super.initState();
    // Create the ticker while this State is active, including reduced motion.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
  }

  void retain() {
    if (_users++ == 0) _controller.repeat(reverse: true);
  }

  void release() {
    if (--_users == 0) _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SidebarPulseScope(
        owner: this,
        child: widget.child,
      );
}

class _SidebarPulseScope extends InheritedWidget {
  const _SidebarPulseScope({required this.owner, required super.child});
  final _SidebarPulseState owner;

  @override
  bool updateShouldNotify(_SidebarPulseScope oldWidget) =>
      owner != oldWidget.owner;
}

/// Solid unread markers and synchronized running pulses, with accessible labels.
/// Place under [SidebarPulse] to share its animation clock.
class SidebarActivityIndicators extends StatefulWidget {
  const SidebarActivityIndicators(
      {super.key, required this.running, required this.unread, this.gap = 8});
  final bool running;
  final bool unread;
  final double gap;

  @override
  State<SidebarActivityIndicators> createState() => _ActivityIndicatorsState();
}

class _ActivityIndicatorsState extends State<SidebarActivityIndicators> {
  _SidebarPulseState? _owner;

  void _syncClock() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final next = widget.running && !reduceMotion
        ? context
            .dependOnInheritedWidgetOfExactType<_SidebarPulseScope>()!
            .owner
        : null;
    if (identical(next, _owner)) return;
    _owner?.release();
    _owner = next;
    _owner?.retain();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncClock();
  }

  @override
  void didUpdateWidget(SidebarActivityIndicators oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  @override
  void dispose() {
    _owner?.release();
    super.dispose();
  }

  Widget _dot(Key key, String label, Widget Function(Widget dot) wrap) {
    return Padding(
      padding: EdgeInsets.only(left: widget.gap),
      child: Semantics(
        label: label,
        child: Semantics(
            label: label,
            child: Tooltip(
              excludeFromSemantics: true,
              message: label,
              child: wrap(Container(
                key: key,
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: ConclaveBrand.accent,
                  shape: BoxShape.circle,
                ),
              )),
            )),
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
                    opacity: _owner!._opacity,
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

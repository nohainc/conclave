import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import 'ax_shell_context.dart';
import '../../ax/sync/ax_query_builder.dart';

/// Interactive Space Tree component for the Conclave AX App Sidebar.
class SpaceTree extends StatelessWidget {
  const SpaceTree({
    super.key,
    required this.shellContext,
    required this.onNavigateTo,
    this.onToggleSpaceExpanded,
    this.onCreateSpace,
    this.onCreateThread,
    this.compact = false,
  });

  final AxShellContext shellContext;
  final ValueChanged<AxNavigation> onNavigateTo;
  final ValueChanged<String>? onToggleSpaceExpanded;
  final VoidCallback? onCreateSpace;
  final ValueChanged<AxSpace>? onCreateThread;
  final bool compact;

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
        shellContext.navigation.kind == AxRouteKind.space;
    final isExpanded = shellContext.isSpaceExpanded(space.id);
    final visibleThreads =
        threads.where((t) => t.status.toLowerCase() != 'archived').toList();
    final archivedThreads =
        threads.where((t) => t.status.toLowerCase() == 'archived').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 2),
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  ConclaveFolderIcon(
                    isExpanded: isExpanded,
                    size: 16,
                    color: isSpaceFocused ? Colors.white : Colors.white54,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      space.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSpaceFocused ? Colors.white : Colors.white70,
                        fontSize: 12.5,
                        fontWeight:
                            isSpaceFocused ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
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
                  margin: const EdgeInsets.only(bottom: 1),
                  padding: const EdgeInsets.fromLTRB(34, 6, 10, 6),
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
                          style: TextStyle(
                            color: isThreadSelected
                                ? Colors.white
                                : Colors.white60,
                            fontSize: 11.5,
                            fontWeight: isThreadSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (statusIndicator != null) ...[
                        const SizedBox(width: 8),
                        statusIndicator,
                      ],
                      if (isThreadSelected)
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: PopupMenuButton<String>(
                            onSelected: (value) => _handleThreadMenuItem(
                              context,
                              space,
                              thread,
                              value,
                            ),
                            itemBuilder: (context) {
                              final isDark = Theme.of(context).brightness == Brightness.dark;
                              final textColor = isDark ? Colors.white : Colors.black87;
                              final errorColor = const Color(0xFFD32F2F);
                              return [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.edit_outlined, size: 18, color: textColor),
                                      const SizedBox(width: 12),
                                      Text('Rename Thread'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: thread.archived ? 'unarchive' : 'archive',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(thread.archived
                                        ? Icons.unarchive_outlined
                                        : Icons.archive_outlined,
                                        size: 18, color: textColor),
                                      const SizedBox(width: 12),
                                      Text(thread.archived ? 'Unarchive Thread' : 'Archive Thread'),
                                    ],
                                  ),
                                ),
                                const PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'clearChat',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.delete_outline, size: 18, color: textColor),
                                      const SizedBox(width: 12),
                                      const Text('Clear Chat History'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'clearWork',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.delete_outline, size: 18, color: textColor),
                                      const SizedBox(width: 12),
                                      Text('Clear Work History', style: TextStyle(color: textColor)),
                                    ],
                                  ),
                                ),
                                const PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.delete_rounded, size: 18, color: errorColor),
                                      const SizedBox(width: 12),
                                      Text('Delete Thread', style: TextStyle(color: errorColor)),
                                    ],
                                  ),
                                ),
                              ];
                            },
                            tooltip: 'Thread menu',
                            padding: const EdgeInsets.all(0),
                            constraints: const BoxConstraints(minWidth: 150),
                            child: const Icon(Icons.more_vert, size: 16),
                          ),
                        ),
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
                Icon(Icons.archive_outlined, size: 12, color: Colors.white38),
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
                  margin: const EdgeInsets.only(bottom: 1),
                  padding: const EdgeInsets.fromLTRB(48, 4, 10, 4),
                  decoration: BoxDecoration(
                    color: isThreadSelected
                        ? ConclaveColors.navigationSelected
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    thread.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isThreadSelected ? Colors.white : Colors.white38,
                      fontSize: 11,
                      fontWeight:
                          isThreadSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  void _handleThreadMenuItem(BuildContext context, AxSpace space, AxThread thread, String action) {
    switch (action) {
      case 'rename':
        _showRenameDialog(context, thread);
        break;
      case 'archive':
      case 'unarchive':
        _showArchiveDialog(context, thread, action == 'archive');
        break;
      case 'clearChat':
        _showClearChatDialog(context, thread);
        break;
      case 'clearWork':
        _showClearWorkDialog(context, thread);
        break;
      case 'delete':
        _showDeleteThreadDialog(context, thread);
        break;
    }
  }

  void _showRenameDialog(BuildContext context, AxThread thread) {
    final controller = TextEditingController(text: thread.title);
    showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Thread'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 1,
          decoration: const InputDecoration(
            labelText: 'Thread name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: controller.text.trim().isEmpty
                ? null
                : () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  void _showArchiveDialog(BuildContext context, AxThread thread, bool isArchiving) {
    final title = isArchiving ? 'Archive Thread' : 'Unarchive Thread';
    final content = isArchiving
        ? 'This Thread will be moved to archived Threads.'
        : 'This Thread will be moved back to active Threads.';

    showDialog<bool>(
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
    );
  }

  void _showClearChatDialog(BuildContext context, AxThread thread) {
    showDialog<bool>(
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
  }

  void _showClearWorkDialog(BuildContext context, AxThread thread) {
    showDialog<bool>(
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
  }

  void _showDeleteThreadDialog(BuildContext context, AxThread thread) {
    showDialog<bool>(
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
              backgroundColor: const Color(0xFFD32F2F),
            ),
            child: const Text('Delete'),
          ),
        ],
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

part of '../spaces_pages.dart';

extension _SpaceWorkspaceTabs on _SpaceWorkspaceState {
  Widget _threadsTab() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'Each Thread is one focused area of team work.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (canManage)
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Create Thread',
                    splashRadius: 20,
                    onPressed: _createThread,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (threadsError != null)
              TextButton(
                  onPressed: () {
                    unawaited(_streams.refresh(widget.space.id).then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {}));
                  },
                  child: const Text('Retry Threads')),
            if (threadsLoading)
              const LinearProgressIndicator()
            else if (threads.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No threads yet.'),
              )
            else
              Column(
                children: [
                  ...threads
                      .asMap()
                      .entries
                      .where((entry) => entry.value.status != 'archived')
                      .map((entry) {
                    final index = entry.key;
                    final thread = entry.value;
                    return _threadListTile(thread, index);
                  }),
                  if (threads.any((item) => item.status == 'archived')) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Archived Threads',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...threads
                        .where((item) => item.status == 'archived')
                        .map((thread) => _threadListTile(
                              thread,
                              threads.indexOf(thread),
                            )),
                  ],
                ],
              ),
          ],
        ),
      );

  Widget _threadListTile(AxThread thread, int index) {
    final archived = thread.status == 'archived';
    final pending = thread.id.startsWith('local-thread-');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        thread.name,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: archived || pending ? null : () => widget.onOpenThread(thread.id),
      trailing: (isOwner || (canManage && thread.canConfigureWork)) && !pending
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isOwner && !archived)
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    tooltip: 'Move up',
                    iconSize: 20,
                    splashRadius: 16,
                    onPressed: index > 0 ? () => _moveThread(index, -1) : null,
                  ),
                if (isOwner && !archived)
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    tooltip: 'Move down',
                    iconSize: 20,
                    splashRadius: 16,
                    onPressed: index < threads.length - 1
                        ? () => _moveThread(index, 1)
                        : null,
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Thread actions',
                  onSelected: (action) {
                    if (action == 'edit') {
                      _editThread(thread);
                    } else if (action == 'archive') {
                      _setThreadArchived(thread, true);
                    } else if (action == 'restore') {
                      _setThreadArchived(thread, false);
                    } else if (action == 'delete') {
                      _deleteThread(thread);
                    }
                  },
                  itemBuilder: (context) => [
                    if (!archived)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Rename'),
                      ),
                    PopupMenuItem(
                      value: archived ? 'restore' : 'archive',
                      child: Text(archived ? 'Restore' : 'Archive'),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete'),
                    ),
                  ],
                ),
              ],
            )
          : null,
    );
  }

  Widget _workspacesTab() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'Workspaces provide execution capacity for your space.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (canManage)
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Connect Workspace',
                    splashRadius: 20,
                    onPressed: _connectWorkspace,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (executionError != null)
              TextButton(
                  onPressed: () {
                    unawaited(_grants.refresh(widget.space.id).then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {}));
                  },
                  child: const Text('Retry Workspace grants')),
            if (executionLoading)
              const LinearProgressIndicator()
            else if (spaceWorkspaces.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No execution workspaces connected yet.'),
              )
            else
              Column(
                children: spaceWorkspaces.map((workspace) {
                  final workspaceName = (workspace['workspaceName'] ??
                          workspace['name'] ??
                          workspace['workspaceId'] ??
                          'Workspace')
                      .toString();
                  final workspaceId =
                      (workspace['workspaceId'] ?? workspace['id'] ?? '')
                          .toString();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      workspaceName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      if (widget.onOpenWorkspace != null) {
                        widget.onOpenWorkspace!(workspaceId);
                      }
                    },
                    trailing: isOwner
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              icon:
                                  const Icon(Icons.security_outlined, size: 18),
                              tooltip: 'Edit Workspace access',
                              onPressed: workspace['optimistic'] == true
                                  ? null
                                  : () => _editWorkspaceAccess(workspace),
                            ),
                            IconButton(
                              icon: const Icon(Icons.link_off, size: 18),
                              tooltip: 'Revoke grant',
                              onPressed: workspace['optimistic'] == true
                                  ? null
                                  : () => _revokeWorkspaceGrant(workspace),
                            ),
                          ])
                        : null,
                  );
                }).toList(),
              ),
          ],
        ),
      );

  String _formatInvitationTime(String raw) {
    if (raw.isEmpty) return '';
    try {
      final parsed = DateTime.parse(raw).toLocal();
      final diff = DateTime.now().difference(parsed);
      if (diff.inSeconds < 60) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return raw;
    }
  }

  Widget _membersTab() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'Space roles control collaboration across team members.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (isOwner)
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Share Space',
                    splashRadius: 20,
                    onPressed: _share,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (membersError != null)
              const Text(
                  'Members could not be loaded. Reopen this tab to try again.'),
            if (membersLoading)
              const LinearProgressIndicator()
            else ...[
              if (members.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Members (${members.length})',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                ...members.map((member) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            ConclaveBrand.accent.withValues(alpha: 0.15),
                        child: Text(
                          (member.displayName.isNotEmpty
                                  ? member.displayName[0]
                                  : member.email.isNotEmpty
                                      ? member.email[0]
                                      : 'M')
                              .toUpperCase(),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: ConclaveBrand.accent,
                          ),
                        ),
                      ),
                      title: Text(
                        member.displayName.isNotEmpty
                            ? member.displayName
                            : member.email,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: member.displayName.isNotEmpty &&
                              member.email.isNotEmpty &&
                              member.displayName != member.email
                          ? Text(member.email)
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Chip(label: Text(member.role)),
                          if (isOwner && member.role != 'owner') ...[
                            const SizedBox(width: 4),
                            PopupMenuButton<String>(
                              tooltip: 'Member actions',
                              onSelected: (action) {
                                if (action == 'role') {
                                  _changeRole(member);
                                } else if (action == 'remove') {
                                  _removeMember(member);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'role',
                                  child: Text('Change role'),
                                ),
                                PopupMenuItem(
                                  value: 'remove',
                                  child: Text('Remove from Space'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    )),
              ] else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No members found.'),
                ),
              if (invitations.isNotEmpty) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Pending invitations (${invitations.length})',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                ...invitations.map((invite) {
                  final timeText = _formatInvitationTime(invite.createdAt);
                  final roleText = invite.role.toUpperCase();
                  final subtitle = timeText.isNotEmpty
                      ? '$roleText · Invited $timeText'
                      : roleText;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.amber.withValues(alpha: 0.15),
                      child: const Icon(
                        Icons.mail_outline,
                        size: 16,
                        color: Colors.amber,
                      ),
                    ),
                    title: Text(
                      invite.email,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: Colors.amber.withValues(alpha: 0.4),
                            ),
                          ),
                          child: const Text(
                            'PENDING',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.amber,
                            ),
                          ),
                        ),
                        if (isOwner) ...[
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 18),
                            tooltip: 'Resend invitation',
                            onPressed: () => _resendInvitation(invite),
                          ),
                          IconButton(
                            icon: const Icon(Icons.cancel_outlined, size: 18),
                            tooltip: 'Revoke invitation',
                            onPressed: () => _revokeInvitation(invite),
                          ),
                        ],
                      ],
                    ),
                  );
                }),
              ],
            ],
          ],
        ),
      );
}

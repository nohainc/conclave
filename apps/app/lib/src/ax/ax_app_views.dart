part of 'ax_app.dart';

extension _AxAppViews on _AxAppStateMixin {
  void _toggleTheme() {
    _updateState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  void _setThemeMode(ThemeMode mode) {
    _updateState(() {
      _themeMode = mode;
    });
  }

  Widget _homeView() => ListenableBuilder(
      listenable: Listenable.merge([
        store.spaces,
        store.workspaces,
        store.executionChanges,
        store.invitations,
        store.unreadNotifications,
        store.productUpdateReadStates,
        store.productUpdatesNotifier,
      ]),
      builder: (context, _) => _HomeThreadCollection(
          spaces: store.spaces.items,
          spaceThreads: store.spaceThreads,
          builder: (continueWorkItems) => AxQueryBuilder<List<AxWorker>>(
              engine: store.syncEngine,
              query: store.catalogs.workers,
              builder: (context, workers) => HomePage(
                spaces: store.spaces.items,
                workspaces: store.workspaces.items,
                workers: workers.data ?? const [],
                invitations: store.invitations.items,
                productUpdates: store.productUpdates,
                productUpdateReadStates: store.productUpdateReadStates.value,
                attentionItems: notifications.map((n) {
                  final kind = switch (n.kind) {
                    AxNotificationKind.threadNeedsInput ||
                    AxNotificationKind.workflowRunNeedsApproval ||
                    AxNotificationKind.approvalRequired =>
                      AxAttentionKind.needsInput,
                    AxNotificationKind.threadFailed ||
                    AxNotificationKind.workflowRunFailed ||
                    AxNotificationKind.failed =>
                      AxAttentionKind.failedExecution,
                    AxNotificationKind.workerCredentialProblem ||
                    AxNotificationKind.workerInstallFailed =>
                      AxAttentionKind.workerProblem,
                    AxNotificationKind.workspaceOffline =>
                      AxAttentionKind.workspaceProblem,
                    AxNotificationKind.threadCompleted ||
                    AxNotificationKind.workflowRunCompleted ||
                    AxNotificationKind.completed =>
                      AxAttentionKind.completed,
                    AxNotificationKind.spaceInvitationReceived ||
                    AxNotificationKind.invitationReceived =>
                      AxAttentionKind.invitation,
                  };
                  final categoryLabel = switch (n.kind) {
                    AxNotificationKind.threadNeedsInput ||
                    AxNotificationKind.workflowRunNeedsApproval ||
                    AxNotificationKind.approvalRequired =>
                      'Needs your input',
                    AxNotificationKind.threadFailed ||
                    AxNotificationKind.workflowRunFailed ||
                    AxNotificationKind.failed =>
                      'Failed execution',
                    AxNotificationKind.workerCredentialProblem =>
                      'Worker needs attention',
                    AxNotificationKind.workerInstallFailed =>
                      'Worker install failed',
                    AxNotificationKind.workspaceOffline => 'Workspace offline',
                    AxNotificationKind.threadCompleted ||
                    AxNotificationKind.workflowRunCompleted ||
                    AxNotificationKind.completed =>
                      'Completed',
                    AxNotificationKind.spaceInvitationReceived ||
                    AxNotificationKind.invitationReceived =>
                      'Space invitation',
                  };
                  final actionLabel = switch (n.kind) {
                    AxNotificationKind.threadNeedsInput ||
                    AxNotificationKind.workflowRunNeedsApproval ||
                    AxNotificationKind.approvalRequired =>
                      'Review →',
                    AxNotificationKind.threadFailed ||
                    AxNotificationKind.workflowRunFailed ||
                    AxNotificationKind.failed =>
                      'Inspect →',
                    AxNotificationKind.workerCredentialProblem => 'Fix →',
                    AxNotificationKind.workerInstallFailed => 'Fix →',
                    AxNotificationKind.workspaceOffline => 'Connect →',
                    AxNotificationKind.threadCompleted ||
                    AxNotificationKind.workflowRunCompleted ||
                    AxNotificationKind.completed =>
                      'Open →',
                    AxNotificationKind.spaceInvitationReceived ||
                    AxNotificationKind.invitationReceived =>
                      'View →',
                  };
                  return AxHomeAttentionItem(
                    id: n.id,
                    kind: kind,
                    categoryLabel: categoryLabel,
                    title: n.title,
                    subtitle: n.message,
                    timestampDisplay: _formatNotificationTime(n.createdAt),
                    actionLabel: actionLabel,
                    spaceId: n.spaceId,
                    threadId: n.threadId,
                    isUnread: !n.read,
                    isActionable: n.kind != AxNotificationKind.completed &&
                        n.kind != AxNotificationKind.threadCompleted &&
                        n.kind != AxNotificationKind.workflowRunCompleted,
                    createdAt: n.createdAt,
                  );
                }).toList(),
                continueWorkItems: continueWorkItems,
                isOffline: store.lifecycle.isOffline,
                onAcceptInvitation: _acceptInvitation,
                onDeclineInvitation: _declineInvitation,
                run: executionSnapshot.run,
                openFindingCount: executionSnapshot.findings
                    .where((finding) => finding.status == FindingStatus.open)
                    .length,
                onOpenWorkspaces: () =>
                    _navigateTo(const AxNavigation.workspaces()),
                onOpenSpace: (spaceId) =>
                    _navigateTo(AxNavigation.space(spaceId)),
                onOpenThread: (spaceId, threadId) =>
                    _navigateTo(AxNavigation.thread(spaceId, threadId)),
                onOpenRun: (spaceId, runId) =>
                    _navigateTo(AxNavigation.run(spaceId, runId)),
                onCreateSpace: _createSpace,
                onOpenNotifications: _showNotifications,
                onOpenWhatsNew: () => AxWhatsNewDialog.show(
                  context,
                  updates: store.productUpdates.isNotEmpty
                      ? store.productUpdates
                      : defaultProductUpdates,
                  readStates: store.productUpdateReadStates.value,
                  onOpenUpdateDetail: (update) =>
                      store.markProductUpdateOpened(update.id),
                  onDismissUpdate: (update) =>
                      store.dismissProductUpdate(update.id),
                ),
                onOpenUpdateDetail: (update) =>
                    store.markProductUpdateOpened(update.id),
                onDismissUpdate: (update) =>
                    store.dismissProductUpdate(update.id),
              ))));

  void _openArchivedSpaces() =>
      _navigateTo(const AxNavigation.archivedSpaces());

  Widget _spaceOverviewView() {
    final space = selectedSpace;
    if (space == null) return _homeView();
    return SpacePage(
      key: ValueKey('space-page-${space.id}'),
      spaceThreads: store.spaceThreads,
      tabQueries: store.spaceTabs,
      mutations: store.collaboration,
      space: space,
      dataSource: widget.dataSource,
      onOpenThread: (threadId) => _openThread(space.id, threadId),
      onEdit: () => _editSpace(space),
      onArchive: () => _archiveSpace(space),
      onDelete: () => _deleteSpace(space.id),
    );
  }

  void _openThread(String spaceId, String threadId) {
    _navigateTo(AxNavigation.thread(spaceId, threadId));
  }

  Widget _threadView() {
    final space = selectedSpace;
    if (space == null) return _homeView();
    return AxQueryBuilder<List<AxThread>>(
      key: ValueKey('thread-page-${space.id}'),
      engine: store.spaceThreads.engine,
      query: store.spaceThreads.query(space.id),
      builder: (context, state) {
        final thread =
            state.data?.where((w) => w.id == navigation.threadId).firstOrNull;
        if (thread == null) {
          return Center(
              child: state.error != null
                  ? TextButton(
                      onPressed: () => store.spaceThreads
                          .ensure(space.id)
                          .then<void>((_) {},
                              onError: (Object _, StackTrace __) {}),
                      child: const Text('Retry Threads'))
                  : Text(state.hasData
                      ? 'Thread unavailable'
                      : 'Loading Thread…'));
        }
        return ThreadPage(
          catalogs: store.catalogs,
          workflowConfigurations: AxWorkflowConfigurations(widget.dataSource,
              engine: store.syncEngine, spaceId: space.id),
          discussionCache: store.discussion,
          workHistoryCache: store.workHistory,
          threadViewStateStore: store.threadViewState,
          key: ValueKey(thread.id),
          space: space,
          thread: thread,
          dataSource: widget.dataSource,
          realtimeEvents: realtimeClient.events,
          currentUserId: store.auth.viewer?.id,
          currentUserName: store.auth.viewer?.displayName,
          onBackToSpace: () => _navigateTo(AxNavigation.space(space.id)),
          onArchive: () async {
            try {
              await store.collaboration.deleteThread(thread);
              if (!mounted) return;
              _showSnackBar('Thread deleted.');
              _navigateTo(AxNavigation.space(space.id));
            } catch (error) {
              if (mounted) _showSnackBar(error.toString());
            }
          },
          onRename: (name) async {
            try {
              await store.collaboration.editThread(
                thread,
                name: name,
              );
              if (mounted) _showSnackBar('Thread updated.');
            } catch (error) {
              if (mounted) _showSnackBar(error.toString());
            }
          },
          onRunWork: (prompt, workflowId, attachments, idempotencyKey) =>
              widget.dataSource.createWorkRequest(
            threadId: thread.id,
            workflowId: workflowId,
            prompt: prompt,
            attachments: attachments,
            idempotencyKey: idempotencyKey,
          ),
          onRunWorkWithSelection:
              (prompt, workflowId, attachments, idempotencyKey, selection) =>
                  widget.dataSource.createWorkRequestWithSelection(
            threadId: thread.id,
            workflowId: workflowId,
            prompt: prompt,
            attachments: attachments,
            executionSelection: selection,
            idempotencyKey: idempotencyKey,
          ),
        );
      },
    );
  }

  Widget _searchView() {
    return ListenableBuilder(
        listenable: store.spaces,
        builder: (context, _) => _searchCollections(
            0,
            () => SearchPage(
                  query: _searchQuery.isNotEmpty
                      ? _searchQuery
                      : _searchQueryController.text.trim(),
                  spaces: store.spaces.items,
                  workspaces: store.workspaces.items,
                  run: executionSnapshot.run,
                  threadsBySpace: {
                    for (final space in store.spaces.items)
                      space.id: store.spaceThreads.peek(space.id),
                  },
                  onNavigateTo: _navigateTo,
                  onSelectSpace: (spaceId) {
                    _clearSearch();
                    _navigateTo(AxNavigation.space(spaceId));
                  },
                  onClearSearch: _clearSearch,
                  onToggleTheme: _toggleTheme,
                  onCreateContextualItem: _handleContextualCreate,
                )));
  }

  Widget _searchCollections(int index, Widget Function() build) {
    if (index >= store.spaces.items.length) return build();
    final query = store.spaceThreads.query(store.spaces.items[index].id);
    // Search watches already cached collections, without eagerly fetching all Spaces.
    return AxQueryBuilder<List<AxThread>>(
        engine: store.syncEngine,
        query: query,
        ensure: false,
        builder: (context, _) => _searchCollections(index + 1, build));
  }

  List<AxWorkspace> _workspaceCards() =>
      store.workspaces.items.map((workspace) {
        final inventoryCount = workspaceWorkers
            .where((worker) =>
                worker.workspaceId == workspace.id &&
                worker.status != 'removed')
            .length;
        return workspace.copyWith(
          workerCount: workspaceWorkerInventoryLoaded
              ? inventoryCount
              : workspace.workerCount,
          lastSeen: workspace.lastSeen,
        );
      }).toList(growable: false);

  Widget _workspacesView() => ListenableBuilder(
      listenable: store.workspaces,
      builder: (context, _) => AxQueryBuilder<List<AxWorker>>(
          engine: store.syncEngine,
          query: store.catalogs.workers,
          builder: (context, _) => WorkspacesPage(
                workspaces: _workspaceCards(),
                workspaceWorkers: workspaceWorkers,
                initialWorkspaceId: navigation.workspaceId,
              )));

  Widget _profileSecurityView() => ListenableBuilder(
      listenable: Listenable.merge(
          [store.security, store.securityLoading, store.securityError]),
      builder: (context, _) => _profileSecurityBody());
  Widget _profileSecurityBody() {
    final viewer = store.auth.viewer;
    final security = accountSecurity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (store.securityError.value != null)
          TextButton(
              onPressed: _loadAccountSecurity,
              child:
                  Text('Retry account security: ${store.securityError.value}')),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: ConclaveColors.primarySoftColor(
                      Theme.of(context).brightness == Brightness.dark),
                  backgroundImage: _shellContext.viewerAvatarImage,
                  child: _shellContext.viewerAvatarImage == null
                      ? Text(
                          _shellContext.viewerInitials,
                          style: TextStyle(
                            color: ConclaveColors.primaryForeground(
                                Theme.of(context).brightness ==
                                    Brightness.dark),
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : null,
                ),
                title: Text(viewer?.displayName ?? 'Conclave user'),
                subtitle: Text(viewer?.email ?? 'Email unavailable'),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _editDisplayName,
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: const Text('Rename'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _editEmail,
                    icon: const Icon(Icons.alternate_email, size: 17),
                    label: const Text('Update email'),
                  ),
                  OutlinedButton.icon(
                    onPressed: avatarUploadBusy ? null : _uploadAvatar,
                    icon: const Icon(Icons.photo_camera_outlined, size: 17),
                    label:
                        Text(avatarUploadBusy ? 'Uploading…' : 'Change avatar'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _profileSection(
          title: 'Linked login methods',
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.accounts.isEmpty ?? true)
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('No linked methods loaded.')),
                    ...?security?.accounts.map((account) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(account.providerId == 'github'
                              ? Icons.code
                              : Icons.account_circle_outlined),
                          title: Text(_providerLabel(account.providerId)),
                          subtitle: Text('Linked account ${account.accountId}'),
                          trailing: const Icon(Icons.verified_outlined,
                              color: Color(0xff3ca879)),
                        )),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _linkAccountProvider('github'),
                          icon: const Icon(Icons.code, size: 17),
                          label: const Text('Link GitHub'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _linkAccountProvider('google'),
                          icon: const Icon(Icons.account_circle_outlined,
                              size: 17),
                          label: const Text('Link Google'),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _profileSection(
          title: 'Active sessions',
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.sessions.isEmpty ?? true)
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('No active sessions loaded.')),
                    ...?security?.sessions.map((session) {
                      final currentSessionId = store.auth.session?.sessionId;
                      final isRevoking =
                          revokingAccountSessionTokens.contains(session.token);
                      final isCurrent = currentSessionId != null &&
                          currentSessionId != '—' &&
                          (session.id == currentSessionId ||
                              session.token == currentSessionId);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.devices_outlined),
                        title: Text(session.userAgent ?? 'Browser session'),
                        subtitle: Text(
                            'Expires ${_formatAccountDate(session.expiresAt)}'),
                        trailing: isCurrent
                            ? const Text('Current',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff3ca879)))
                            : TextButton(
                                onPressed: isRevoking
                                    ? null
                                    : () => _revokeAccountSession(session),
                                child:
                                    Text(isRevoking ? 'Revoking…' : 'Revoke'),
                              ),
                      );
                    }),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _profileSection({
    required String title,
    required Widget child,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );

  String _providerLabel(String provider) => switch (provider) {
        'github' => 'GitHub',
        'google' => 'Google',
        _ => provider,
      };

  String _formatAccountDate(String value) {
    if (value.isEmpty || value == '—') return 'unknown';
    return value.replaceFirst('T', ' ').replaceFirst('Z', ' UTC');
  }

  String _formatNotificationTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

/// Keeps Home's recent-work projection backed by cached per-Space thread
/// collections instead of the deliberately lightweight Space list.
class _HomeThreadCollection extends StatefulWidget {
  const _HomeThreadCollection({
    required this.spaces,
    required this.spaceThreads,
    required this.builder,
  });

  final List<AxSpace> spaces;
  final AxSpaceThreads spaceThreads;
  final Widget Function(List<AxContinueWorkItem>) builder;

  @override
  State<_HomeThreadCollection> createState() => _HomeThreadCollectionState();
}

class _HomeThreadCollectionState extends State<_HomeThreadCollection> {
  VoidCallback? _cancelCache;

  @override
  void initState() {
    super.initState();
    _watchAndEnsure();
  }

  @override
  void didUpdateWidget(covariant _HomeThreadCollection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.spaces.map((space) => space.id).toSet();
    final newIds = widget.spaces.map((space) => space.id).toSet();
    if (oldWidget.spaceThreads != widget.spaceThreads ||
        oldIds.length != newIds.length ||
        oldIds.difference(newIds).isNotEmpty ||
        newIds.difference(oldIds).isNotEmpty) {
      _cancelCache?.call();
      _watchAndEnsure();
    }
  }

  void _watchAndEnsure() {
    _cancelCache = widget.spaceThreads.engine.watchCache(() {
      if (mounted) setState(() {});
    });
    for (final space in widget.spaces) {
      if (space.archived) continue;
      unawaited(widget.spaceThreads.ensure(space.id).then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {},
          ));
    }
  }

  List<AxContinueWorkItem> _items() {
    final items = <AxContinueWorkItem>[];
    for (final space in widget.spaces) {
      if (space.archived) continue;
      for (final thread in widget.spaceThreads.peek(space.id)) {
        if (thread.archived) continue;
        final updatedAt = DateTime.tryParse(thread.updatedAt);
        final createdAt = DateTime.tryParse(thread.createdAt);
        final activityAt = updatedAt ?? createdAt;
        items.add(AxContinueWorkItem(
          spaceId: space.id,
          spaceName: space.name,
          threadId: thread.id,
          threadTitle: thread.name,
          collaboratorsDisplay: thread.leadDisplayName.isNotEmpty
              ? thread.leadDisplayName
              : (thread.lead.isNotEmpty && thread.lead != 'Unassigned'
                  ? thread.lead
                  : (thread.creatorEmail.isNotEmpty
                      ? thread.creatorEmail
                      : 'You and team AI')),
          lastMessageSnippet: thread.brief.isNotEmpty
              ? thread.brief
              : 'Continue conversation and work in context',
          lastActivityDisplay: activityAt == null
              ? (space.lastActivity.isNotEmpty ? space.lastActivity : 'Recently')
              : _formatHomeThreadActivity(activityAt),
          lastMeaningfulActivityAt: activityAt,
        ));
      }
    }
    items.sort((a, b) {
      final aTime = a.lastMeaningfulActivityAt;
      final bTime = b.lastMeaningfulActivityAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
    return items.take(3).toList();
  }

  @override
  void dispose() {
    _cancelCache?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_items());
}

String _formatHomeThreadActivity(DateTime value) {
  final diff = DateTime.now().difference(value);
  if (diff.isNegative || diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${value.month}/${value.day}/${value.year}';
}

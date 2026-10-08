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
      builder: (context, _) => AxQueryBuilder<List<AxWorker>>(
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
                continueWorkItems: _deriveContinueWorkItems(store.spaces.items),
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
              )));

  List<AxContinueWorkItem> _deriveContinueWorkItems(List<AxSpace> spaces) {
    final items = <AxContinueWorkItem>[];
    for (final space in spaces) {
      if (space.archived) continue;
      if (space.threads.isNotEmpty) {
        for (final ws in space.threads) {
          if (ws.archived) continue;
          items.add(AxContinueWorkItem(
            spaceId: space.id,
            spaceName: space.name,
            threadId: ws.id,
            threadTitle: ws.name,
            collaboratorsDisplay: ws.lead.isNotEmpty && ws.lead != 'Unassigned'
                ? ws.lead
                : 'You and team AI',
            lastMessageSnippet: ws.brief.isNotEmpty
                ? ws.brief
                : 'Continue conversation and work in context',
            lastActivityDisplay:
                space.lastActivity.isNotEmpty ? space.lastActivity : 'Recently',
          ));
        }
      } else {
        items.add(AxContinueWorkItem(
          spaceId: space.id,
          spaceName: space.name,
          threadId: 'default',
          threadTitle: 'Main Thread',
          collaboratorsDisplay: 'You and team AI',
          lastMessageSnippet: 'Continue conversation and work in context',
          lastActivityDisplay:
              space.lastActivity.isNotEmpty ? space.lastActivity : 'Recently',
        ));
      }
    }
    return items.take(5).toList();
  }

  Future<void> _showArchivedSpaces() async {
    try {
      final archived =
          await widget.dataSource.loadSpaces(includeArchived: true);
      var inactive = archived.where((space) => space.archived).toList();
      String? restoringSpaceId;
      if (!mounted) return;
      await showDialog<void>(
        context: navigatorKey.currentContext ?? context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Archived Spaces'),
            content: SizedBox(
              width: 520,
              child: inactive.isEmpty
                  ? const Text('No archived Spaces.')
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: inactive.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final space = inactive[index];
                        final restoring = restoringSpaceId == space.id;
                        return ListTile(
                          title: Text(space.name),
                          subtitle: Text(space.description.isEmpty
                              ? 'No description'
                              : space.description),
                          trailing: FilledButton.tonal(
                            onPressed: restoring
                                ? null
                                : () async {
                                    setDialogState(
                                        () => restoringSpaceId = space.id);
                                    try {
                                      await store.collaboration.editSpace(
                                        space,
                                        settings: const {'archived': false},
                                      );
                                      if (dialogContext.mounted) {
                                        setDialogState(() {
                                          inactive = inactive
                                              .where(
                                                  (item) => item.id != space.id)
                                              .toList();
                                          restoringSpaceId = null;
                                        });
                                      }
                                      await store.spaces.refresh();
                                      if (mounted) {
                                        _showSnackBar('Space restored.');
                                      }
                                    } catch (error) {
                                      if (dialogContext.mounted) {
                                        setDialogState(
                                            () => restoringSpaceId = null);
                                      }
                                      if (mounted) {
                                        _showSnackBar(error.toString(),
                                            type: ToastType.error);
                                      }
                                    }
                                  },
                            child: Text(restoring ? 'Restoring…' : 'Restore'),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Widget _spaceOverviewView() {
    final space = selectedSpace;
    if (space == null) return _homeView();
    return SpacePage(
      key: ValueKey('space-page-${space.id}'),
      spaceThreads: store.spaceThreads,
      workspaceGrants: store.spaceWorkspaceGrants,
      tabQueries: store.spaceTabs,
      mutations: store.collaboration,
      space: space,
      dataSource: widget.dataSource,
      onOpenThread: (threadId) => _openThread(space.id, threadId),
      onOpenWorkspace: (workspaceId) =>
          _navigateTo(AxNavigation.workspaces(workspaceId: workspaceId)),
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
          workflowConfigurations: store.workflowConfigurations,
          mutations: store.collaboration,
          workspaceGrants: store.spaceWorkspaceGrants,
          discussionCache: store.discussion,
          workHistoryCache: store.workHistory,
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

  Future<void> _refreshWorkspaceGrantSummary() async {
    try {
      await store.workspaces.list();
    } catch (_) {
      // Preserve the previous aggregate counts while offline.
    }
  }

  Widget _workspacesView() => ListenableBuilder(
      listenable: store.workspaces,
      builder: (context, _) => AxQueryBuilder<List<AxWorker>>(
          engine: store.syncEngine,
          query: store.catalogs.workers,
          builder: (context, _) => WorkspacesPage(
                workspaces: _workspaceCards(),
                workspaceWorkers: workspaceWorkers,
                initialWorkspaceId: navigation.workspaceId,
                onSelectWorkspace: (workspaceId) {
                  if (workspaceId != null) {
                    _navigateTo(
                        AxNavigation.workspaces(workspaceId: workspaceId));
                  } else {
                    _navigateTo(const AxNavigation.workspaces());
                  }
                },
                onOpenDownloads: () => browserNavigation.openExternal(
                  Uri.parse(conclaveDownloadsUrl),
                ),
                onGrant: _grantWorkspace,
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
        Semantics(
          header: true,
          child: const Text('Profile & Security',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 6),
        const Text(
            'Manage your Conclave identity, login methods, sessions, and passkeys.',
            style: TextStyle(color: Color(0xff777683), fontSize: 13)),
        if (store.securityError.value != null)
          TextButton(
              onPressed: _loadAccountSecurity,
              child:
                  Text('Retry account security: ${store.securityError.value}')),
        const SizedBox(height: 24),
        _panel(
          title: 'Profile',
          subtitle: 'Your stable Conclave identity',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: ConclaveColors.primarySoftColor(
                  Theme.of(context).brightness == Brightness.dark),
              child: Text(
                _shellContext.viewerInitials,
                style: TextStyle(
                  color: ConclaveColors.primaryForeground(
                      Theme.of(context).brightness == Brightness.dark),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            title: Text(viewer?.displayName ?? 'Conclave user'),
            subtitle: Text(viewer?.email ?? 'Email unavailable'),
          ),
        ),
        const SizedBox(height: 16),
        _panel(
          title: 'Linked login methods',
          subtitle:
              'Link another verified provider so one provider can be unavailable without locking you out.',
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
        _panel(
          title: 'Active sessions',
          subtitle: 'Revoke access from a device you no longer recognize.',
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.sessions.isEmpty ?? true)
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('No active sessions loaded.')),
                    ...?security?.sessions.map((session) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.devices_outlined),
                          title: Text(session.userAgent ?? 'Browser session'),
                          subtitle: Text(
                              'Expires ${_formatAccountDate(session.expiresAt)}'),
                          trailing: TextButton(
                            onPressed: () => _revokeAccountSession(session),
                            child: const Text('Revoke'),
                          ),
                        )),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _panel(
          title: 'Passkeys',
          subtitle:
              'Use a device or security key to sign in without a password.',
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.passkeys.isEmpty ?? true)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('No passkeys enrolled.'),
                      ),
                    ...?security?.passkeys.map((passkey) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.fingerprint),
                          title: Text(passkey.name),
                          subtitle: Text(passkey.createdAt.isEmpty
                              ? 'WebAuthn credential'
                              : 'Added ${_formatAccountDate(passkey.createdAt)}'),
                          trailing: TextButton(
                            onPressed: () => _deletePasskey(passkey),
                            child: const Text('Remove'),
                          ),
                        )),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _registerPasskey,
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Add passkey'),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

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

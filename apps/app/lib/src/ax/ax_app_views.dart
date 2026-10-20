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

  Widget _homeView() => AxDeferredListenableBuilder(
      listenable: store.homeChanges,
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
                    productUpdateReadStates:
                        store.productUpdateReadStates.value,
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
                        AxNotificationKind.workspaceOffline =>
                          'Workspace offline',
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
                        .where(
                            (finding) => finding.status == FindingStatus.open)
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
    return NewThreadPage(
      key: ValueKey('space-draft-${space.id}'),
      space: space,
      dataSource: widget.dataSource,
      discussionCache: store.discussion,
      workHistoryCache: store.workHistory,
      threadViewStateStore: store.threadViewState,
      catalogs: store.catalogs,
      workflowConfigurations: AxWorkflowConfigurations(widget.dataSource,
          engine: store.syncEngine, spaceId: space.id),
      currentUserId: store.auth.viewer?.id,
      currentUserName: store.auth.viewer?.displayName,
      viewerEmail: store.auth.viewer?.email,
      createThread: (name) =>
          store.collaboration.createThread(spaceId: space.id, name: name),
      onOpenThread: (thread) => _openThread(space.id, thread.id),
    );
  }

  Widget _spaceResourceView(SpacePageSection section) {
    if (section == SpacePageSection.members) return _spaceOverviewView();
    final space = selectedSpace;
    if (space == null) return _homeView();
    return SpacePage(
      key: ValueKey('space-${section.name}-page-${space.id}'),
      section: section,
      spaceThreads: store.spaceThreads,
      tabQueries: store.spaceTabs,
      mutations: store.collaboration,
      workflowConfigurations: AxWorkflowConfigurations(widget.dataSource,
          engine: store.syncEngine, spaceId: space.id),
      space: space,
      dataSource: widget.dataSource,
      viewerEmail: store.auth.viewer?.email,
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
          viewerEmail: store.auth.viewer?.email,
          onBackToSpace: () => _navigateTo(AxNavigation.space(space.id)),
          onClearConversation: () => _clearChatHistory(thread),
          onClearAiHistory: () => _clearWorkHistory(thread),
          onViewStateChanged: (viewState) async {
            await store.collaboration.editThread(thread, viewState: viewState);
          },
          onArchive: () async {
            try {
              await store.collaboration.deleteThread(thread);
              _discardNotificationsFor(threadId: thread.id);
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
          builder: (context, _) => AxQueryBuilder<List<AxPerson>>(
              engine: store.syncEngine,
              query: store.people.query,
              builder: (context, peopleState) => WorkspacesPage(
                    people: peopleState.data ?? const <AxPerson>[],
                    workspaces: _workspaceCards(),
                    workspaceWorkers: workspaceWorkers,
                    initialWorkspaceId: navigation.workspaceId,
                    workflowCatalogs: store.catalogs,
                    workflowConfigurations: store.workflowConfigurations,
                    viewerEmail: store.auth.viewer?.email,
                    memberAccessSource: widget.dataSource
                            is AxWorkspaceMemberAccessDataSource
                        ? widget.dataSource as AxWorkspaceMemberAccessDataSource
                        : null,
                    personAccessSource: widget.dataSource
                            is AxWorkspacePersonAccessDataSource
                        ? widget.dataSource as AxWorkspacePersonAccessDataSource
                        : null,
                    sharingSource:
                        widget.dataSource is AxWorkspaceSharingDataSource
                            ? widget.dataSource as AxWorkspaceSharingDataSource
                            : null,
                  ))));

  Widget _accountProviderIcon(String providerId, {double size = 24}) {
    final provider = providerId.toLowerCase();
    if (provider != 'github' && provider != 'google') {
      return Icon(Icons.account_circle_outlined, size: size);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: ColoredBox(
        color: Colors.white,
        child: Image.asset('assets/auth/$provider.png',
            width: size, height: size, excludeFromSemantics: true),
      ),
    );
  }

  Widget _profileActionLink(
      {required String label,
      required Widget icon,
      required VoidCallback? onTap,
      bool destructive = false}) {
    final color = onTap == null
        ? Theme.of(context).disabledColor
        : destructive
            ? ConclaveColors.errorText(
                Theme.of(context).brightness == Brightness.dark)
            : Theme.of(context).colorScheme.primary;
    return Semantics(
      link: true,
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        mouseCursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            icon,
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 13,
                    decoration: TextDecoration.underline,
                    decorationColor: color)),
          ]),
        ),
      ),
    );
  }

  Widget _profileEditableValue(String value,
          {required String tooltip, required VoidCallback onEdit}) =>
      Row(
        children: [
          Flexible(child: Text(value, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: tooltip,
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 17),
          ),
        ],
      );

  Widget _profileSecurityView() => ListenableBuilder(
      listenable: store.profileSecurityChanges,
      builder: (context, _) => _profileSecurityBody());
  Widget _profileSecurityBody() {
    final viewer = store.auth.viewer;
    final security = accountSecurity;
    // Better Auth can expose its internal credentials account alongside
    // externally linked providers. Credentials are an implementation detail
    // and are not a user-manageable linked login method.
    final linkedAccounts =
        (security?.accounts ?? const <AxAuthAccount>[]).where((account) {
      final providerId = account.providerId.toLowerCase();
      return providerId != 'credential' && providerId != 'credentials';
    }).toList(growable: false);
    final linkedProviders = linkedAccounts
        .map((account) => account.providerId.toLowerCase())
        .toSet();
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
                leading: Tooltip(
                  message: avatarUploadBusy ? 'Uploading…' : 'Change avatar',
                  child: IconButton(
                    key: const ValueKey('profile-avatar-upload'),
                    onPressed: avatarUploadBusy ? null : _uploadAvatar,
                    padding: EdgeInsets.zero,
                    icon: avatarUploadBusy
                        ? const SizedBox(
                            width: 40,
                            height: 40,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : CircleAvatar(
                            backgroundColor: ConclaveColors.primarySoftColor(
                                Theme.of(context).brightness ==
                                    Brightness.dark),
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
                  ),
                ),
                title: _profileEditableValue(
                  viewer?.displayName ?? 'Conclave user',
                  tooltip: 'Edit name',
                  onEdit: _editDisplayName,
                ),
                subtitle: _profileEditableValue(
                  viewer?.email ?? 'Email unavailable',
                  tooltip: 'Edit email',
                  onEdit: _editEmail,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    ...linkedAccounts.map((account) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: _accountProviderIcon(account.providerId),
                          title: Text(_providerLabel(account.providerId)),
                          trailing: Icon(Icons.verified_outlined,
                              color: Theme.of(context).colorScheme.primary),
                        )),
                    const SizedBox(height: 8),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            key: const ValueKey('profile-account-links'),
            children: [
              if (!accountSecurityLoading &&
                  !linkedProviders.contains('github')) ...[
                _profileActionLink(
                    label: 'Link GitHub',
                    icon: Image.asset('assets/auth/github-link.png',
                        width: 24, height: 24, excludeFromSemantics: true),
                    onTap: () => _linkAccountProvider('github')),
                const SizedBox(width: 20),
              ],
              if (!accountSecurityLoading &&
                  !linkedProviders.contains('google')) ...[
                _profileActionLink(
                    label: 'Link Google',
                    icon: Image.asset('assets/auth/google-link.png',
                        width: 24, height: 24, excludeFromSemantics: true),
                    onTap: () => _linkAccountProvider('google')),
                const SizedBox(width: 20),
              ],
              _profileActionLink(
                  label: deletingAccount ? 'Deleting…' : 'Delete account',
                  icon: Icon(Icons.delete_forever_outlined,
                      size: 18,
                      color: ConclaveColors.errorText(
                          Theme.of(context).brightness == Brightness.dark)),
                  destructive: true,
                  onTap: deletingAccount ? null : _deleteAccount),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _profileSection(
          title: 'Active sessions',
          trailing: Builder(builder: (context) {
            final sessions = security?.sessions ?? const <AxAuthSession>[];
            final hasOtherSessions = sessions.any(
              (session) => !_isCurrentAccountSession(session),
            );
            return TextButton(
              onPressed: accountSecurityLoading ||
                      revokingAllAccountSessions ||
                      !hasOtherSessions
                  ? null
                  : _revokeAllAccountSessions,
              child:
                  Text(revokingAllAccountSessions ? 'Revoking…' : 'Revoke all'),
            );
          }),
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.sessions.isEmpty ?? true)
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('No active sessions loaded.')),
                    ...?security?.sessions.map((session) {
                      final isRevoking =
                          revokingAccountSessionTokens.contains(session.token);
                      final isCurrent = _isCurrentAccountSession(session);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(Icons.devices_outlined,
                                  size: 20,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    accountSessionLabel(session.userAgent),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface),
                                    softWrap: true,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(_formatAccountDate(session.expiresAt),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant)),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 96,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: isCurrent
                                    ? Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text('Current',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .primary,
                                                    fontWeight:
                                                        FontWeight.w500)),
                                      )
                                    : TextButton(
                                        onPressed: isRevoking ||
                                                revokingAllAccountSessions
                                            ? null
                                            : () =>
                                                _revokeAccountSession(session),
                                        style: TextButton.styleFrom(
                                          padding: EdgeInsets.zero,
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          alignment: Alignment.centerRight,
                                          textStyle: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                  fontWeight: FontWeight.w500),
                                        ),
                                        child: Text(isRevoking
                                            ? 'Revoking…'
                                            : 'Revoke'),
                                      ),
                              ),
                            ),
                          ],
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
    Widget? trailing,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                if (trailing != null) trailing,
              ],
            ),
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
    final date = DateTime.tryParse(value)?.toUtc();
    if (date == null) return 'Expiry unavailable';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return 'Expires ${date.day} ${months[date.month - 1]} ${date.year}, $hour:$minute UTC';
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
  bool _cacheRebuildPending = false;

  void _cacheChanged() {
    if (!mounted || _cacheRebuildPending) return;
    _cacheRebuildPending = true;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      _cacheRebuildPending = false;
      setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cacheRebuildPending = false;
      if (mounted) setState(() {});
    });
  }

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
    _cancelCache = widget.spaceThreads.engine.watchCache(_cacheChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Timer.run(() {
        if (!mounted) return;
        for (final space in widget.spaces) {
          if (space.archived) continue;
          unawaited(widget.spaceThreads.ensure(space.id).then<void>(
                (_) {},
                onError: (Object _, StackTrace __) {},
              ));
        }
      });
    });
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
              ? (space.lastActivity.isNotEmpty
                  ? space.lastActivity
                  : 'Recently')
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

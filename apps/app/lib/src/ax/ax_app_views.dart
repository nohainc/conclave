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
        store.projects,
        store.workspaces,
        store.executionChanges,
        store.invitations
      ]),
      builder: (context, _) => AxQueryBuilder<List<AxWorker>>(
          engine: store.syncEngine,
          query: store.catalogs.workers,
          builder: (context, workers) => HomePage(
                projects: store.projects.items,
                workspaces: store.workspaces.items,
                workers: workers.data ?? const [],
                invitations: store.invitations.items,
                onAcceptInvitation: _acceptInvitation,
                onDeclineInvitation: _declineInvitation,
                run: executionSnapshot.run,
                openFindingCount: executionSnapshot.findings
                    .where((finding) => finding.status == FindingStatus.open)
                    .length,
                onOpenWorkspaces: () =>
                    _navigateTo(const AxNavigation.workspaces()),
                onOpenProject: (projectId) =>
                    _navigateTo(AxNavigation.project(projectId)),
                onOpenRun: (projectId, runId) =>
                    _navigateTo(AxNavigation.run(projectId, runId)),
                onCreateProject: _createProject,
                onOpenArchivedProjects: _showArchivedProjects,
                onOpenNotifications: _showNotifications,
              )));
  Future<void> _showArchivedProjects() async {
    try {
      final archived =
          await widget.dataSource.loadProjects(includeArchived: true);
      var inactive = archived.where((project) => project.archived).toList();
      String? restoringProjectId;
      if (!mounted) return;
      await showDialog<void>(
        context: navigatorKey.currentContext ?? context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Archived Projects'),
            content: SizedBox(
              width: 520,
              child: inactive.isEmpty
                  ? const Text('No archived Projects.')
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: inactive.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final project = inactive[index];
                        final restoring = restoringProjectId == project.id;
                        return ListTile(
                          title: Text(project.name),
                          subtitle: Text(project.description.isEmpty
                              ? 'No description'
                              : project.description),
                          trailing: FilledButton.tonal(
                            onPressed: restoring
                                ? null
                                : () async {
                                    setDialogState(
                                        () => restoringProjectId = project.id);
                                    try {
                                      await store.collaboration.editProject(
                                        project,
                                        settings: const {'archived': false},
                                      );
                                      if (dialogContext.mounted) {
                                        setDialogState(() {
                                          inactive = inactive
                                              .where((item) =>
                                                  item.id != project.id)
                                              .toList();
                                          restoringProjectId = null;
                                        });
                                      }
                                      await store.projects.refresh();
                                      if (mounted) {
                                        _showSnackBar('Project restored.');
                                      }
                                    } catch (error) {
                                      if (dialogContext.mounted) {
                                        setDialogState(
                                            () => restoringProjectId = null);
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

  Widget _projectOverviewView() {
    final project = selectedProject;
    if (project == null) return _homeView();
    return ProjectPage(
      key: ValueKey('project-page-${project.id}'),
      projectWorkstreams: store.projectWorkstreams,
      workspaceGrants: store.projectWorkspaceGrants,
      tabQueries: store.projectTabs,
      mutations: store.collaboration,
      project: project,
      dataSource: widget.dataSource,
      onOpenWorkstream: (workstreamId) =>
          _openWorkstream(project.id, workstreamId),
      onOpenWorkspace: (workspaceId) =>
          _navigateTo(AxNavigation.workspaces(workspaceId: workspaceId)),
      onEdit: () => _editProject(project),
      onArchive: () => _archiveProject(project),
      onDelete: () => _deleteProject(project.id),
    );
  }

  void _openWorkstream(String projectId, String workstreamId) {
    _navigateTo(AxNavigation.workstream(projectId, workstreamId));
  }

  Widget _workstreamView() {
    final project = selectedProject;
    if (project == null) return _homeView();
    return AxQueryBuilder<List<AxWorkstream>>(
      key: ValueKey('workstream-page-${project.id}'),
      engine: store.projectWorkstreams.engine,
      query: store.projectWorkstreams.query(project.id),
      builder: (context, state) {
        final workstream = state.data
            ?.where((w) => w.id == navigation.workstreamId)
            .firstOrNull;
        if (workstream == null) {
          return Center(
              child: state.error != null
                  ? TextButton(
                      onPressed: () => store.projectWorkstreams
                          .ensure(project.id)
                          .then<void>((_) {},
                              onError: (Object _, StackTrace __) {}),
                      child: const Text('Retry Workstreams'))
                  : Text(state.hasData
                      ? 'Workstream unavailable'
                      : 'Loading Workstream…'));
        }
        return WorkstreamPage(
          catalogs: store.catalogs,
          mutations: store.collaboration,
          workspaceGrants: store.projectWorkspaceGrants,
          discussionCache: store.discussion,
          workHistoryCache: store.workHistory,
          key: ValueKey(workstream.id),
          project: project,
          workstream: workstream,
          dataSource: widget.dataSource,
          realtimeEvents: realtimeClient.events,
          currentUserId: store.auth.viewer?.id,
          currentUserName: store.auth.viewer?.displayName,
          onBackToProject: () => _navigateTo(AxNavigation.project(project.id)),
          onArchive: () async {
            try {
              await store.collaboration.deleteWorkstream(workstream);
              if (!mounted) return;
              _showSnackBar('Workstream deleted.');
              _navigateTo(AxNavigation.project(project.id));
            } catch (error) {
              if (mounted) _showSnackBar(error.toString());
            }
          },
          onRename: (name) async {
            try {
              await store.collaboration.editWorkstream(
                workstream,
                name: name,
              );
              if (mounted) _showSnackBar('Workstream updated.');
            } catch (error) {
              if (mounted) _showSnackBar(error.toString());
            }
          },
          onRunWork: (prompt, workflowId, attachments, idempotencyKey,
                  executionSelection) =>
              widget.dataSource.createWorkRequest(
            workstreamId: workstream.id,
            workflowId: workflowId,
            prompt: prompt,
            attachments: attachments,
            idempotencyKey: idempotencyKey,
            executionSelection: executionSelection,
          ),
        );
      },
    );
  }

  Widget _searchView() {
    return ListenableBuilder(
        listenable: store.projects,
        builder: (context, _) => _searchCollections(
            0,
            () => SearchPage(
                  query: _searchQuery.isNotEmpty
                      ? _searchQuery
                      : _searchQueryController.text.trim(),
                  projects: store.projects.items,
                  workspaces: store.workspaces.items,
                  run: executionSnapshot.run,
                  workstreamsByProject: {
                    for (final project in store.projects.items)
                      project.id: store.projectWorkstreams.peek(project.id),
                  },
                  onNavigateTo: _navigateTo,
                  onSelectProject: (projectId) {
                    _clearSearch();
                    _navigateTo(AxNavigation.project(projectId));
                  },
                  onClearSearch: _clearSearch,
                  onToggleTheme: _toggleTheme,
                  onCreateContextualItem: _handleContextualCreate,
                )));
  }

  Widget _searchCollections(int index, Widget Function() build) {
    if (index >= store.projects.items.length) return build();
    final query =
        store.projectWorkstreams.query(store.projects.items[index].id);
    // Search watches already cached collections, without eagerly fetching all Projects.
    return AxQueryBuilder<List<AxWorkstream>>(
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
}

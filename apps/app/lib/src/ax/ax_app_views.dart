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

  Widget _homeView() => HomePage(
        projects: snapshot.projects,
        workspaces: snapshot.workspaces,
        workers: workspaceWorkers,
        run: snapshot.run,
        openFindingCount: snapshot.findings
            .where((finding) => finding.status == FindingStatus.open)
            .length,
        onOpenWorkspaces: () => _navigateTo(const AxNavigation.workspaces()),
        onOpenProject: (projectId) =>
            _navigateTo(AxNavigation.project(projectId)),
        onOpenRun: (projectId, runId) =>
            _navigateTo(AxNavigation.run(projectId, runId)),
        onCreateProject: _createProject,
        onOpenArchivedProjects: _showArchivedProjects,
      );
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
                                      await widget.dataSource.updateProject(
                                        projectId: project.id,
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
                                      await _loadSnapshot(showSpinner: false);
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
    return AxQueryBuilder<List<AxWorkstream>>(
      key: ValueKey('project-page-${project.id}'),
      engine: store.projectWorkstreams.engine,
      query: store.projectWorkstreams.query(project.id),
      builder: (context, state) => ProjectPage(
        projectWorkstreams: store.projectWorkstreams,
        project: project.copyWith(workstreams: state.data ?? const []),
        dataSource: widget.dataSource,
        onOpenWorkstream: (workstreamId) =>
            _openWorkstream(project.id, workstreamId),
        onOpenWorkspace: (workspaceId) =>
            _navigateTo(AxNavigation.workspaces(workspaceId: workspaceId)),
        onEdit: () => _editProject(project),
        onArchive: () => _archiveProject(project),
        onDelete: () => _deleteProject(project.id),
        onProjectUpdated: (updated) async {
          if (updated.name != project.name ||
              updated.description != project.description ||
              updated.instructions != project.instructions ||
              updated.archived != project.archived ||
              updated.role != project.role ||
              !mapEquals(updated.settings, project.settings)) {
            await store.projectDetails.record(updated);
            if (!mounted) return;
            _updateState(() {
              snapshot = snapshot.copyWith(
                  projects: snapshot.projects
                      .map((p) => p.id == updated.id
                          ? updated.copyWith(workstreams: const [])
                          : p)
                      .toList());
              store.projects.replace(snapshot.projects);
            });
          }
          try {
            await store.projectWorkstreams.refresh(project.id);
          } catch (error) {
            if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
          }
        },
      ),
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
          discussionCache: store.discussion,
          workHistoryCache: store.workHistory,
          key: ValueKey(workstream.id),
          project: project,
          workstream: workstream,
          dataSource: widget.dataSource,
          realtimeEvents: realtimeClient.events,
          currentUserId: store.auth.viewer?.id ?? snapshot.viewer?.id,
          currentUserName:
              store.auth.viewer?.displayName ?? snapshot.viewer?.displayName,
          onBackToProject: () => _navigateTo(AxNavigation.project(project.id)),
          onArchive: () async {
            try {
              await widget.dataSource
                  .deleteWorkstream(workstreamId: workstream.id);
              if (!mounted) return;
              _showSnackBar('Workstream deleted.');
              _navigateTo(AxNavigation.project(project.id));
              await store.projectWorkstreams.refresh(project.id);
            } catch (error) {
              if (mounted) _showSnackBar(error.toString());
            }
          },
          onRename: (name) async {
            try {
              await widget.dataSource.updateWorkstream(
                workstreamId: workstream.id,
                name: name,
              );
              await store.projectWorkstreams.refresh(project.id);
              if (mounted) _showSnackBar('Workstream updated.');
            } catch (error) {
              if (mounted) _showSnackBar(error.toString());
            }
          },
          onRunWork: (prompt, workflowId, attachments) =>
              widget.dataSource.createWorkRequest(
            workstreamId: workstream.id,
            workflowId: workflowId,
            prompt: prompt,
            attachments: attachments,
          ),
        );
      },
    );
  }

  Widget _searchView() {
    return SearchPage(
      query: _searchQuery.isNotEmpty
          ? _searchQuery
          : _searchQueryController.text.trim(),
      snapshot: snapshot.copyWith(
          projects: snapshot.projects
              .map((project) => project.copyWith(
                  workstreams: store.projectWorkstreams.peek(project.id)))
              .toList()),
      onNavigateTo: _navigateTo,
      onSelectProject: (projectId) {
        _clearSearch();
        _navigateTo(AxNavigation.project(projectId));
      },
      onClearSearch: _clearSearch,
      onToggleTheme: _toggleTheme,
      onCreateContextualItem: _handleContextualCreate,
    );
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
          projectGrantCount: workspaceProjectGrantCounts[workspace.id] ?? 0,
          lastSeen: workspace.lastSeen,
        );
      }).toList(growable: false);

  Future<void> _refreshWorkspaceProjectGrantCounts() async {
    final projects = snapshot.projects;
    if (projects.isEmpty) return;
    final counts = <String, int>{};
    await Future.wait(projects.map((project) async {
      try {
        final grants = await widget.dataSource
            .loadProjectWorkspaces(projectId: project.id);
        for (final grant in grants) {
          final workspaceId = grant['workspaceId']?.toString();
          if (workspaceId != null &&
              workspaceId.isNotEmpty &&
              grant['status']?.toString() == 'active') {
            counts.update(workspaceId, (count) => count + 1, ifAbsent: () => 1);
          }
        }
      } catch (_) {
        // Some Projects may not be readable; keep counts from readable ones.
      }
    }));
    if (mounted) _updateState(() => workspaceProjectGrantCounts = counts);
  }

  Widget _workspacesView() => WorkspacesPage(
        workspaces: _workspaceCards(),
        workspaceWorkers: workspaceWorkers,
        initialWorkspaceId: navigation.workspaceId,
        onSelectWorkspace: (workspaceId) {
          if (workspaceId != null) {
            _navigateTo(AxNavigation.workspaces(workspaceId: workspaceId));
          } else {
            _navigateTo(const AxNavigation.workspaces());
          }
        },
        onOpenDownloads: () => browserNavigation.openExternal(
          Uri.parse(conclaveDownloadsUrl),
        ),
        onGrant: _grantWorkspace,
      );

  Widget _profileSecurityView() {
    final viewer = store.auth.viewer ?? snapshot.viewer;
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
        const SizedBox(height: 24),
        _panel(
          title: 'Profile',
          subtitle: 'Your stable Conclave identity',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: const Color(0xffeeecff),
              child: Text(_shellContext.viewerInitials,
                  style: const TextStyle(color: Color(0xff4238a0))),
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

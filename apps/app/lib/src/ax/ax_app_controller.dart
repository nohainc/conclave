part of 'ax_app.dart';

extension _AxAppController on _AxAppStateMixin {
  Future<void> _pollDesktopAuthStatus() async {
    final intentId = _desktopAuthIntentId;
    if (intentId == null ||
        _desktopAuthStatusRequestActive ||
        desktopAuthApproved ||
        desktopAuthCancelled) {
      return;
    }
    _desktopAuthStatusRequestActive = true;
    try {
      final intentStatus = await widget.dataSource.loadDesktopAuthIntentStatus(
        intentId: intentId,
      );
      if (!mounted) return;
      if (intentStatus.status == 'pending') {
        _updateState(() => desktopAuthIntentStatus = intentStatus);
        return;
      }
      browserNavigation.replace(Uri(path: '/'));
      final approved =
          intentStatus.status == 'approved' || intentStatus.status == 'claimed';
      _updateState(() {
        desktopAuthIntentStatus = intentStatus;
        desktopAuthApproved = approved;
        desktopAuthCancelled = !approved;
      });
      _desktopAuthStatusTimer?.cancel();
    } on Object {
      // Temporary network or sign-in errors should not disrupt browser auth.
    } finally {
      _desktopAuthStatusRequestActive = false;
    }
  }

  Future<void> _loadSession() async {
    try {
      final session = await store.auth.load();
      if (!session.authenticated) {
        if (!mounted) return;
        _updateState(() {
          authRequired = true;
          isLoading = false;
        });
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      if (navigation.kind == AxRouteKind.login &&
          navigation.loginReturnTo != null) {
        final target = AxNavigation.fromUri(
          Uri.parse(navigation.loginReturnTo!),
        );
        if (mounted) _updateState(() => navigation = target);
        browserNavigation.replace(target.toUri());
      }
      if (navigation.kind == AxRouteKind.desktopAuthApproval) {
        if (mounted) _updateState(() => isLoading = false);
        return;
      }
      await _loadWorkspaces();
      await _loadSnapshot();
      unawaited(_refreshWorkspaceProjectGrantCounts());
      if (navigation.kind == AxRouteKind.profileSecurity) {
        await _loadAccountSecurity();
      }
    } catch (_) {
      if (mounted) {
        _updateState(() {
          isLoading = false;
          loadError = 'Authentication service is unavailable.';
        });
      }
    }
  }

  Future<void> _logout() async {
    try {
      await store.auth.logout();
      store.clearServerState();
      expandedProjectIds.clear();
      if (!mounted) return;
      _updateState(() {
        snapshot = AxSnapshot.empty();
        selectedProjectId = null;
        authRequired = true;
      });
      browserNavigation.replaceWithLogin(navigation.toUri());
    } catch (error) {
      if (mounted) _updateState(() => loadError = error.toString());
    }
  }

  Future<void> _submitEmailAuth() async {
    final email = authEmailController.text.trim();
    final password = authPasswordController.text;
    final confirmPassword = authConfirmPasswordController.text;
    final resetToken = browserNavigation.current.queryParameters['token'];
    if ((resetToken == null && email.isEmpty) ||
        (password.isEmpty && (!authResetRequest || resetToken != null))) {
      _updateState(() => authError = 'Enter your email and password.');
      return;
    }
    if (authSignUp && authNameController.text.trim().isEmpty) {
      _updateState(() => authError = 'Enter your name.');
      return;
    }
    if ((authSignUp || resetToken != null) && password != confirmPassword) {
      _updateState(() => authError = 'The passwords do not match.');
      return;
    }
    _updateState(() {
      authBusy = true;
      authError = null;
      authNotice = null;
    });
    try {
      if (resetToken != null) {
        await widget.dataSource.resetPassword(
          token: resetToken,
          password: password,
        );
        browserNavigation.replace(Uri(path: '/login'));
        if (mounted) {
          _updateState(() {
            authBusy = false;
            authNotice = 'Password changed. You can sign in now.';
            authPasswordController.clear();
            authConfirmPasswordController.clear();
          });
        }
        return;
      }
      if (authResetRequest) {
        await widget.dataSource.requestPasswordReset(email: email);
        if (mounted) {
          _updateState(() {
            authBusy = false;
            authNotice =
                'If an account exists for that email, a password reset link is on its way.';
          });
        }
        return;
      }
      if (authSignUp) {
        await widget.dataSource.signUpWithEmail(
          name: authNameController.text.trim(),
          email: email,
          password: password,
        );
      } else {
        await widget.dataSource.signInWithEmail(
          email: email,
          password: password,
        );
      }
      if (!mounted) return;
      _updateState(() {
        authBusy = false;
        authRequired = false;
        isLoading = true;
      });
      await _loadSession();
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        authBusy = false;
        authError = error.toString();
      });
    }
  }

  Future<void> _showAboutConclave() {
    final dialogContext = navigatorKey.currentState?.context ?? context;
    return showDialog<void>(
      context: dialogContext,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            ConclaveBrand.logoMark(size: 26),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'About Conclave AX',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Conclave AX coordinates AI Workers across models and machines to research, implement, review, test, and verify complex work.',
                style: TextStyle(fontSize: 13.5, height: 1.45),
              ),
              const SizedBox(height: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xff7c6cf0).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_outlined,
                      size: 14,
                      color: Color(0xff9e95ff),
                    ),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Conclave AX v0.4.0 • Provider-Independent Core',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xff9e95ff),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              browserNavigation
                  .openExternal(Uri.parse('https://conclaveax.com'));
            },
            child: const Text('Visit website'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadWorkspaces() async {
    try {
      final loadedWorkspaces = await store.workspaces.list();
      if (!mounted) return;
      _updateState(
          () => snapshot = snapshot.copyWith(workspaces: loadedWorkspaces));
      try {
        final localWorkers =
            await widget.dataSource.loadWorkspaceWorkerInventory();
        if (mounted) {
          _updateState(() {
            workspaceWorkers = localWorkers;
            workspaceWorkerInventoryLoaded = true;
          });
        }
      } catch (_) {
        // Workspace inventory remains independently optional during registration.
      }
      _startRealtime();
    } catch (_) {
      // Snapshot loading remains the primary path for anonymous development.
    }
  }

  void _onRealtimeEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (!mounted) return;
    if (type == 'realtime.connection') {
      final status = event['status'];
      _updateState(() {
        realtimeStale = status == 'reconnecting';
        realtimeNotice = realtimeStale
            ? 'Live updates paused. Conclave AX is reconnecting.'
            : 'Live updates connected.';
      });
      return;
    }
    if (type == 'realtime.ready') {
      _updateState(() => realtimeStale = false);
      return;
    }
    if (type == 'reconnect.required') {
      final scope = event['scope'];
      final scopeMap = scope is Map
          ? Map<String, dynamic>.from(scope)
          : const <String, dynamic>{};
      _updateState(() {
        realtimeStale = true;
        realtimeNotice =
            'Some live updates were missed. Refreshing the affected view.';
      });
      if (scopeMap['kind'] == 'execution_workspace') {
        unawaited(_refreshRealtimeFeatures('worker.status'));
      } else {
        unawaited(_loadSnapshot(
            projectId: (scopeMap['projectId'] as String?) ?? selectedProjectId,
            showSpinner: false));
      }
      return;
    }
    _lastRealtimeProjectId = event['projectId'] as String?;
    _recordNotification(event);
    if (type is String && type.startsWith('typing')) return;
    if (type is String &&
        (type.startsWith('assignment.progress') ||
            type.startsWith('worker.status') ||
            type.startsWith('heartbeat'))) {
      _announceRealtimeProgress(event);
      return;
    }
    if (type == 'run.input_required' || type == 'run.approval_required') {
      final payload = event['payload'];
      final prompt = payload is Map ? payload['prompt'] : null;
      if (prompt is String && prompt.trim().isNotEmpty) {
        _updateState(() => pendingRunPrompt = prompt.trim());
      }
    }
    _announceRealtimeProgress(event);
    unawaited(_refreshRealtimeFeatures(type is String ? type : ''));
  }

  Future<void> _refreshRealtimeFeatures(String type) async {
    final workspaceId = executionWorkspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    final eventProjectId = _lastRealtimeProjectId;
    if (eventProjectId != null &&
        selectedProjectId != null &&
        eventProjectId != selectedProjectId) {
      return;
    }
    try {
      if (type.startsWith('workspace.')) {
        final workspaces = await store.workspaces.list();
        final localWorkers =
            await widget.dataSource.loadWorkspaceWorkerInventory();
        if (!mounted) return;
        _updateState(() {
          snapshot = snapshot.copyWith(workspaces: workspaces);
          workspaceWorkers = localWorkers;
          workspaceWorkerInventoryLoaded = true;
        });
        return;
      }
      if (type.startsWith('worker.inventory.')) {
        final localWorkers =
            await widget.dataSource.loadWorkspaceWorkerInventory();
        if (!mounted) return;
        _updateState(() {
          workspaceWorkers = localWorkers;
          workspaceWorkerInventoryLoaded = true;
        });
        return;
      }
      if (type.startsWith('project.')) {
        final projects = await store.projects.refresh();
        if (!mounted) return;
        _updateState(() => snapshot = snapshot.copyWith(projects: projects));
        unawaited(_refreshWorkspaceProjectGrantCounts());
        return;
      }
      // Run/Task/Assignment events refresh only the focused execution read
      // model. A reconnect gap still uses the full initial read model.
      if (type.startsWith('run.') ||
          type.startsWith('task.') ||
          type.startsWith('attempt.') ||
          type.startsWith('assignment.') ||
          type.startsWith('artifact.') ||
          type.startsWith('finding.') ||
          type.startsWith('verification.')) {
        await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
      }
    } catch (error) {
      if (mounted) _showSnackBar('Live update refresh failed: $error');
    }
  }

  void _recordNotification(Map<String, dynamic> event) {
    final notification = notificationFromRealtimeEvent(event);
    if (notification == null ||
        notifications.any((item) => item.id == notification.id)) {
      return;
    }
    final currentRunId = snapshot.run?.id ?? snapshot.activeRunId;
    final isViewingRun = showRunDetails &&
        notification.runId != null &&
        notification.runId == currentRunId;
    _updateState(() {
      notifications.insert(
        0,
        isViewingRun ? notification.markRead() : notification,
      );
      if (notifications.length > 50) notifications.removeLast();
    });
  }

  Future<void> _showNotifications() async {
    final dialogContext = navigatorKey.currentState?.context ?? context;
    final orderedNotifications = [...notifications]..sort((a, b) {
        final priority = b.priority.index.compareTo(a.priority.index);
        return priority != 0 ? priority : b.createdAt.compareTo(a.createdAt);
      });
    final selected = await showDialog<AxNotification>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Attention center'),
        content: SizedBox(
          width: 420,
          child: notifications.isEmpty
              ? const Text('You are all caught up.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: orderedNotifications.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final notification = orderedNotifications[index];
                    return ListTile(
                      leading: Icon(
                        switch (notification.kind) {
                          AxNotificationKind.completed =>
                            Icons.check_circle_outline,
                          AxNotificationKind.failed => Icons.error_outline,
                          AxNotificationKind.approvalRequired =>
                            Icons.help_outline,
                          AxNotificationKind.workspaceOffline =>
                            Icons.cloud_off_outlined,
                          AxNotificationKind.workerCredentialProblem =>
                            Icons.key_off_outlined,
                          AxNotificationKind.workerInstallFailed =>
                            Icons.download_for_offline_outlined,
                          AxNotificationKind.invitationReceived =>
                            Icons.mail_outline,
                        },
                        color: notification.read
                            ? const Color(0xff8e8e9a)
                            : notification.priority ==
                                    AxNotificationPriority.high
                                ? const Color(0xffc64b4b)
                                : Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(notification.title),
                      subtitle: Text(
                          '${notification.message} · ${notification.priority.name} priority'),
                      trailing: notification.read
                          ? null
                          : const Icon(Icons.circle, size: 9),
                      onTap: () => Navigator.of(context).pop(notification),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: notifications.isEmpty
                ? null
                : () {
                    _updateState(() {
                      for (var index = 0;
                          index < notifications.length;
                          index++) {
                        notifications[index] = notifications[index].markRead();
                      }
                    });
                    Navigator.of(context).pop();
                  },
            child: const Text('Mark all as read'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    _updateState(() {
      final index = notifications.indexWhere((item) => item.id == selected.id);
      if (index >= 0) notifications[index] = notifications[index].markRead();
    });
    _navigateToNotification(selected);
  }

  void _navigateToNotification(AxNotification notification) {
    switch (notification.target) {
      case AxNotificationTarget.run:
        if (notification.projectId != null && notification.runId != null) {
          _navigateTo(
              AxNavigation.run(notification.projectId!, notification.runId!));
        }
      case AxNotificationTarget.workspaces:
      case AxNotificationTarget.workspace:
        final workspaceId = notification.workspaceId ??
            workspaceWorkers
                .where((worker) => worker.id == notification.workerId)
                .map((worker) => worker.workspaceId)
                .firstOrNull;
        _navigateTo(AxNavigation.workspaces(workspaceId: workspaceId));
      case null:
        break;
    }
  }

  void _announceRealtimeProgress(Map<String, dynamic> event) {
    final now = DateTime.now();
    if (_lastRealtimeAnnouncement != null &&
        now.difference(_lastRealtimeAnnouncement!).inMilliseconds < 750) {
      return;
    }
    final payload = event['payload'];
    final summary = payload is Map
        ? (payload['summary'] ?? payload['status'] ?? payload['phase'])
        : null;
    if (summary is String && summary.trim().isNotEmpty) {
      _lastRealtimeAnnouncement = now;
      _updateState(() => realtimeNotice = summary.trim());
    }
  }

  Future<void> _copyRunDiagnostics() async {
    final run = snapshot.run;
    if (run == null) return;
    final diagnostics = <String, Object?>{
      'format': 'conclave-run-diagnostics-v1',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'workspaceId': snapshot.workspaceId,
      'projectId': selectedProjectId,
      'runId': run.id,
      'status': run.status.name,
      'tasks': snapshot.tasks
          .map((task) => {
                'id': task.id,
                'status': task.status.name,
                'worker': task.worker,
              })
          .toList(),
      'events': snapshot.events
          .map((event) => {
                'eventId': event.eventId,
                'correlationId': event.correlationId,
                'time': event.time,
                'type': event.kind,
                'detail': event.detail,
              })
          .toList(),
    };
    await Clipboard.setData(ClipboardData(text: jsonEncode(diagnostics)));
    if (mounted) _showSnackBar('Run diagnostics copied without secrets.');
  }

  void _startRealtime() {
    final workspaceId = executionWorkspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    if (!realtimeStarted) {
      realtimeStarted = true;
      final apiBaseUrl =
          const String.fromEnvironment('CONCLAVE_API_URL').isNotEmpty
              ? const String.fromEnvironment('CONCLAVE_API_URL')
              : '/api';
      unawaited(
        realtimeClient.connect(
          realtimeEndpointForApi(apiBaseUrl),
          workspaceId,
        ),
      );
    }
    unawaited(realtimeClient.setScopes(
      projectId: selectedProjectId,
      workstreamId: navigation.workstreamId,
      runId: navigation.runId,
      executionWorkspaceId: workspaceId,
    ));
  }

  Future<void> _loadAccountSecurity() async {
    if (!mounted) return;
    _updateState(() => accountSecurityLoading = true);
    try {
      final loaded = await widget.dataSource.loadAccountSecurity();
      if (!mounted) return;
      _updateState(() {
        accountSecurity = loaded;
        accountSecurityLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        accountSecurityLoading = false;
        loadError = error.toString();
      });
    }
  }

  Future<void> _revokeAccountSession(AxAuthSession session) async {
    try {
      await widget.dataSource.revokeAccountSession(session.token);
      await _loadAccountSecurity();
      if (mounted) _showSnackBar('Session revoked.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  Future<void> _linkAccountProvider(String provider) async {
    try {
      final uri = await widget.dataSource
          .beginAccountLink(provider, Uri(path: '/settings/profile'));
      browserNavigation.openExternal(uri);
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  Future<void> _registerPasskey() async {
    try {
      await widget.dataSource.registerPasskey('Conclave AX browser passkey');
      await _loadAccountSecurity();
      if (mounted) {
        _showSnackBar('Passkey added.');
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar(error.toString());
      }
    }
  }

  Future<void> _deletePasskey(AxPasskey passkey) async {
    try {
      await widget.dataSource.deletePasskey(passkey.id);
      await _loadAccountSecurity();
      if (mounted) _showSnackBar('Passkey removed.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  Future<void> _signInWithPasskey(Uri returnTo) async {
    try {
      await widget.dataSource.signInWithPasskey();
      browserNavigation.replace(returnTo);
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  Future<void> _loadSnapshot(
      {String? projectId, String? workspaceId, bool showSpinner = true}) async {
    if (store.auth.session?.authenticated != true) return;
    if (showSpinner) {
      final reconnecting = !isLoading && snapshot.projects.isNotEmpty;
      _updateState(() {
        isLoading = true;
        loadError = null;
        isReconnecting = reconnecting;
      });
    }
    try {
      final loaded =
          await store.reload(projectId: projectId, workspaceId: workspaceId);
      if (!mounted) return;
      _updateState(() {
        snapshot = loaded;
        optimisticRunStatus = null;
        selectedProjectId = loaded.projects.any(
                (project) => project.id == (projectId ?? selectedProjectId))
            ? (projectId ?? selectedProjectId)
            : loaded.projects.firstOrNull?.id;
        isLoading = false;
        isReconnecting = false;
        authRequired = false;
        _applyNavigationToSnapshot(loaded);
        if (loaded.run?.status == RunStatus.paused) {
          // The API is the source of truth; no local pause state is maintained.
        }
      });
      _ensureNavigationResources(navigation);
      _scheduleRefresh(loaded);
    } catch (error) {
      if (!mounted) return;
      if (error is AxApiException && error.statusCode == 401) {
        _updateState(() => authRequired = true);
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      _updateState(() {
        isLoading = false;
        isReconnecting = false;
        loadError = error.toString();
      });
    }
  }

  Future<void> _syncSession() async {
    try {
      final session = await store.auth.load();
      if (!mounted) return;
      if (!session.authenticated && !authRequired) {
        store.clearServerState();
        expandedProjectIds.clear();
        _updateState(() => authRequired = true);
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      if (session.authenticated && authRequired) {
        final target = navigation.loginReturnTo == null
            ? const AxNavigation.home()
            : AxNavigation.fromUri(
                Uri.parse(navigation.loginReturnTo!),
              );
        _updateState(() {
          navigation = target;
          authRequired = false;
          isLoading = true;
          loadError = null;
        });
        browserNavigation.replace(target.toUri());
        await _loadWorkspaces();
        await _loadSnapshot();
      }
    } catch (_) {
      // The normal load/error path will explain an unavailable auth service.
    }
  }

  void _applyNavigationToSnapshot(AxSnapshot loaded) {
    final routeProject = navigation.projectId;
    if (routeProject != null &&
        loaded.projects.any((project) => project.id == routeProject)) {
      selectedProjectId = routeProject;
    }
  }

  /// Navigation is applied synchronously before independent resource requests.
  void _ensureNavigationResources(AxNavigation target) {
    final projectId = target.projectId;
    if (projectId == null || store.auth.session?.authenticated != true) return;
    unawaited(store.projectDetails
        .ensure(projectId)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(store.projectWorkstreams
        .ensure(projectId)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  void _onBrowserNavigation(Uri uri) {
    final next = AxNavigation.fromUri(uri);
    final canonicalUri = next.toUri();
    if (!_isCanonicalWorkspaceUri(uri, canonicalUri)) {
      browserNavigation.replace(canonicalUri);
    }
    if (next == navigation) return;
    _updateState(() {
      navigation = next;
      selectedProjectId = next.projectId ?? selectedProjectId;
      if (next.kind == AxRouteKind.workstream && next.projectId != null) {
        expandedProjectIds.add(next.projectId!);
      }
    });
    if (next.kind == AxRouteKind.profileSecurity) {
      unawaited(_loadAccountSecurity());
    }
    _ensureNavigationResources(next);
    unawaited(realtimeClient.setScopes(
      projectId: next.projectId ?? selectedProjectId,
      workstreamId: next.workstreamId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  bool _isCanonicalWorkspaceUri(Uri actual, Uri canonical) =>
      actual.path == canonical.path &&
      mapEquals(actual.queryParameters, canonical.queryParameters);

  void _navigateTo(AxNavigation next, {bool replace = false}) {
    if (next.kind != AxRouteKind.search &&
        _searchQueryController.text.isNotEmpty) {
      _searchQueryController.removeListener(_onSearchQueryChanged);
      _searchQueryController.clear();
      _searchQuery = '';
      _navigationBeforeSearch = null;
      _searchQueryController.addListener(_onSearchQueryChanged);
    }
    _updateState(() {
      navigation = next;
      selectedProjectId = next.projectId ?? selectedProjectId;
      if (next.kind == AxRouteKind.workstream && next.projectId != null) {
        expandedProjectIds.add(next.projectId!);
      }
    });
    if (replace) {
      browserNavigation.replace(next.toUri());
    } else {
      browserNavigation.push(next.toUri());
    }
    _ensureNavigationResources(next);
    unawaited(realtimeClient.setScopes(
      projectId: next.projectId ?? selectedProjectId,
      workstreamId: next.workstreamId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  void _scheduleRefresh(AxSnapshot loaded) {
    refreshTimer?.cancel();
    if (loaded.run != null &&
        {
          RunStatus.active,
          RunStatus.running,
          RunStatus.waiting,
          RunStatus.paused
        }.contains(loaded.run!.status)) {
      refreshTimer = Timer(const Duration(seconds: 5), () {
        _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
      });
    }
  }

  Future<void> _grantWorkspace(AxWorkspace workspace) async {
    if (snapshot.projects.isEmpty) {
      _showSnackBar('Create a Project before granting Workspace access.');
      return;
    }
    String? selectedProjectId = snapshot.projects.first.id;
    final permissions = <String>{};
    final projectId = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Grant Workspace to Project'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: selectedProjectId,
              decoration: const InputDecoration(labelText: 'Project'),
              items: snapshot.projects
                  .map((project) => DropdownMenuItem(
                      value: project.id, child: Text(project.name)))
                  .toList(),
              onChanged: (value) =>
                  setDialogState(() => selectedProjectId = value),
            ),
            const Text(
                'Work needs repository read and write access. Test steps also need command execution.'),
            for (final entry in const {
              'repository:read': 'Read repository files',
              'repository:write': 'Change repository files',
              'shell:execute': 'Execute commands and tests',
            }.entries)
              CheckboxListTile(
                  title: Text(entry.value),
                  value: permissions.contains(entry.key),
                  onChanged: (value) => setDialogState(() {
                        if (value == true) {
                          permissions.add(entry.key);
                        } else {
                          permissions.remove(entry.key);
                        }
                      })),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selectedProjectId == null
                  ? null
                  : () => Navigator.pop(dialogContext, selectedProjectId),
              child: const Text('Grant access'),
            ),
          ],
        ),
      ),
    );
    if (projectId == null) return;
    try {
      await widget.dataSource.requestProjectWorkspace(
        projectId: projectId,
        workspaceId: workspace.id,
        allowedPermissions: permissions.toList(),
      );
      await _refreshWorkspaceProjectGrantCounts();
      if (mounted) _showSnackBar('Workspace access request sent.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  void _handleContextualCreate() {
    final project = selectedProject;
    if (project != null) {
      _createWorkstream(project);
    } else {
      _createProject();
    }
  }
}

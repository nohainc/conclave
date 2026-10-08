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
      final hydrated = await store.hydrateReadCache();
      if (!mounted) return;
      if (hydrated) {
        _updateState(() {
          authRequired = false;
          isLoading = false;
          loadError = null;
          selectedSpaceId =
              navigation.spaceId ?? store.spaces.items.firstOrNull?.id;
          _applySpaceNavigation();
        });
        _startRealtime();
        _ensureNavigationResources(navigation);
      }
      await _loadWorkspaces();
      await _loadBootstrapState(showSpinner: !hydrated);
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
      await store.logout();
      expandedSpaceIds.clear();
      if (!mounted) return;
      _updateState(() {
        selectedSpaceId = null;
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
      await store.workspaces.list();
      if (!mounted) return;
      try {
        await store.catalogs.ensureWorkers();
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
    final recoveryGeneration = const {
      'reconnect.required',
      'realtime.ready',
      'realtime.connection',
      'realtime.stale'
    }.contains(type)
        ? ++_realtimeRecoveryGeneration
        : _realtimeRecoveryGeneration;
    final routed = store.realtimeCacheRouter.handle(event);
    if (type != 'reconnect.required') {
      unawaited(routed.catchError((Object error) {
        if (mounted) _showSnackBar('Live update refresh failed: $error');
      }));
    }
    if (type == 'realtime.connection') {
      final status = event['status'];
      _realtimeTransportConnected = status == 'connected';
      _updateLiveState(() {
        realtimeStale = status != 'connected';
        realtimeNotice = realtimeStale
            ? 'Live updates paused. Conclave AX is reconnecting.'
            : 'Live updates connected.';
      });
      return;
    }
    if (type == 'realtime.ready') {
      _realtimeTransportConnected = true;
      unawaited(_refreshRealtimeFeatures('space.updated'));
      _updateLiveState(() => realtimeStale = false);
      return;
    }
    if (type == 'reconnect.required') {
      final scope = AxSyncScope.fromEvent(event);
      _updateLiveState(() {
        realtimeStale = true;
        realtimeNotice =
            'Some live updates were missed. Refreshing the affected view.';
      });
      unawaited(_recoverRealtimeScope(scope, routed, recoveryGeneration));
      return;
    }
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
        store.pendingRunPrompt.value = prompt.trim();
      }
    }
    _announceRealtimeProgress(event);
    unawaited(
        _refreshRealtimeFeatures(type is String ? type : '', event: event));
  }

  Future<void> _recoverRealtimeScope(
      AxSyncScope scope, Future<void> routed, int generation) async {
    Future<void> workspaceRecovery() async {
      if (scope.kind == 'execution_workspace' && scope.id != null) {
        await store.resynchronizeWorkspace(scope.id!);
      } else if (scope.kind == 'user') {
        await Future.wait([
          _refreshRealtimeFeatures('space.updated'),
          _refreshRealtimeFeatures('workspace.updated'),
        ]);
      }
    }

    try {
      await Future.wait([routed, workspaceRecovery()]);
      // The shared Work router receives the same transport frame, independently
      // of rendering. Wait for that recovery without delivering it twice.
      await store.workRealtime.pendingRecovery;
      if (!mounted ||
          generation != _realtimeRecoveryGeneration ||
          !_realtimeTransportConnected) {
        return;
      }
      _updateLiveState(() {
        realtimeStale = false;
        realtimeNotice = 'Live updates connected.';
      });
    } catch (error) {
      if (mounted) _showSnackBar('Live update refresh failed: $error');
    }
  }

  Future<void> _refreshRealtimeFeatures(String type,
      {Map<String, dynamic>? event}) async {
    final workspaceId = executionWorkspaceId;
    if (type.startsWith('product.update.') ||
        type.startsWith('product_update.')) {
      final payload = event?['payload'];
      if (payload is Map<String, dynamic>) {
        try {
          final update = AxProductUpdate.fromJson(payload);
          store.addProductUpdate(update);
        } catch (_) {}
      }
      return;
    }
    if ((workspaceId == null || workspaceId.isEmpty) &&
        !type.startsWith('space.') &&
        type != 'space_workspace_grant.updated') {
      return;
    }
    try {
      if (type.startsWith('workspace.')) {
        await Future.wait(
            [store.workspaces.list(), store.catalogs.refreshWorkers()]);
        return;
      }
      if (type.startsWith('worker.inventory.')) {
        // The cache router owns invalidation; the shared query updates consumers.
        return;
      }
      if (type.startsWith('space.invitation.') ||
          type.startsWith('space.invitation.') ||
          type.startsWith('invitation.') ||
          type.startsWith('space.') ||
          type == 'space_workspace_grant.updated') {
        await Future.wait([
          store.spaces.refresh(),
          store.invitations.refresh(),
        ]);
        if (!mounted) return;
        unawaited(_refreshWorkspaceGrantSummary());
        return;
      }
      // Execution events are reconciled by the shared Work router, never by
      // reloading Spaces, Workspaces, authentication, or bootstrap state.
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
    final currentRunId =
        executionSnapshot.run?.id ?? executionSnapshot.activeRunId;
    final isViewingRun = showRunDetails &&
        notification.runId != null &&
        notification.runId == currentRunId;
    _updateNotifications(() {
      notifications.insert(
        0,
        isViewingRun ? notification.markRead() : notification,
      );
      if (notifications.length > 50) notifications.removeLast();
    });
  }

  Future<void> _acceptInvitation(AxSpaceInvitation invite) async {
    try {
      await store.acceptInvitation(invite);
      if (!mounted) return;
      _showSnackBar(
          'Joined ${invite.spaceName.isNotEmpty ? invite.spaceName : "Space"}.');
      if (invite.spaceId.isNotEmpty) {
        _navigateTo(AxNavigation.space(invite.spaceId));
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to accept invitation: $error',
            type: ToastType.error);
      }
    }
  }

  Future<void> _declineInvitation(AxSpaceInvitation invite) async {
    try {
      await store.declineInvitation(invite);
      if (mounted) {
        _showSnackBar('Invitation declined.');
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to decline invitation: $error',
            type: ToastType.error);
      }
    }
  }

  Future<void> _showNotifications() async {
    final dialogContext = navigatorKey.currentState?.context ?? context;
    final orderedNotifications = [...notifications]..sort((a, b) {
        final priority = b.priority.index.compareTo(a.priority.index);
        return priority != 0 ? priority : b.createdAt.compareTo(a.createdAt);
      });
    final selected = await showDialog<AxNotification>(
      context: dialogContext,
      builder: (context) => ListenableBuilder(
        listenable: store.invitations,
        builder: (context, _) {
          final pendingInvitations = store.invitations.items;
          final isEmpty = pendingInvitations.isEmpty && notifications.isEmpty;
          return AlertDialog(
            title: const Text('Inbox'),
            content: SizedBox(
              width: 440,
              child: isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('You are all caught up.'),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (pendingInvitations.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.only(bottom: 8),
                              child: Text(
                                'Pending invitations',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xff8e8e9a),
                                ),
                              ),
                            ),
                            for (final invite in pendingInvitations)
                              Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.mail_outline,
                                              size: 18),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              invite.spaceName.isNotEmpty
                                                  ? invite.spaceName
                                                  : 'Space Invitation',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.1),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              invite.role.toUpperCase(),
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w600,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'Invited by ${invite.invitedByDisplay}',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          OutlinedButton(
                                            onPressed: () => unawaited(
                                                _declineInvitation(invite)),
                                            style: OutlinedButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 12),
                                            ),
                                            child: const Text('Decline'),
                                          ),
                                          const SizedBox(width: 8),
                                          FilledButton(
                                            onPressed: () {
                                              Navigator.of(context).pop();
                                              unawaited(
                                                  _acceptInvitation(invite));
                                            },
                                            style: FilledButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 12),
                                            ),
                                            child: const Text('Accept'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (notifications.isNotEmpty)
                              const Divider(height: 24),
                          ],
                          if (notifications.isNotEmpty) ...[
                            if (pendingInvitations.isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Activity',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff8e8e9a),
                                  ),
                                ),
                              ),
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: orderedNotifications.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final notification =
                                    orderedNotifications[index];
                                return ListTile(
                                  leading: Icon(
                                    switch (notification.kind) {
                                      AxNotificationKind.threadNeedsInput ||
                                      AxNotificationKind
                                          .workflowRunNeedsApproval ||
                                      AxNotificationKind.approvalRequired =>
                                        Icons.help_outline,
                                      AxNotificationKind.threadFailed ||
                                      AxNotificationKind.workflowRunFailed ||
                                      AxNotificationKind.failed =>
                                        Icons.error_outline,
                                      AxNotificationKind.threadCompleted ||
                                      AxNotificationKind.workflowRunCompleted ||
                                      AxNotificationKind.completed =>
                                        Icons.check_circle_outline,
                                      AxNotificationKind.workspaceOffline =>
                                        Icons.cloud_off_outlined,
                                      AxNotificationKind
                                            .workerCredentialProblem =>
                                        Icons.key_off_outlined,
                                      AxNotificationKind.workerInstallFailed =>
                                        Icons.download_for_offline_outlined,
                                      AxNotificationKind.spaceInvitationReceived ||
                                      AxNotificationKind
                                          .spaceInvitationReceived ||
                                      AxNotificationKind.invitationReceived =>
                                        Icons.mail_outline,
                                    },
                                    color: notification.read
                                        ? const Color(0xff8e8e9a)
                                        : notification.priority ==
                                                AxNotificationPriority.high
                                            ? const Color(0xffc64b4b)
                                            : Theme.of(context)
                                                .colorScheme
                                                .primary,
                                  ),
                                  title: Text(notification.title),
                                  subtitle: Text(
                                      '${notification.message} · ${notification.priority.name} priority'),
                                  trailing: notification.read
                                      ? null
                                      : const Icon(Icons.circle, size: 9),
                                  onTap: () =>
                                      Navigator.of(context).pop(notification),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
            actions: [
              if (notifications.isNotEmpty)
                TextButton(
                  onPressed: () {
                    _updateNotifications(() {
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
          );
        },
      ),
    );
    if (!mounted || selected == null) return;
    _updateNotifications(() {
      final index = notifications.indexWhere((item) => item.id == selected.id);
      if (index >= 0) notifications[index] = notifications[index].markRead();
    });
    _navigateToNotification(selected);
  }

  void _navigateToNotification(AxNotification notification) {
    switch (notification.target) {
      case AxNotificationTarget.thread:
        final spaceId = notification.spaceId;
        final threadId = notification.threadId;
        if (spaceId != null && threadId != null) {
          _navigateTo(AxNavigation.thread(spaceId, threadId));
        } else if (spaceId != null) {
          _navigateTo(AxNavigation.space(spaceId));
        }
      case AxNotificationTarget.workflowRun:
      case AxNotificationTarget.run:
        final spaceId = notification.spaceId;
        if (spaceId != null && notification.runId != null) {
          _navigateTo(AxNavigation.run(spaceId, notification.runId!));
        } else if (spaceId != null) {
          _navigateTo(AxNavigation.space(spaceId));
        }
      case AxNotificationTarget.space:
        final spaceId = notification.spaceId;
        if (spaceId != null) {
          _navigateTo(AxNavigation.space(spaceId));
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
      _updateLiveState(() => realtimeNotice = summary.trim());
    }
  }

  Future<void> _copyRunDiagnostics() async {
    final run = executionSnapshot.run;
    if (run == null) return;
    final diagnostics = <String, Object?>{
      'format': 'conclave-run-diagnostics-v1',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'workspaceId': executionSnapshot.workspaceId,
      'spaceId': selectedSpaceId,
      'runId': run.id,
      'status': run.status.name,
      'tasks': executionSnapshot.tasks
          .map((task) => {
                'id': task.id,
                'status': task.status.name,
                'worker': task.worker,
              })
          .toList(),
      'events': executionSnapshot.events
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
      spaceId: selectedSpaceId,
      threadId: navigation.threadId,
      runId: navigation.runId,
      executionWorkspaceId: workspaceId,
    ));
  }

  Future<void> _loadAccountSecurity() async {
    if (!mounted) return;
    store.securityError.value = null;
    _updateSecurity(() => accountSecurityLoading = true);
    try {
      final loaded = await widget.dataSource.loadAccountSecurity();
      if (!mounted) return;
      _updateSecurity(() {
        accountSecurity = loaded;
        accountSecurityLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _updateSecurity(() {
        accountSecurityLoading = false;
        store.securityError.value = error.toString();
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

  Future<void> _loadBootstrapState(
      {String? spaceId, String? workspaceId, bool showSpinner = true}) async {
    if (store.auth.session?.authenticated != true) return;
    final resolvedSpaceId = spaceId;
    if (showSpinner) {
      final reconnecting = !isLoading && store.spaces.items.isNotEmpty;
      _updateState(() {
        isLoading = true;
        loadError = null;
        isReconnecting = reconnecting;
      });
    }
    try {
      final loaded = await store.loadBootstrapState(
          spaceId: resolvedSpaceId, workspaceId: workspaceId);
      if (!mounted) return;
      unawaited(store.invitations.refresh());
      optimisticRunStatus = null;
      if (showSpinner) {
        _updateState(() {
          selectedSpaceId = loaded.spaces.any(
                  (space) => space.id == (resolvedSpaceId ?? selectedSpaceId))
              ? (resolvedSpaceId ?? selectedSpaceId)
              : loaded.spaces.firstOrNull?.id;
          isLoading = false;
          isReconnecting = false;
          authRequired = false;
          _applySpaceNavigation();
        });
      }
      _ensureNavigationResources(navigation);
    } catch (error) {
      if (!mounted) return;
      if (error is AxApiException && error.statusCode == 401) {
        _updateState(() => authRequired = true);
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      if (!showSpinner) {
        _showSnackBar(error.toString(), type: ToastType.error);
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
      if (session.authenticated &&
          store.persistence.userId != null &&
          store.persistence.userId != session.viewer?.id) {
        store.clearServerState();
        expandedSpaceIds.clear();
        _updateState(() => authRequired = true);
      }
      if (!session.authenticated && !authRequired) {
        store.clearServerState();
        expandedSpaceIds.clear();
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
        final hydrated = await store.hydrateReadCache();
        if (!mounted) return;
        if (hydrated) {
          _updateState(() {
            isLoading = false;
            _applySpaceNavigation();
          });
        }
        await _loadWorkspaces();
        await _loadBootstrapState(showSpinner: !hydrated);
      }
    } catch (_) {
      // The normal load/error path will explain an unavailable auth service.
    }
  }

  void _applySpaceNavigation() {
    final routeSpace = navigation.spaceId;
    if (routeSpace != null &&
        store.spaces.items.any((space) => space.id == routeSpace)) {
      selectedSpaceId = routeSpace;
    }
  }

  /// Navigation is applied synchronously before independent resource requests.
  void _ensureNavigationResources(AxNavigation target) {
    final spaceId = target.spaceId;
    if (spaceId == null || store.auth.session?.authenticated != true) return;
    unawaited(store.spaceDetails
        .ensure(spaceId)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(store.spaceThreads
        .ensure(spaceId)
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
      final spaceId = next.spaceId;
      selectedSpaceId = spaceId ?? selectedSpaceId;
      if (next.kind == AxRouteKind.thread && spaceId != null) {
        expandedSpaceIds.add(spaceId);
      }
    });
    if (next.kind == AxRouteKind.profileSecurity) {
      unawaited(_loadAccountSecurity());
    }
    _ensureNavigationResources(next);
    unawaited(realtimeClient.setScopes(
      spaceId: next.spaceId ?? selectedSpaceId,
      threadId: next.threadId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  bool _isCanonicalWorkspaceUri(Uri actual, Uri canonical) =>
      actual.path == canonical.path &&
      mapEquals(actual.queryParameters, canonical.queryParameters);

  void _navigateTo(AxNavigation next, {bool replace = false}) {
    if ((next.spaceId?.startsWith('local-space-') ?? false) ||
        (next.spaceId?.startsWith('local-space-') ?? false) ||
        (next.threadId?.startsWith('local-thread-') ?? false) ||
        (next.threadId?.startsWith('local-thread-') ?? false)) {
      return;
    }
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
      final spaceId = next.spaceId;
      selectedSpaceId = spaceId ?? selectedSpaceId;
      if (next.kind == AxRouteKind.thread && spaceId != null) {
        expandedSpaceIds.add(spaceId);
      }
    });
    if (replace) {
      browserNavigation.replace(next.toUri());
    } else {
      browserNavigation.push(next.toUri());
    }
    _ensureNavigationResources(next);
    unawaited(realtimeClient.setScopes(
      spaceId: next.spaceId ?? selectedSpaceId,
      threadId: next.threadId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  Future<void> _grantWorkspace(AxWorkspace workspace) async {
    if (store.spaces.items.isEmpty) {
      _showSnackBar('Create a Space before granting Workspace access.');
      return;
    }
    String? selectedSpaceId = store.spaces.items.first.id;
    final permissions = <String>{};
    final spaceId = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Grant Workspace to Space'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: selectedSpaceId,
              decoration: const InputDecoration(labelText: 'Space'),
              items: store.spaces.items
                  .map((space) => DropdownMenuItem(
                      value: space.id, child: Text(space.name)))
                  .toList(),
              onChanged: (value) =>
                  setDialogState(() => selectedSpaceId = value),
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
              onPressed: selectedSpaceId == null
                  ? null
                  : () => Navigator.pop(dialogContext, selectedSpaceId),
              child: const Text('Grant access'),
            ),
          ],
        ),
      ),
    );
    if (spaceId == null) return;
    try {
      await store.spaceWorkspaceGrants.create(
        spaceId: spaceId,
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        allowedPermissions: permissions.toList(),
      );
      await _refreshWorkspaceGrantSummary();
      if (mounted) _showSnackBar('Workspace access request sent.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  void _handleContextualCreate() {
    final space = selectedSpace;
    if (space != null) {
      _createThread(space);
    } else {
      _createSpace();
    }
  }
}

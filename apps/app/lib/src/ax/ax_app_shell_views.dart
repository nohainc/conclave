part of 'ax_app.dart';

extension _AxAppShellViews on _AxAppStateMixin {
  Widget _buildApp(BuildContext context) {
    return MaterialApp(
      title: 'Conclave AX',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: ConclaveBrand.lightTheme(),
      darkTheme: ConclaveBrand.darkTheme(),
      themeMode: _themeMode,
      home: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
              _handleContextualCreate,
          const SingleActivator(LogicalKeyboardKey.keyN, control: true):
              _handleContextualCreate,
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  if (desktopAuthApproved || desktopAuthCancelled) {
                    return _desktopAuthApprovalView();
                  }
                  if (isLoading) return _loadingScaffold();
                  if (authRequired) return _authScaffold();
                  if (loadError != null) return _errorScaffold();
                  if (navigation.kind == AxRouteKind.desktopAuthApproval) {
                    return _desktopAuthApprovalView();
                  }
                  final isDesktop =
                      ConclaveBrand.isDesktop(constraints.maxWidth);
                  final shell = _shellContext;
                  return Scaffold(
                    drawer: !isDesktop
                        ? Drawer(
                            child: AxSidebar(
                              shellContext: shell,
                              onNavigateTo: _navigateTo,
                              onToggleProjectExpanded: _toggleProjectExpanded,
                              onCreateProject: _createProject,
                              onCreateWorkstream: _createWorkstream,
                              searchController: _searchQueryController,
                              searchFocusNode: _searchFocusNode,
                              onClearSearch: _clearSearch,
                              onOpenCommandPalette: _openCommandPalette,
                              onOpenNotifications: _showNotifications,
                              onToggleTheme: _toggleTheme,
                              onSetThemeMode: _setThemeMode,
                              onLogout: () => unawaited(_logout()),
                              onOpenAbout: () =>
                                  unawaited(_showAboutConclave()),
                              onOpenExternal: (uri) =>
                                  browserNavigation.openExternal(uri),
                              onOpenArchivedProjects: _showArchivedProjects,
                              compact: true,
                            ),
                          )
                        : null,
                    body: Row(
                      children: [
                        if (isDesktop)
                          _desktopSidebarCollapsed
                              ? AxIconRail(
                                  shellContext: shell,
                                  onNavigateTo: _navigateTo,
                                  onOpenDrawer: () {},
                                  onCreateProject: _createProject,
                                  onCreateWorkstream: _createWorkstream,
                                  searchController: _searchQueryController,
                                  searchFocusNode: _searchFocusNode,
                                  onSearchChanged: (_) =>
                                      _onSearchQueryChanged(),
                                  onClearSearch: _clearSearch,
                                  onOpenCommandPalette: _openCommandPalette,
                                  onOpenNotifications: _showNotifications,
                                  onToggleTheme: _toggleTheme,
                                  onSetThemeMode: _setThemeMode,
                                  onLogout: () => unawaited(_logout()),
                                  onOpenAbout: () =>
                                      unawaited(_showAboutConclave()),
                                  onOpenExternal: (uri) =>
                                      browserNavigation.openExternal(uri),
                                  onOpenArchivedProjects: _showArchivedProjects,
                                  onToggleCollapse: () => _updateState(
                                      () => _desktopSidebarCollapsed = false),
                                )
                              : SizedBox(
                                  width: 248,
                                  child: AxSidebar(
                                    shellContext: shell,
                                    onNavigateTo: _navigateTo,
                                    onToggleProjectExpanded:
                                        _toggleProjectExpanded,
                                    onCreateProject: _createProject,
                                    onCreateWorkstream: _createWorkstream,
                                    searchController: _searchQueryController,
                                    searchFocusNode: _searchFocusNode,
                                    onClearSearch: _clearSearch,
                                    onOpenCommandPalette: _openCommandPalette,
                                    onOpenNotifications: _showNotifications,
                                    onToggleTheme: _toggleTheme,
                                    onSetThemeMode: _setThemeMode,
                                    onLogout: () => unawaited(_logout()),
                                    onOpenAbout: () =>
                                        unawaited(_showAboutConclave()),
                                    onOpenExternal: (uri) =>
                                        browserNavigation.openExternal(uri),
                                    onOpenArchivedProjects:
                                        _showArchivedProjects,
                                    onToggleCollapse: () => _updateState(
                                        () => _desktopSidebarCollapsed = true),
                                  ),
                                ),
                        Expanded(
                          child: _content(
                            compact: !isDesktop,
                            showTopHud: !isDesktop,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadingScaffold() => Scaffold(
        body: Center(
          child: Semantics(
            liveRegion: true,
            label: 'Loading your Conclave workspace',
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 18),
                    Text('Loading your workspace',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    const Text(
                        'Your existing work stays safe while Conclave AX connects.',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
  Widget _authScaffold() {
    final returnTo = navigation.loginReturnTo == null
        ? Uri(path: '/')
        : Uri.parse(navigation.loginReturnTo!);
    final resetToken = browserNavigation.current.queryParameters['token'];
    final resetPassword = resetToken != null;
    final title = resetPassword
        ? 'Choose a new password'
        : authResetRequest
            ? 'Restore your password'
            : authSignUp
                ? 'Create your Conclave AX account'
                : 'Welcome to Conclave AX';
    return Scaffold(
      body: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConclaveBrand.logoMark(size: 52),
                    const SizedBox(height: 16),
                    Text(title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                        resetPassword
                            ? 'Choose a strong password for your account.'
                            : authResetRequest
                                ? 'Enter your email and we will send a reset link if an account exists.'
                                : authSignUp
                                    ? 'Create an account to start using Conclave AX.'
                                    : 'Sign in securely to access your Projects, Workspaces, and Workers.',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    if (!resetPassword && authSignUp) ...[
                      TextField(
                        controller: authNameController,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Name'),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (!resetPassword) ...[
                      TextField(
                        controller: authEmailController,
                        autofocus: !authSignUp,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: authResetRequest
                            ? TextInputAction.done
                            : TextInputAction.next,
                        onSubmitted: (_) {
                          if (authResetRequest) {
                            _submitEmailAuth();
                          }
                        },
                        decoration: const InputDecoration(labelText: 'Email'),
                      ),
                      if (!authResetRequest) const SizedBox(height: 10),
                    ],
                    if (resetPassword || !authResetRequest) ...[
                      TextField(
                        controller: authPasswordController,
                        autofocus: resetPassword,
                        obscureText: true,
                        textInputAction: (!authSignUp && !resetPassword)
                            ? TextInputAction.done
                            : TextInputAction.next,
                        onSubmitted: (_) {
                          if (!authSignUp && !resetPassword) {
                            _submitEmailAuth();
                          }
                        },
                        decoration:
                            const InputDecoration(labelText: 'Password'),
                      ),
                      if (authSignUp || resetPassword) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: authConfirmPasswordController,
                          obscureText: true,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submitEmailAuth(),
                          decoration: const InputDecoration(
                              labelText: 'Confirm password'),
                        ),
                      ],
                    ],
                    if (authError != null) ...[
                      const SizedBox(height: 12),
                      Text(authError!,
                          style: TextStyle(color: Colors.red.shade700)),
                    ],
                    if (authNotice != null) ...[
                      const SizedBox(height: 12),
                      Text(authNotice!, textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: authBusy ? null : _submitEmailAuth,
                        child: Text(authBusy
                            ? 'Please wait…'
                            : resetPassword
                                ? 'Save new password'
                                : authResetRequest
                                    ? 'Email reset link'
                                    : authSignUp
                                        ? 'Create account'
                                        : 'Sign in with email'),
                      ),
                    ),
                    if (!resetPassword && !authSignUp && !authResetRequest)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: authBusy
                              ? null
                              : () => _updateState(() {
                                    authResetRequest = true;
                                    authError = null;
                                    authNotice = null;
                                  }),
                          child: const Text('Forgot password?'),
                        ),
                      ),
                    if (!resetPassword && !authResetRequest)
                      TextButton(
                        onPressed: authBusy
                            ? null
                            : () => _updateState(() {
                                  authSignUp = !authSignUp;
                                  authError = null;
                                  authNotice = null;
                                }),
                        child: Text(authSignUp
                            ? 'Already have an account? Sign in'
                            : 'New here? Create an account'),
                      ),
                    if (!resetPassword && (authSignUp || authResetRequest))
                      TextButton(
                        onPressed: authBusy
                            ? null
                            : () => _updateState(() {
                                  authSignUp = false;
                                  authResetRequest = false;
                                  authError = null;
                                  authNotice = null;
                                }),
                        child: const Text('Back to sign in'),
                      ),
                    if (!resetPassword && !authSignUp && !authResetRequest) ...[
                      const Divider(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => browserNavigation.startSocialLogin(
                              'github', returnTo),
                          icon: const Icon(Icons.code),
                          label: const Text('Continue with GitHub'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => browserNavigation.startSocialLogin(
                              'google', returnTo),
                          icon: const Icon(Icons.account_circle_outlined),
                          label: const Text('Continue with Google'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          onPressed: () => _signInWithPasskey(returnTo),
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Continue with Passkey'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopAuthApprovalView() {
    final appName =
        desktopAuthIntentStatus?.applicationName ?? 'desktop application';
    if (desktopAuthApproved || desktopAuthCancelled) {
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                        desktopAuthApproved
                            ? 'Sign-in approved'
                            : 'Sign-in canceled',
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Text(desktopAuthApproved
                        ? 'Return to $appName to finish signing in.'
                        : 'This sign-in request was canceled.'),
                    const SizedBox(height: 8),
                    const Text('You can close this page, window, or tab.'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final user = store.auth.viewer;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Sign in to $appName',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(desktopAuthIntentStatus == null
                      ? 'Loading the desktop sign-in request…'
                      : desktopAuthIntentStatus!.applicationName == null
                          ? 'This request came from an unsupported desktop app. It cannot be approved here.'
                          : 'Approve sign-in to $appName for ${user?.displayName ?? user?.email ?? 'your account'}? Return to that app after approval.'),
                  const SizedBox(height: 22),
                  if (desktopAuthError != null) ...[
                    const SizedBox(height: 8),
                    Text(desktopAuthError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: desktopAuthBusy ||
                            desktopAuthIntentStatus?.canApprove != true
                        ? null
                        : _approveDesktopAuth,
                    child: Text(
                        desktopAuthBusy ? 'Approving…' : 'Approve sign-in'),
                  ),
                  TextButton(
                    onPressed:
                        desktopAuthBusy ? null : _cancelDesktopAuthFromBrowser,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _approveDesktopAuth() async {
    final intentId = navigation.desktopAuthIntentId;
    if (intentId == null || desktopAuthIntentStatus?.canApprove != true) {
      _updateState(() => desktopAuthError =
          'This desktop sign-in request is incomplete or unsupported. Start again from the requesting app.');
      return;
    }
    _updateState(() {
      desktopAuthBusy = true;
      desktopAuthError = null;
    });
    try {
      await widget.dataSource.approveDesktopAuthIntent(intentId: intentId);
      if (!mounted) return;
      browserNavigation.replace(Uri(path: '/'));
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthApproved = true;
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthError = error.toString();
      });
    }
  }

  Future<void> _cancelDesktopAuthFromBrowser() async {
    final intentId = navigation.desktopAuthIntentId;
    if (intentId == null) {
      _navigateTo(const AxNavigation.home(), replace: true);
      return;
    }
    _updateState(() {
      desktopAuthBusy = true;
      desktopAuthError = null;
    });
    try {
      await widget.dataSource.denyDesktopAuthIntent(intentId: intentId);
      if (!mounted) return;
      browserNavigation.replace(Uri(path: '/'));
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthCancelled = true;
      });
      _desktopAuthStatusTimer?.cancel();
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthError = error.toString();
      });
    }
  }

  Widget _errorScaffold() => Scaffold(
        body: Center(
          child: _RecoveryPanel(
            icon: Icons.cloud_off_rounded,
            title: 'Conclave AX could not load live data',
            happened: loadError ?? 'The workspace connection did not respond.',
            safe: 'Your existing work is safe. No new work was started.',
            nextStep: 'Check your connection, then try again.',
            retrying: isReconnecting,
            onRetry: () => _loadBootstrapState(),
          ),
        ),
      );
  Widget _workstreamContextBuilder(Widget Function() build) {
    final projectId = navigation.projectId;
    if (projectId == null) return build();
    return AxQueryBuilder<List<AxWorkstream>>(
      engine: store.projectWorkstreams.engine,
      query: store.projectWorkstreams.query(projectId),
      builder: (context, state) => build(),
    );
  }

  Widget _projectContextBuilder(Widget Function() build) {
    final projectId = navigation.projectId;
    if (projectId == null) return build();
    return AxQueryBuilder<AxProject>(
      key: ValueKey('project-context-$projectId'),
      engine: store.syncEngine,
      query: store.projectDetails.query(projectId),
      builder: (context, state) {
        if (selectedProject != null) return build();
        return Center(
            child: state.error != null
                ? TextButton(
                    onPressed: () => store.projectDetails
                        .ensure(projectId)
                        .then<void>((_) {},
                            onError: (Object _, StackTrace __) {}),
                    child: const Text('Retry Project'))
                : const Text('Loading Project…'));
      },
    );
  }

  Widget _content({required bool compact, required bool showTopHud}) {
    return _projectContextBuilder(() => Column(children: [
          if (showTopHud)
            _workstreamContextBuilder(() => ListenableBuilder(
                listenable: Listenable.merge([
                  store.workspaces,
                  store.executionChanges,
                  store.realtimeStatus
                ]),
                builder: (context, _) => AxTopBar(
                      shellContext: _shellContext,
                      onNavigateTo: _navigateTo,
                      onOpenCommandPalette: _openCommandPalette,
                      onOpenNotifications: _showNotifications,
                      searchController: _searchQueryController,
                      searchFocusNode: _searchFocusNode,
                      onClearSearch: _clearSearch,
                      onToggleTheme: _toggleTheme,
                      onOpenAbout: () => unawaited(_showAboutConclave()),
                      onLogout: () => unawaited(_logout()),
                      onOpenExternal: (uri) =>
                          browserNavigation.openExternal(uri),
                      compact: compact,
                    ))),
          ListenableBuilder(
              listenable: Listenable.merge(
                  [store.realtimeStatus, store.lifecycleNotice]),
              builder: (context, _) {
                final status = store.realtimeStatus.value;
                return Column(children: [
                  if (status.$1 || store.lifecycleNotice.value != null)
                    _realtimeStatusBanner(),
                  if (status.$2 != null)
                    Semantics(
                        liveRegion: true,
                        label: status.$2!,
                        child: const SizedBox(width: 1, height: 1)),
                ]);
              }),
          Expanded(
            child: navigation.kind == AxRouteKind.workstream
                ? Padding(
                    padding: EdgeInsets.zero,
                    child: _workstreamView(),
                  )
                : SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                        compact ? 18 : 34, 26, compact ? 18 : 34, 40),
                    child:
                        showRunDetails ? _runDetailsView(compact) : _homeView(),
                  ),
          ),
        ]));
  }

  Widget _realtimeStatusBanner() => Semantics(
        liveRegion: true,
        label: store.lifecycleNotice.value ??
            realtimeNotice ??
            'Live updates are reconnecting.',
        child: Container(
          width: double.infinity,
          color: const Color(0xfffff6df),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          child: Row(children: [
            const Icon(Icons.cloud_off_outlined,
                size: 17, color: Color(0xff8a6518)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                store.lifecycleNotice.value ??
                    realtimeNotice ??
                    'Live updates are reconnecting.',
                style: const TextStyle(color: Color(0xff765817), fontSize: 12),
              ),
            ),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ]),
        ),
      );
}

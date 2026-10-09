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
                              onToggleSpaceExpanded: _toggleSpaceExpanded,
                              onCreateSpace: _createSpace,
                              onCreateThread: _createThread,
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
                              onOpenArchivedSpaces: _openArchivedSpaces,
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
                                  onCreateSpace: _createSpace,
                                  onCreateThread: _createThread,
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
                                  onOpenArchivedSpaces: _openArchivedSpaces,
                                  onToggleCollapse: () => _updateState(
                                      () => _desktopSidebarCollapsed = false),
                                )
                              : SizedBox(
                                  width: 248,
                                  child: AxSidebar(
                                    shellContext: shell,
                                    onNavigateTo: _navigateTo,
                                    onToggleSpaceExpanded: _toggleSpaceExpanded,
                                    onCreateSpace: _createSpace,
                                    onCreateThread: _createThread,
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
                                    onOpenArchivedSpaces: _openArchivedSpaces,
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
                                    : 'Sign in securely to access your Spaces, Workspaces, and Workers.',
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
                          style: const TextStyle(color: ConclaveColors.error)),
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
  Widget _threadContextBuilder(Widget Function() build) {
    final spaceId = navigation.spaceId;
    if (spaceId == null) return build();
    return AxQueryBuilder<List<AxThread>>(
      engine: store.spaceThreads.engine,
      query: store.spaceThreads.query(spaceId),
      builder: (context, state) => build(),
    );
  }

  Widget _spaceContextBuilder(Widget Function() build) {
    final spaceId = navigation.spaceId;
    if (spaceId == null) return build();
    return AxQueryBuilder<AxSpace>(
      key: ValueKey('space-context-$spaceId'),
      engine: store.syncEngine,
      query: store.spaceDetails.query(spaceId),
      builder: (context, state) {
        if (selectedSpace != null) return build();
        return Center(
            child: state.error != null
                ? TextButton(
                    onPressed: () => store.spaceDetails
                        .ensure(spaceId)
                        .then<void>((_) {},
                            onError: (Object _, StackTrace __) {}),
                    child: const Text('Retry Space'))
                : const Text('Loading Space…'));
      },
    );
  }

  Widget _content({required bool compact, required bool showTopHud}) {
    return _spaceContextBuilder(() => Stack(
          children: [
            Column(children: [
              if (showTopHud)
                _threadContextBuilder(() => ListenableBuilder(
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
              Expanded(
                child: navigation.kind == AxRouteKind.thread
                    ? Padding(
                        padding: EdgeInsets.zero,
                        child: _threadView(),
                      )
                    : SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                            compact ? 18 : 34, 26, compact ? 18 : 34, 40),
                        child: showRunDetails
                            ? _runDetailsView(compact)
                            : _homeView(),
                      ),
              ),
            ]),
            Positioned(
              top: showTopHud ? 60 : 10,
              left: 20,
              right: 20,
              child: _FloatingRealtimeStatusBanner(
                realtimeStatus: store.realtimeStatus,
                lifecycleNotice: store.lifecycleNotice,
                realtimeNotice: realtimeNotice,
              ),
            ),
          ],
        ));
  }
}

class _FloatingRealtimeStatusBanner extends StatefulWidget {
  const _FloatingRealtimeStatusBanner({
    required this.realtimeStatus,
    required this.lifecycleNotice,
    this.realtimeNotice,
  });

  final ValueNotifier<(bool, String?)> realtimeStatus;
  final ValueNotifier<String?> lifecycleNotice;
  final String? realtimeNotice;

  @override
  State<_FloatingRealtimeStatusBanner> createState() =>
      _FloatingRealtimeStatusBannerState();
}

class _FloatingRealtimeStatusBannerState
    extends State<_FloatingRealtimeStatusBanner> {
  static const _connectionWarningDelay = Duration(seconds: 3);
  Timer? _dismissTimer;
  Timer? _pendingConnectionWarning;
  bool _visible = false;
  String? _lastNoticeKey;

  @override
  void initState() {
    super.initState();
    widget.realtimeStatus.addListener(_onNoticeChanged);
    widget.lifecycleNotice.addListener(_onNoticeChanged);
    _onNoticeChanged();
  }

  @override
  void didUpdateWidget(covariant _FloatingRealtimeStatusBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.realtimeStatus != widget.realtimeStatus) {
      oldWidget.realtimeStatus.removeListener(_onNoticeChanged);
      widget.realtimeStatus.addListener(_onNoticeChanged);
    }
    if (oldWidget.lifecycleNotice != widget.lifecycleNotice) {
      oldWidget.lifecycleNotice.removeListener(_onNoticeChanged);
      widget.lifecycleNotice.addListener(_onNoticeChanged);
    }
    if (oldWidget.realtimeNotice != widget.realtimeNotice) {
      _onNoticeChanged();
    }
  }

  @override
  void dispose() {
    widget.realtimeStatus.removeListener(_onNoticeChanged);
    widget.lifecycleNotice.removeListener(_onNoticeChanged);
    _dismissTimer?.cancel();
    _pendingConnectionWarning?.cancel();
    super.dispose();
  }

  void _onNoticeChanged() {
    final status = widget.realtimeStatus.value;
    final lifecycle = widget.lifecycleNotice.value;
    final noticeText = lifecycle ?? widget.realtimeNotice ?? status.$2;
    final isActive = status.$1 || lifecycle != null || noticeText != null;

    if (!isActive || noticeText == null || noticeText.isEmpty) {
      _dismissTimer?.cancel();
      _pendingConnectionWarning?.cancel();
      if (_visible) {
        setState(() => _visible = false);
      }
      return;
    }

    // A short reconnect should be invisible. If the transport is still stale
    // after three seconds, show the warning; a connected confirmation is not
    // useful for the brief transitions this banner is meant to cover.
    final isConnectedNotice =
        lifecycle == null && noticeText == 'Live updates connected.';
    if (isConnectedNotice) {
      _dismissTimer?.cancel();
      _pendingConnectionWarning?.cancel();
      if (_visible) {
        setState(() => _visible = false);
      }
      _lastNoticeKey = '$isActive:$noticeText';
      return;
    }

    final isConnectionWarning = lifecycle == null && status.$1;
    if (isConnectionWarning) {
      final key = '$isActive:$noticeText';
      if (key == _lastNoticeKey &&
          (_pendingConnectionWarning?.isActive == true || _visible)) {
        return;
      }
      _lastNoticeKey = key;
      _dismissTimer?.cancel();
      _pendingConnectionWarning?.cancel();
      if (_visible) {
        setState(() => _visible = false);
      }
      _pendingConnectionWarning = Timer(_connectionWarningDelay, () {
        _pendingConnectionWarning = null;
        if (!mounted) return;
        final currentStatus = widget.realtimeStatus.value;
        final currentLifecycle = widget.lifecycleNotice.value;
        final currentNotice =
            currentLifecycle ?? widget.realtimeNotice ?? currentStatus.$2;
        if (currentStatus.$1 &&
            currentLifecycle == null &&
            currentNotice != null &&
            currentNotice.isNotEmpty) {
          _showNotice();
        }
      });
      return;
    }

    _pendingConnectionWarning?.cancel();

    final key = '$isActive:$noticeText';
    if (key != _lastNoticeKey || !_visible) {
      _lastNoticeKey = key;
      _dismissTimer?.cancel();
      _showNotice();
    }
  }

  void _showNotice() {
    if (!mounted) return;
    setState(() => _visible = true);
    _dismissTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.realtimeStatus.value;
    final lifecycle = widget.lifecycleNotice.value;
    final noticeText = lifecycle ??
        widget.realtimeNotice ??
        status.$2 ??
        'Live updates are reconnecting.';

    if (!_visible) return const SizedBox.shrink();

    return IgnorePointer(
      ignoring: true,
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Semantics(
          liveRegion: true,
          label: noticeText,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xfffff6df),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xffe6c875)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cloud_off_outlined,
                        size: 16,
                        color: Color(0xff8a6518),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          noticeText,
                          style: const TextStyle(
                            color: Color(0xff765817),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Color(0xff8a6518)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

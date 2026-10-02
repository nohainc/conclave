part of 'ax_app.dart';

mixin _AxAppStateMixin on State<ConclaveAppShell> {
  late AxSnapshot snapshot;
  String? selectedProjectId;
  RunStatus? optimisticRunStatus;
  Timer? refreshTimer;
  bool isLoading = true;
  String? loadError;
  String? selectedTaskId = 'implement';
  final Set<String> expandedProjectIds = <String>{};
  List<AxWorker> workspaceWorkers = const [];
  bool workspaceWorkerInventoryLoaded = false;
  Map<String, int> workspaceProjectGrantCounts = const {};
  final authNameController = TextEditingController();
  final authEmailController = TextEditingController();
  final authPasswordController = TextEditingController();
  final authConfirmPasswordController = TextEditingController();
  final List<AxNotification> notifications = [];
  late final AxStore store;
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final AxBrowserNavigation browserNavigation;
  late AxNavigation navigation;
  StreamSubscription<Uri>? navigationSubscription;
  StreamSubscription<void>? lifecycleSubscription;
  late final RealtimeClient realtimeClient;
  StreamSubscription<Map<String, dynamic>>? realtimeSubscription;
  bool realtimeStarted = false;
  bool authRequired = false;
  bool isReconnecting = false;
  bool realtimeStale = false;
  String? realtimeNotice;
  bool authSignUp = false;
  bool authResetRequest = false;
  bool authBusy = false;
  bool desktopAuthBusy = false;
  bool desktopAuthApproved = false;
  bool desktopAuthCancelled = false;
  String? _desktopAuthIntentId;
  Timer? _desktopAuthStatusTimer;
  bool _desktopAuthStatusRequestActive = false;
  String? desktopAuthError;
  String? authNotice;
  String? authError;
  String? pendingRunPrompt;
  final promptResponseController = TextEditingController();
  final TextEditingController _searchQueryController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  AxNavigation? _navigationBeforeSearch;
  DateTime? _lastRealtimeAnnouncement;
  String? _lastRealtimeProjectId;
  AxAccountSecurity? accountSecurity;
  bool accountSecurityLoading = false;
  ThemeMode _themeMode = ThemeMode.system;
  bool _desktopSidebarCollapsed = false;
  bool get showRunDetails => switch (navigation.kind) {
        AxRouteKind.home => false,
        _ => true,
      };
  void _showSnackBar(String message, {ToastType type = ToastType.info}) {
    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          showCloseIcon: true,
          closeIconColor: const Color(0xff9e9ea7),
          content: Text(
            message,
            style: const TextStyle(
              color: Color(0xfff4f4f6),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          backgroundColor: const Color(0xff20202a),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          action: SnackBarAction(
            label: 'Copy',
            textColor: const Color(0xffb8a9fe),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
              messengerKey.currentState?.hideCurrentSnackBar();
            },
          ),
        ),
      );
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        messengerKey.currentState?.hideCurrentSnackBar();
      }
    });
  }

  void _onSearchQueryChanged() {
    final newQuery = _searchQueryController.text.trim();
    if (newQuery == _searchQuery) return;
    if (_searchQuery.isEmpty && newQuery.isNotEmpty) {
      if (navigation.kind != AxRouteKind.search) {
        _navigationBeforeSearch = navigation;
      }
      setState(() {
        _searchQuery = newQuery;
        navigation = AxNavigation.search(newQuery);
      });
    } else if (_searchQuery.isNotEmpty && newQuery.isEmpty) {
      final restoreNav = _navigationBeforeSearch ?? const AxNavigation.home();
      _navigationBeforeSearch = null;
      setState(() {
        _searchQuery = '';
        navigation = restoreNav;
      });
    } else {
      setState(() {
        _searchQuery = newQuery;
        if (navigation.kind == AxRouteKind.search) {
          navigation = AxNavigation.search(newQuery);
        }
      });
    }
  }

  void _clearSearch() {
    setState(() {
      _searchQuery = '';
      if (_searchQueryController.text.isNotEmpty) {
        _searchQueryController.clear();
      }
      if (navigation.kind == AxRouteKind.search) {
        final restoreNav = _navigationBeforeSearch ?? const AxNavigation.home();
        _navigationBeforeSearch = null;
        navigation = restoreNav;
      }
    });
  }

  void _focusSearch() {
    _searchFocusNode.requestFocus();
  }

  void _openCommandPalette() {
    _focusSearch();
  }

  AxProject? get selectedProject => snapshot.projects
      .where((project) => project.id == selectedProjectId)
      .firstOrNull;
  List<AxWorkspace> get workspaces => store.workspaces.items;
  AxTask? get selectedTask =>
      snapshot.tasks.where((task) => task.id == selectedTaskId).firstOrNull;
  AxWorkstream? get selectedWorkstream {
    final project = selectedProject;
    return project?.workstreams
        .where((workstream) => workstream.id == navigation.workstreamId)
        .firstOrNull;
  }

  String? get executionWorkspaceId => snapshot.workspaceId;
  int get unreadNotificationCount =>
      notifications.where((notification) => !notification.read).length;
  AxShellContext get _shellContext => AxShellContext(
        navigation: navigation,
        projects: snapshot.projects,
        selectedProject: selectedProject,
        selectedWorkstream: selectedWorkstream,
        selectedRun: snapshot.run,
        workspaces: snapshot.workspaces,
        unreadNotificationCount: unreadNotificationCount,
        isDarkTheme: _themeMode == ThemeMode.dark ||
            (_themeMode == ThemeMode.system &&
                Theme.of(context).brightness == Brightness.dark),
        themeMode: _themeMode,
        realtimeStale: realtimeStale,
        realtimeNotice: realtimeNotice,
        viewerDisplayName:
            store.auth.viewer?.displayName ?? snapshot.viewer?.displayName,
        viewerEmail: store.auth.viewer?.email ?? snapshot.viewer?.email,
        expandedProjectIds: expandedProjectIds,
      );
  void _toggleProjectExpanded(String projectId) {
    setState(() {
      if (expandedProjectIds.contains(projectId)) {
        expandedProjectIds.remove(projectId);
      } else {
        expandedProjectIds.add(projectId);
      }
    });
  }

  void _updateState(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    _searchQueryController.addListener(_onSearchQueryChanged);
    browserNavigation = createAxBrowserNavigation();
    final initialUri = widget.initialUri ?? browserNavigation.current;
    navigation = AxNavigation.fromUri(initialUri);
    _desktopAuthIntentId = _intentIdFromNavigation(navigation);
    if (!_isCanonicalWorkspaceUri(initialUri, navigation.toUri())) {
      browserNavigation.replace(navigation.toUri());
    }
    navigationSubscription =
        browserNavigation.changes.listen(_onBrowserNavigation);
    lifecycleSubscription = browserNavigation.lifecycleChanges
        .listen((_) => unawaited(_syncSession()));
    realtimeClient = createRealtimeClient();
    realtimeSubscription = realtimeClient.events.listen(_onRealtimeEvent);
    store = AxStore(widget.dataSource);
    snapshot = AxSnapshot.empty();
    if (_desktopAuthIntentId != null) {
      _desktopAuthStatusTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_pollDesktopAuthStatus()),
      );
    }
    unawaited(_loadSession());
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    _desktopAuthStatusTimer?.cancel();
    _searchQueryController.removeListener(_onSearchQueryChanged);
    _searchQueryController.dispose();
    _searchFocusNode.dispose();
    authNameController.dispose();
    authEmailController.dispose();
    authPasswordController.dispose();
    authConfirmPasswordController.dispose();
    promptResponseController.dispose();
    unawaited(navigationSubscription?.cancel());
    unawaited(lifecycleSubscription?.cancel());
    unawaited(realtimeSubscription?.cancel());
    unawaited(realtimeClient.close());
    browserNavigation.dispose();
    super.dispose();
  }

  String? _intentIdFromNavigation(AxNavigation value) {
    if (value.desktopAuthIntentId != null) return value.desktopAuthIntentId;
    if (value.loginReturnTo == null) return null;
    final returnTo = Uri.tryParse(value.loginReturnTo!);
    if (returnTo == null) return null;
    return AxNavigation.fromUri(returnTo).desktopAuthIntentId;
  }

  @override
  Widget build(BuildContext context) {
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
                                  onToggleCollapse: () => setState(
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
                                    onToggleCollapse: () => setState(
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
                              : () => setState(() {
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
                            : () => setState(() {
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
                            : () => setState(() {
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
                        ? 'Return to Conclave Workspace to finish signing in.'
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
                  Text('Sign in to Conclave Workspace',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(
                      'Approve Conclave Workspace sign-in for ${user?.displayName ?? user?.email ?? 'your account'}? Return to the desktop app after approval.'),
                  const SizedBox(height: 22),
                  if (desktopAuthError != null) ...[
                    const SizedBox(height: 8),
                    Text(desktopAuthError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: desktopAuthBusy ? null : _approveDesktopAuth,
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
    if (intentId == null) {
      setState(() => desktopAuthError =
          'This Workspace sign-in request is incomplete. Start again from the desktop app.');
      return;
    }
    setState(() {
      desktopAuthBusy = true;
      desktopAuthError = null;
    });
    try {
      await widget.dataSource.approveDesktopAuthIntent(intentId: intentId);
      if (!mounted) return;
      browserNavigation.replace(Uri(path: '/'));
      setState(() {
        desktopAuthBusy = false;
        desktopAuthApproved = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
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
    setState(() {
      desktopAuthBusy = true;
      desktopAuthError = null;
    });
    try {
      await widget.dataSource.denyDesktopAuthIntent(intentId: intentId);
      if (!mounted) return;
      browserNavigation.replace(Uri(path: '/'));
      setState(() {
        desktopAuthBusy = false;
        desktopAuthCancelled = true;
      });
      _desktopAuthStatusTimer?.cancel();
    } catch (error) {
      if (!mounted) return;
      setState(() {
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
            onRetry: () => _loadSnapshot(),
          ),
        ),
      );
  Future<void> _createProject() async {
    var name = '';
    var description = '';
    var instructions = '';
    final values = await showDialog<(String, String?, String?)>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) {
        void submit() {
          Navigator.pop(
            dialogContext,
            (
              name.isEmpty ? 'My first project' : name,
              description.trim().isEmpty ? null : description.trim(),
              instructions.trim().isEmpty ? null : instructions.trim(),
            ),
          );
        }

        return AlertDialog(
          title: const Text('Create project'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  onChanged: (value) => name = value,
                  onSubmitted: (_) => submit(),
                  decoration: const InputDecoration(labelText: 'Project name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  onChanged: (value) => description = value,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  onChanged: (value) => instructions = value,
                  decoration: const InputDecoration(
                    labelText: 'Project instructions (optional)',
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: submit,
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    if (values == null) return;
    if (mounted) {
      setState(() {
        isLoading = true;
        loadError = null;
      });
    }
    try {
      final project = await widget.dataSource.createProject(
        name: values.$1,
        description: values.$2,
        instructions: values.$3,
      );
      if (!mounted) return;
      setState(() {
        snapshot = snapshot.copyWith(
          projects: [...snapshot.projects, project],
        );
        selectedProjectId = project.id;
        isLoading = false;
      });
      _navigateTo(AxNavigation.project(project.id), replace: true);
      _showSnackBar('Project created. Create a Workstream to get started.');
    } catch (error) {
      if (mounted) {
        setState(() {
          isLoading = false;
          loadError = null;
        });
        _showSnackBar(error.toString(), type: ToastType.error);
      }
    }
  }

  Future<void> _createWorkstream([AxProject? targetProject]) async {
    final project = targetProject ?? selectedProject;
    if (project == null) return;
    var name = '';
    final created = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Workstream'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => name = value,
          onSubmitted: (_) {
            if (name.trim().isNotEmpty) {
              Navigator.pop(dialogContext, name.trim());
            }
          },
          decoration: const InputDecoration(
            labelText: 'Workstream name',
            hintText: 'e.g. Authentication redesign',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.trim().isNotEmpty) {
                Navigator.pop(dialogContext, name.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (created == null || created.isEmpty) return;
    final newWorkstreamId =
        'workstream-${DateTime.now().microsecondsSinceEpoch}';
    final newWorkstream = AxWorkstream(
      id: newWorkstreamId,
      projectId: project.id,
      name: created,
      lead: _shellContext.viewerDisplayName ?? 'You',
      status: 'active',
      brief: 'Add a brief so collaborators understand the intended outcome.',
      primaryWorkspace: _shellContext.workspaces.isNotEmpty
          ? _shellContext.workspaces.first.name
          : 'Not selected',
      queueStatus: 'Idle',
    );
    final updatedProjects = snapshot.projects.map((p) {
      if (p.id == project.id) {
        return AxProject(
          id: p.id,
          name: p.name,
          branch: p.branch,
          lastActivity: 'just now',
          description: p.description,
          instructions: p.instructions,
          workstreams: [...p.workstreams, newWorkstream],
        );
      }
      return p;
    }).toList();
    if (mounted) {
      setState(() {
        snapshot = snapshot.copyWith(projects: updatedProjects);
        expandedProjectIds.add(project.id);
      });
      _navigateTo(
        AxNavigation.workstream(project.id, newWorkstreamId),
      );
      _showSnackBar('Workstream created.');
    }
  }

  Future<void> _editProject(AxProject project) async {
    var name = project.name;
    var description = project.description;
    var instructions = project.instructions;
    final values = await showDialog<(String, String, String)?>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Project settings'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: project.name,
                onChanged: (value) => name = value,
                decoration: const InputDecoration(labelText: 'Project name'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: project.description,
                onChanged: (value) => description = value,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: project.instructions,
                onChanged: (value) => instructions = value,
                decoration:
                    const InputDecoration(labelText: 'Project instructions'),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              (name.trim(), description.trim(), instructions.trim()),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (values == null || values.$1.isEmpty) return;
    try {
      final updated = await widget.dataSource.updateProject(
        projectId: project.id,
        name: values.$1,
        description: values.$2,
        instructions: values.$3,
      );
      if (!mounted) return;
      setState(() {
        snapshot = snapshot.copyWith(
          projects: snapshot.projects
              .map((item) => item.id == updated.id ? updated : item)
              .toList(),
        );
      });
      _showSnackBar('Project updated.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _archiveProject(AxProject project) async {
    final confirmed = await _confirmProjectAction(
      title: 'Archive project?',
      message: 'Archived projects leave the active Projects list.',
      action: 'Archive',
    );
    if (!confirmed) return;
    try {
      await widget.dataSource.archiveProject(projectId: project.id);
      if (!mounted) return;
      setState(() {
        snapshot = snapshot.copyWith(
          projects:
              snapshot.projects.where((item) => item.id != project.id).toList(),
        );
        selectedProjectId = null;
      });
      _navigateTo(const AxNavigation.home(), replace: true);
      _showSnackBar('Project archived.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _deleteProject(String projectId) async {
    final confirmed = await _confirmProjectAction(
      title: 'Delete project?',
      message: 'This permanently removes the Project and its Workstreams.',
      action: 'Delete',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await widget.dataSource.deleteProject(projectId: projectId);
      if (!mounted) return;
      setState(() {
        snapshot = snapshot.copyWith(
          projects:
              snapshot.projects.where((item) => item.id != projectId).toList(),
        );
        selectedProjectId = null;
      });
      _navigateTo(const AxNavigation.home(), replace: true);
      _showSnackBar('Project deleted.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<bool> _confirmProjectAction({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result == true;
  }

  Widget _content({required bool compact, required bool showTopHud}) {
    return Column(children: [
      if (showTopHud)
        AxTopBar(
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
          onOpenExternal: (uri) => browserNavigation.openExternal(uri),
          compact: compact,
        ),
      if (realtimeStale) _realtimeStatusBanner(),
      if (realtimeNotice != null)
        Semantics(
          liveRegion: true,
          label: realtimeNotice!,
          child: const SizedBox(width: 1, height: 1),
        ),
      Expanded(
        child: SingleChildScrollView(
          padding:
              EdgeInsets.fromLTRB(compact ? 18 : 34, 26, compact ? 18 : 34, 40),
          child: showRunDetails ? _runDetailsView(compact) : _homeView(),
        ),
      ),
    ]);
  }

  Widget _realtimeStatusBanner() => Semantics(
        liveRegion: true,
        label: realtimeNotice ?? 'Live updates are reconnecting.',
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
                realtimeNotice ?? 'Live updates are reconnecting.',
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

class _AxAppState extends State<ConclaveAppShell> with _AxAppStateMixin {}

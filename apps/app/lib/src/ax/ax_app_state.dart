part of 'ax_app.dart';

mixin _AxAppStateMixin on State<ConclaveAppShell> {
  AxSnapshot get executionSnapshot => store.execution;
  String? selectedSpaceId;
  RunStatus? optimisticRunStatus;
  bool isLoading = true;
  String? loadError;
  String? selectedTaskId = 'implement';
  final Set<String> expandedSpaceIds = <String>{};
  List<AxWorker> get workspaceWorkers =>
      store.syncEngine.peek(store.catalogs.workers).data ?? const [];
  bool get workspaceWorkerInventoryLoaded =>
      store.syncEngine.peek(store.catalogs.workers).hasData;
  final authNameController = TextEditingController();
  final authEmailController = TextEditingController();
  final authPasswordController = TextEditingController();
  final authConfirmPasswordController = TextEditingController();
  List<AxNotification> get notifications => store.notifications;
  void _updateNotifications(VoidCallback callback) {
    callback();
    store.unreadNotifications.value =
        notifications.where((n) => !n.read).length;
  }

  late final AxStore store;
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final AxBrowserNavigation browserNavigation;
  late AxNavigation navigation;
  StreamSubscription<Uri>? navigationSubscription;
  StreamSubscription<void>? lifecycleSubscription;
  StreamSubscription<bool>? connectivitySubscription;
  late final RealtimeClient realtimeClient;
  StreamSubscription<Map<String, dynamic>>? realtimeSubscription;
  bool realtimeStarted = false;
  void Function()? _cancelWorkRealtime;

  bool authRequired = false;
  bool isReconnecting = false;
  bool get realtimeStale => store.realtimeStatus.value.$1;
  set realtimeStale(bool value) =>
      store.realtimeStatus.value = (value, realtimeNotice);
  bool _realtimeTransportConnected = false;
  int _realtimeRecoveryGeneration = 0;
  String? get realtimeNotice => store.realtimeStatus.value.$2;
  set realtimeNotice(String? value) =>
      store.realtimeStatus.value = (realtimeStale, value);
  void _updateLiveState(VoidCallback callback) => callback();
  bool authSignUp = false;
  bool authResetRequest = false;
  bool authBusy = false;
  bool desktopAuthBusy = false;
  bool desktopAuthApproved = false;
  bool desktopAuthCancelled = false;
  AxDesktopAuthIntentStatus? desktopAuthIntentStatus;
  String? _desktopAuthIntentId;
  Timer? _desktopAuthStatusTimer;
  bool _desktopAuthStatusRequestActive = false;
  String? desktopAuthError;
  String? authNotice;
  String? authError;
  Timer? _queuedRealtimeNoticeTimer;
  String? _pendingQueuedRealtimeNotice;
  final promptResponseController = TextEditingController();
  final TextEditingController _searchQueryController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  AxNavigation? _navigationBeforeSearch;
  DateTime? _lastRealtimeAnnouncement;
  AxAccountSecurity? get accountSecurity => store.security.value;
  set accountSecurity(AxAccountSecurity? value) => store.security.value = value;
  final Set<String> revokingAccountSessionTokens = <String>{};
  bool avatarUploadBusy = false;
  List<int>? viewerAvatarBytes;
  bool get accountSecurityLoading => store.securityLoading.value;
  set accountSecurityLoading(bool value) => store.securityLoading.value = value;
  void _updateSecurity(VoidCallback callback) => callback();
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
            textColor: ConclaveColors.primaryForegroundDark,
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

  AxSpace? get selectedSpace {
    final id = navigation.spaceId ?? selectedSpaceId;
    if (id == null) return null;
    return store.spaceDetails.peek(id) ??
        store.spaces.items.where((space) => space.id == id).firstOrNull;
  }

  List<AxWorkspace> get workspaces => store.workspaces.items;
  AxTask? get selectedTask => executionSnapshot.tasks
      .where((task) => task.id == selectedTaskId)
      .firstOrNull;
  AxThread? get selectedThread {
    final space = selectedSpace;
    return (space == null ? <AxThread>[] : store.spaceThreads.peek(space.id))
        .where((thread) =>
            thread.id == navigation.threadId ||
            thread.id == navigation.threadId)
        .firstOrNull;
  }

  String? get executionWorkspaceId => executionSnapshot.workspaceId;
  int get unreadNotificationCount =>
      notifications.where((notification) => !notification.read).length;
  AxShellContext get _shellContext => AxShellContext(
        navigation: navigation,
        spaces: store.spaces.items,
        spaceListenable: store.spaces,
        workspaceListenable: store.workspaces,
        spaceThreads: store.spaceThreads,
        selectedSpace: selectedSpace,
        selectedThread: selectedThread,
        selectedRun: executionSnapshot.run,
        workspaces: store.workspaces.items,
        unreadNotificationCount: unreadNotificationCount,
        unreadNotifications: store.unreadNotifications,
        invitationsListenable: store.invitations,
        isDarkTheme: _themeMode == ThemeMode.dark ||
            (_themeMode == ThemeMode.system &&
                Theme.of(context).brightness == Brightness.dark),
        themeMode: _themeMode,
        realtimeStale: realtimeStale,
        realtimeListenable: store.realtimeStatus,
        realtimeNotice: realtimeNotice,
        viewerDisplayName: store.auth.viewer?.displayName,
        viewerEmail: store.auth.viewer?.email,
        viewerAvatarUrl: store.auth.viewer?.avatarUrl,
        viewerAvatarBytes: viewerAvatarBytes,
        expandedSpaceIds: expandedSpaceIds,
      );
  void _toggleSpaceExpanded(String spaceId) {
    setState(() {
      if (expandedSpaceIds.contains(spaceId)) {
        expandedSpaceIds.remove(spaceId);
      } else {
        expandedSpaceIds.add(spaceId);
      }
    });
  }

  void _updateState(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    _searchQueryController.addListener(_onSearchQueryChanged);
    browserNavigation = widget.browserNavigation ?? createAxBrowserNavigation();
    final initialUri = widget.initialUri ?? browserNavigation.current;
    navigation = AxNavigation.fromUri(initialUri);
    // Expand deep links once; data refreshes must preserve manual collapse.
    if (navigation.kind == AxRouteKind.thread &&
        (navigation.spaceId != null || navigation.spaceId != null)) {
      expandedSpaceIds.add(navigation.spaceId!);
    }
    _desktopAuthIntentId = _intentIdFromNavigation(navigation);
    if (!_isCanonicalWorkspaceUri(initialUri, navigation.toUri())) {
      browserNavigation.replace(navigation.toUri());
    }
    navigationSubscription =
        browserNavigation.changes.listen(_onBrowserNavigation);
    realtimeClient = widget.realtimeClient ?? createRealtimeClient();
    realtimeSubscription = realtimeClient.events.listen(_onRealtimeEvent);
    store = AxStore(widget.dataSource);
    lifecycleSubscription = browserNavigation.lifecycleChanges.listen((_) {
      unawaited(() async {
        await _syncSession();
        if (mounted && store.auth.session?.authenticated == true) {
          await store.lifecycle.resume();
        }
      }());
    });
    final connectivity = browserNavigation;
    if (connectivity is AxBrowserConnectivity) {
      final network = connectivity as AxBrowserConnectivity;
      unawaited(store.lifecycle
          .connectivityChanged(network.online, revalidate: false));
      connectivitySubscription = network.connectivityChanges.listen((online) {
        unawaited(store.lifecycle.connectivityChanged(online,
            revalidate: store.auth.session?.authenticated == true));
      });
    }
    _cancelWorkRealtime = store.workRealtime.listen(realtimeClient.events);
    if (_desktopAuthIntentId != null) {
      unawaited(_pollDesktopAuthStatus());
      _desktopAuthStatusTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_pollDesktopAuthStatus()),
      );
    }
    unawaited(_loadSession());
  }

  @override
  void dispose() {
    _desktopAuthStatusTimer?.cancel();
    _queuedRealtimeNoticeTimer?.cancel();
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
    unawaited(connectivitySubscription?.cancel());
    _cancelWorkRealtime?.call();
    store.dispose();
    store.workRealtime.dispose();
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
  Widget build(BuildContext context) => _buildApp(context);

  Future<void> _createSpace() async {
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
              name.isEmpty ? 'My first space' : name,
              description.trim().isEmpty ? null : description.trim(),
              instructions.trim().isEmpty ? null : instructions.trim(),
            ),
          );
        }

        return AlertDialog(
          title: const Text('Create Space'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  onChanged: (value) => name = value,
                  onSubmitted: (_) => submit(),
                  decoration: const InputDecoration(labelText: 'Space name'),
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
                    labelText: 'Space instructions (optional)',
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
    try {
      final space = await store.collaboration.createSpace(
          name: values.$1, description: values.$2, instructions: values.$3);
      if (!mounted) return;
      _navigateTo(AxNavigation.space(space.id), replace: true);
      _showSnackBar('Space created. Create a Thread to get started.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _createThread([AxSpace? targetSpace]) async {
    final space = targetSpace ?? selectedSpace;
    if (space == null) return;
    var name = '';
    final created = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Thread'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => name = value,
          onSubmitted: (_) {
            if (name.trim().isNotEmpty) {
              Navigator.pop(dialogContext, name.trim());
            }
          },
          decoration: const InputDecoration(
            labelText: 'Thread name',
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
    try {
      final thread = await store.collaboration
          .createThread(spaceId: space.id, name: created);
      if (!mounted) return;
      setState(() => expandedSpaceIds.add(space.id));
      _navigateTo(AxNavigation.thread(space.id, thread.id));
      _showSnackBar('Thread created.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _editSpace(AxSpace space) async {
    var name = space.name;
    var description = space.description;
    var instructions = space.instructions;
    String? errorText;
    final values = await showDialog<(String, String, String)?>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final trimmedName = name.trim();
            if (trimmedName.isEmpty) {
              setDialogState(() {
                errorText = 'Space name cannot be empty.';
              });
              return;
            }
            Navigator.pop(
              dialogContext,
              (trimmedName, description.trim(), instructions.trim()),
            );
          }

          return AlertDialog(
            title: const Text('Edit Space'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      initialValue: space.name,
                      autofocus: true,
                      onChanged: (value) {
                        name = value;
                        if (errorText != null) {
                          setDialogState(() => errorText = null);
                        }
                      },
                      onFieldSubmitted: (_) => submit(),
                      decoration: InputDecoration(
                        labelText: 'Space Name',
                        errorText: errorText,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: space.description,
                      onChanged: (value) => description = value,
                      decoration:
                          const InputDecoration(labelText: 'Description'),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: space.instructions,
                      onChanged: (value) => instructions = value,
                      decoration:
                          const InputDecoration(labelText: 'Instructions'),
                      maxLines: 4,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (values == null || values.$1.isEmpty) return;
    try {
      await store.collaboration.editSpace(
        space,
        name: values.$1,
        description: values.$2,
        instructions: values.$3,
      );
      if (!mounted) return;
      _showSnackBar('Space updated.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _archiveSpace(AxSpace space) async {
    final confirmed = await _confirmSpaceAction(
      title: 'Archive Space?',
      message: 'Archived spaces leave the active Spaces list.',
      action: 'Archive',
    );
    if (!confirmed) return;
    try {
      await widget.dataSource.archiveSpace(spaceId: space.id);
      unawaited(store.archivedSpaces
          .refresh()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      store.syncEngine.remove(store.spaceDetails.query(space.id).key);
      store.spaceThreads.engine.remove(store.spaceThreads.query(space.id).key);
      expandedSpaceIds.remove(space.id);
      if (!mounted) return;
      store.spaces.replace(
          store.spaces.items.where((item) => item.id != space.id).toList());
      selectedSpaceId = null;
      _navigateTo(const AxNavigation.home(), replace: true);
      _showSnackBar('Space archived.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _deleteSpace(String spaceId) async {
    final confirmed = await _confirmSpaceAction(
      title: 'Delete Space?',
      message: 'This permanently removes the Space and its Threads.',
      action: 'Delete',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await widget.dataSource.deleteSpace(spaceId: spaceId);
      unawaited(store.archivedSpaces
          .refresh()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      store.syncEngine.remove(store.spaceDetails.query(spaceId).key);
      store.spaceThreads.engine.remove(store.spaceThreads.query(spaceId).key);
      expandedSpaceIds.remove(spaceId);
      if (!mounted) return;
      store.spaces.replace(
          store.spaces.items.where((item) => item.id != spaceId).toList());
      selectedSpaceId = null;
      _navigateTo(const AxNavigation.home(), replace: true);
      _showSnackBar('Space deleted.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<bool> _confirmSpaceAction({
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
                ? FilledButton.styleFrom(backgroundColor: ConclaveColors.error)
                : null,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result == true;
  }
}

class _AxAppState extends State<ConclaveAppShell> with _AxAppStateMixin {}

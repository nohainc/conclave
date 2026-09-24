import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation/studio_browser_navigation.dart';
import '../navigation/studio_navigation.dart';
import '../notifications/notification_models.dart';
import '../platform/platform_services.dart';
import '../realtime/realtime_client.dart';
import '../brand.dart';
import '../features/common/toast_overlay.dart';
import '../features/common/code_block_view.dart';
import '../features/common/command_palette.dart';
import '../features/common/diff_viewer.dart';
import '../features/chat/typing_indicator.dart';
import '../features/chat/prompt_composer.dart';
import '../features/execution/task_pipeline_dag.dart';
import '../features/home/home_page.dart';
import '../features/navigation/studio_shell_context.dart';
import '../features/navigation/studio_sidebar.dart';
import '../features/navigation/studio_top_bar.dart';
import '../features/projects/projects_pages.dart';
import '../features/workspace/workspaces_page.dart';
import 'studio_models.dart';
import 'studio_data.dart';
import 'studio_stores.dart';

enum _ChatDeliveryStatus { pending, failed }

class _PendingChatMessage {
  _PendingChatMessage({required this.id, required this.text});

  final String id;
  final String text;
  _ChatDeliveryStatus status = _ChatDeliveryStatus.pending;
  String? error;
}

class ConclaveAppShell extends StatefulWidget {
  const ConclaveAppShell(
      {super.key,
      required this.services,
      required this.dataSource,
      this.initialUri});

  final PlatformServices services;
  final StudioDataSource dataSource;
  final Uri? initialUri;

  @override
  State<ConclaveAppShell> createState() => _StudioAppState();
}

/// Compatibility alias while downstream integrations migrate to the app-shell name.
typedef StudioApp = ConclaveAppShell;

class _StudioAppState extends State<ConclaveAppShell> {
  late StudioSnapshot snapshot;
  String? selectedProjectId;
  RunStatus? optimisticRunStatus;
  Timer? refreshTimer;
  bool isLoading = true;
  String? loadError;
  String? selectedTaskId = 'implement';
  String? selectedChatId;
  final Set<String> expandedProjectIds = <String>{};
  bool showNewGoal = false;
  String? workerActionMessage;
  StudioHostEnrollment? enrollmentResult;
  StudioQualityPreset selectedQuality = StudioQualityPreset.balanced;
  String selectedExecutionWorker = 'Auto';
  String selectedExecutionModel = 'Auto';
  String selectedExecutionAccount = 'Auto';
  String selectedExecutionHost = 'Auto';
  bool showAdvancedExecution = false;
  bool isSendingChat = false;
  final Map<String, bool> workerEnabled = {};
  final objectiveController = TextEditingController();
  final revisionController = TextEditingController();
  final chatController = TextEditingController();
  final authNameController = TextEditingController();
  final authEmailController = TextEditingController();
  final authPasswordController = TextEditingController();
  final authConfirmPasswordController = TextEditingController();
  final List<StudioChatMessage> localChatMessages = [];
  final List<_PendingChatMessage> pendingChatMessages = [];
  final List<StudioNotification> notifications = [];
  late final StudioStore store;
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final StudioBrowserNavigation browserNavigation;
  late StudioNavigation navigation;
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
  String? authNotice;
  String? authError;
  String? pendingRunPrompt;
  final promptResponseController = TextEditingController();
  DateTime? _lastRealtimeAnnouncement;
  List<StudioPendingInvitation> pendingInvitations = const [];
  StudioAccountSecurity? accountSecurity;
  bool accountSecurityLoading = false;
  ThemeMode _themeMode = ThemeMode.system;
  final List<ToastMessage> activeToasts = [];
  String usageRange = '30d';
  String usageProjectFilter = 'all';
  String usageUserFilter = 'all';
  String usageAccountFilter = 'all';
  String usageWorkerFilter = 'all';
  String usageProviderFilter = 'all';
  String usageModelFilter = 'all';
  DateTimeRange? usageCustomRange;

  bool get showRunDetails => switch (navigation.kind) {
        StudioRouteKind.home || StudioRouteKind.chat => false,
        _ => true,
      };

  void _showSnackBar(String message, {ToastType type = ToastType.info}) {
    _showToast(message, type: type);
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  void _showToast(String message, {ToastType type = ToastType.info}) {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final toast = ToastMessage(id: id, message: message, type: type);
    setState(() => activeToasts.add(toast));
    Future<void>.delayed(toast.duration, () {
      if (mounted) {
        setState(() => activeToasts.removeWhere((t) => t.id == id));
      }
    });
  }

  void _openCommandPalette() {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => CommandPaletteDialog(
        snapshot: snapshot,
        onSelectProject: (projectId) {
          setState(() {
            selectedProjectId = projectId;
          });
          unawaited(_loadSnapshot(projectId: projectId));
        },
        onSelectChat: (projectId, chatId) {
          setState(() {
            selectedProjectId = projectId;
            selectedChatId = chatId;
          });
          unawaited(_loadSnapshot(projectId: projectId));
        },
        onNavigateTo: (target) => _navigateTo(target, replace: true),
        onToggleTheme: () {
          setState(() {
            _themeMode =
                _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
          });
        },
        onNewGoal: () {
          setState(() {
            showNewGoal = true;
          });
        },
      ),
    );
  }



  StudioProject? get selectedProject => snapshot.projects
      .where((project) => project.id == selectedProjectId)
      .firstOrNull;

  List<StudioWorkspace> get workspaces => store.workspaces.items;

  StudioTask? get selectedTask =>
      snapshot.tasks.where((task) => task.id == selectedTaskId).firstOrNull;

  StudioChat? get selectedChat =>
      snapshot.allChats
          .where((chat) => chat.id == (selectedChatId ?? snapshot.activeChatId))
          .firstOrNull ??
      snapshot.activeChat;

  StudioWorkstream? get selectedWorkstream {
    final project = selectedProject;
    return project?.workstreams
        .where((workstream) => workstream.id == navigation.workstreamId)
        .firstOrNull;
  }

  String? get executionWorkspaceId => snapshot.workspaceId;

  int get unreadNotificationCount =>
      notifications.where((notification) => !notification.read).length;

  StudioShellContext get _shellContext => StudioShellContext(
        navigation: navigation,
        projects: snapshot.projects,
        selectedProject: selectedProject,
        selectedWorkstream: selectedWorkstream,
        selectedRun: snapshot.run,
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        accounts: snapshot.accounts,
        unreadNotificationCount: unreadNotificationCount,
        isDarkTheme: _themeMode == ThemeMode.dark ||
            (_themeMode == ThemeMode.system &&
                Theme.of(context).brightness == Brightness.dark),
        realtimeStale: realtimeStale,
        realtimeNotice: realtimeNotice,
        viewerDisplayName: store.auth.viewer?.displayName ??
            snapshot.viewer?.displayName,
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

  @override
  void initState() {
    super.initState();
    browserNavigation = createStudioBrowserNavigation();
    navigation = StudioNavigation.fromUri(
        widget.initialUri ?? browserNavigation.current);
    navigationSubscription =
        browserNavigation.changes.listen(_onBrowserNavigation);
    lifecycleSubscription = browserNavigation.lifecycleChanges
        .listen((_) => unawaited(_syncSession()));
    realtimeClient = createRealtimeClient();
    realtimeSubscription = realtimeClient.events.listen(_onRealtimeEvent);
    store = StudioStore(widget.dataSource);
    snapshot = StudioSnapshot.empty();
    unawaited(_loadSession());
  }

  Future<void> _loadSession() async {
    try {
      final session = await store.auth.load();
      pendingInvitations = session.pendingInvitations;
      if (!session.authenticated) {
        if (!mounted) return;
        setState(() {
          authRequired = true;
          isLoading = false;
        });
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      await _loadWorkspaces();
      await _loadSnapshot();
      if (navigation.kind == StudioRouteKind.profileSecurity) {
        await _loadAccountSecurity();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          isLoading = false;
          loadError = 'Authentication service is unavailable.';
        });
      }
    }
  }

  Future<void> _logout() async {
    try {
      await store.auth.logout();
      if (!mounted) return;
      setState(() {
        snapshot = StudioSnapshot.empty();
        selectedProjectId = null;
        authRequired = true;
        pendingInvitations = const [];
      });
      browserNavigation.replaceWithLogin(navigation.toUri());
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Future<void> _submitEmailAuth() async {
    final email = authEmailController.text.trim();
    final password = authPasswordController.text;
    final confirmPassword = authConfirmPasswordController.text;
    final resetToken = browserNavigation.current.queryParameters['token'];
    if ((resetToken == null && email.isEmpty) ||
        (password.isEmpty && (!authResetRequest || resetToken != null))) {
      setState(() => authError = 'Enter your email and password.');
      return;
    }
    if (authSignUp && authNameController.text.trim().isEmpty) {
      setState(() => authError = 'Enter your name.');
      return;
    }
    if ((authSignUp || resetToken != null) && password != confirmPassword) {
      setState(() => authError = 'The passwords do not match.');
      return;
    }
    setState(() {
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
          setState(() {
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
          setState(() {
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
      setState(() {
        authBusy = false;
        authRequired = false;
        isLoading = true;
      });
      await _loadSession();
    } catch (error) {
      if (!mounted) return;
      setState(() {
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
              title: const Text('About Conclave AX'),
              content: const Text(
                  'Conclave AX coordinates AI Workers across models and machines to research, implement, review, test, and verify complex work.'),
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
            ));
  }

  Future<void> _loadWorkspaces() async {
    try {
      await store.workspaces.list();
      if (!mounted) return;
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
      setState(() {
        realtimeStale = status == 'reconnecting';
        realtimeNotice = realtimeStale
            ? 'Live updates paused. Conclave AX is reconnecting.'
            : 'Live updates connected.';
      });
      return;
    }
    if (type == 'realtime.ready') {
      setState(() => realtimeStale = false);
      return;
    }
    if (type == 'reconnect.required') {
      final scope = event['scope'];
      final scopeMap = scope is Map
          ? Map<String, dynamic>.from(scope)
          : const <String, dynamic>{};
      setState(() {
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
        setState(() => pendingRunPrompt = prompt.trim());
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
      if (type.startsWith('host.') || type.startsWith('desired_state.')) {
        final hosts = await store.agents.refresh(workspaceId);
        if (!mounted) return;
        setState(() => snapshot = snapshot.copyWith(agents: hosts));
        return;
      }
      if (type.startsWith('worker.')) {
        final workers = await store.workers.refresh(workspaceId);
        if (!mounted) return;
        setState(() => snapshot = snapshot.copyWith(workers: workers));
        return;
      }
      if (type.startsWith('account.') || type.startsWith('credential.')) {
        final accounts = await store.accounts.refresh(workspaceId);
        if (!mounted) return;
        setState(() => snapshot = snapshot.copyWith(accounts: accounts));
        return;
      }
      if (type.startsWith('project.') || type.startsWith('chat.')) {
        final projects = await store.projects.refresh();
        if (!mounted) return;
        store.chats
            .replace(projects.expand((project) => project.chats).toList());
        setState(() => snapshot = snapshot.copyWith(projects: projects));
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

  String? _lastRealtimeProjectId;

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
    setState(() {
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
    final selected = await showDialog<StudioNotification>(
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
                          StudioNotificationKind.completed =>
                            Icons.check_circle_outline,
                          StudioNotificationKind.failed => Icons.error_outline,
                          StudioNotificationKind.approvalRequired =>
                            Icons.help_outline,
                          StudioNotificationKind.hostOffline =>
                            Icons.cloud_off_outlined,
                          StudioNotificationKind.accountExpired =>
                            Icons.key_off_outlined,
                          StudioNotificationKind.workerInstallFailed =>
                            Icons.download_for_offline_outlined,
                          StudioNotificationKind.invitationReceived =>
                            Icons.mail_outline,
                        },
                        color: notification.read
                            ? const Color(0xff8e8e9a)
                            : notification.priority ==
                                    StudioNotificationPriority.high
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
                    setState(() {
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
    setState(() {
      final index = notifications.indexWhere((item) => item.id == selected.id);
      if (index >= 0) notifications[index] = notifications[index].markRead();
    });
    _navigateToNotification(selected);
  }

  void _navigateToNotification(StudioNotification notification) {
    switch (notification.target) {
      case StudioNotificationTarget.run:
        if (notification.projectId != null && notification.runId != null) {
          _navigateTo(StudioNavigation.run(
              notification.projectId!, notification.runId!));
        }
      case StudioNotificationTarget.hosts:
        _navigateTo(const StudioNavigation.hosts());
      case StudioNotificationTarget.workers:
        _navigateTo(const StudioNavigation.workers());
      case StudioNotificationTarget.accounts:
        _navigateTo(const StudioNavigation.accounts());
      case StudioNotificationTarget.workspace:
        _navigateTo(const StudioNavigation.hosts());
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
      setState(() => realtimeNotice = summary.trim());
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
      chatId: selectedChatId,
      runId: navigation.runId,
      executionWorkspaceId: workspaceId,
    ));
  }

  Future<void> _loadAccountSecurity() async {
    if (!mounted) return;
    setState(() => accountSecurityLoading = true);
    try {
      final loaded = await widget.dataSource.loadAccountSecurity();
      if (!mounted) return;
      setState(() {
        accountSecurity = loaded;
        accountSecurityLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        accountSecurityLoading = false;
        loadError = error.toString();
      });
    }
  }

  Future<void> _revokeAccountSession(StudioAuthSession session) async {
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
          .beginAccountLink(provider, Uri(path: '/account'));
      browserNavigation.openExternal(uri);
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  Future<void> _requestCredentialSetup(StudioCredentialProfile account) async {
    final workspaceId = executionWorkspaceId;
    if (workspaceId == null) return;
    try {
      await widget.dataSource.requestCredentialSetup(
        workspaceId: workspaceId,
        profileId: account.id,
      );
      if (mounted) {
        _showSnackBar('Local Account setup requested on the Workspace.');
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar(error.toString());
      }
    }
  }

  Future<void> _revokeCredentialProfile(StudioCredentialProfile account) async {
    final workspaceId = executionWorkspaceId;
    if (workspaceId == null) return;
    try {
      await widget.dataSource.revokeCredentialProfile(
        workspaceId: workspaceId,
        profileId: account.id,
      );
      await _loadSnapshot(workspaceId: workspaceId, showSpinner: false);
      if (mounted) {
        _showSnackBar('Account revoked.');
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar(error.toString());
      }
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

  Future<void> _deletePasskey(StudioPasskey passkey) async {
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
      setState(() {
        isLoading = true;
        loadError = null;
        isReconnecting = reconnecting;
      });
    }
    try {
      final loaded =
          await store.reload(projectId: projectId, workspaceId: workspaceId);
      if (!mounted) return;
      setState(() {
        snapshot = loaded;
        optimisticRunStatus = null;
        selectedQuality = loaded.policy?.preset ?? selectedQuality;
        selectedProjectId = loaded.projects.any(
                (project) => project.id == (projectId ?? selectedProjectId))
            ? (projectId ?? selectedProjectId)
            : loaded.projects.firstOrNull?.id;
        selectedChatId = navigation.kind == StudioRouteKind.chat
            ? (loaded.activeChatId ?? loaded.activeChat?.id)
            : null;
        isLoading = false;
        isReconnecting = false;
        authRequired = false;
        _applyNavigationToSnapshot(loaded);
        if (loaded.run?.status == RunStatus.paused) {
          // The API is the source of truth; no local pause state is maintained.
        }
      });
      _scheduleRefresh(loaded);
    } catch (error) {
      if (!mounted) return;
      if (error is StudioApiException && error.statusCode == 401) {
        setState(() => authRequired = true);
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      setState(() {
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
      pendingInvitations = session.pendingInvitations;
      if (!session.authenticated && !authRequired) {
        setState(() => authRequired = true);
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      if (session.authenticated && authRequired) {
        final target = navigation.loginReturnTo == null
            ? const StudioNavigation.home()
            : StudioNavigation.fromUri(
                Uri.parse(navigation.loginReturnTo!),
              );
        setState(() {
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

  void _applyNavigationToSnapshot(StudioSnapshot loaded) {
    final routeProject = navigation.projectId;
    if (routeProject != null &&
        loaded.projects.any((project) => project.id == routeProject)) {
      selectedProjectId = routeProject;
    }
    final project = loaded.projects
        .where((value) => value.id == selectedProjectId)
        .firstOrNull;
    if (navigation.kind == StudioRouteKind.chat &&
        navigation.chatId != null &&
        project?.chats.any((chat) => chat.id == navigation.chatId) == true) {
      selectedChatId = navigation.chatId;
    } else if (navigation.kind != StudioRouteKind.chat) {
      selectedChatId = null;
    }
    if (navigation.kind == StudioRouteKind.workstream &&
        navigation.projectId != null) {
      expandedProjectIds.add(navigation.projectId!);
    }
  }

  void _onBrowserNavigation(Uri uri) {
    final next = StudioNavigation.fromUri(uri);
    if (next == navigation) return;
    final projectChanged =
        next.projectId != null && next.projectId != selectedProjectId;
    setState(() {
      navigation = next;
      selectedProjectId = next.projectId ?? selectedProjectId;
      selectedChatId =
          next.kind == StudioRouteKind.chat ? next.chatId : null;
      if (next.kind == StudioRouteKind.workstream && next.projectId != null) {
        expandedProjectIds.add(next.projectId!);
      }
    });
    if (next.kind == StudioRouteKind.profileSecurity) {
      unawaited(_loadAccountSecurity());
    }
    if (projectChanged) {
      unawaited(_loadSnapshot(projectId: next.projectId));
    }
    unawaited(realtimeClient.setScopes(
      projectId: next.projectId ?? selectedProjectId,
      chatId: next.chatId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  void _navigateTo(StudioNavigation next, {bool replace = false}) {
    setState(() {
      navigation = next;
      selectedProjectId = next.projectId ?? selectedProjectId;
      selectedChatId =
          next.kind == StudioRouteKind.chat ? next.chatId : null;
      if (next.kind == StudioRouteKind.workstream && next.projectId != null) {
        expandedProjectIds.add(next.projectId!);
      }
    });
    if (replace) {
      browserNavigation.replace(next.toUri());
    } else {
      browserNavigation.push(next.toUri());
    }
  }

  void _scheduleRefresh(StudioSnapshot loaded) {
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

  Future<void> _revokeAgent(String agentId) async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    try {
      await store.agents.revoke(workspaceId, agentId);
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Future<void> _announceAgentUpdate(StudioAgent agent) async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    try {
      await store.agents.announceUpdate(
        workspaceId,
        agent.id,
        channel: agent.updateChannel == '—' ? 'stable' : agent.updateChannel,
      );
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
      if (!mounted) return;
      _showSnackBar('Update announced to the Workspace.');
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Future<void> _renameHost(StudioAgent host) async {
    final controller = TextEditingController(text: host.name);
    final name = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Workspace'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Workspace name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    final workspaceId = snapshot.workspaceId;
    if (name == null || name.trim().isEmpty || workspaceId == null) return;
    try {
      await store.agents.updateHost(workspaceId, host.id, name: name.trim());
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
      if (mounted) _showSnackBar('Workspace renamed.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _bindHost(StudioAgent host) async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null) return;
    try {
      await store.agents.bindWorkspace(workspaceId, host.id);
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
      if (mounted) _showSnackBar('Workspace grant saved.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }



  Future<void> _enrollAgent() async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    var platform = 'macOS';
    final selected = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Workspace'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Choose the machine where Conclave Workspace will run.'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: platform,
                decoration: const InputDecoration(labelText: 'Platform'),
                items: const ['macOS', 'Windows', 'Linux']
                    .map((value) =>
                        DropdownMenuItem(value: value, child: Text(value)))
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => platform = value ?? platform),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, platform),
                child: const Text('Continue')),
          ],
        ),
      ),
    );
    if (selected == null) return;
    try {
      final enrollment = await store.agents.createEnrollment(workspaceId);
      if (!mounted) return;
      setState(() {
        enrollmentResult = enrollment;
        loadError = null;
      });
      _showSnackBar(
          'Download Conclave Workspace for $selected, then enter the one-time code.');
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  // Retained only while the legacy data adapter is being retired. It
  // is no longer reachable from the v4 catalog UI.
  // ignore: unused_element
  Future<void> _editWorker([StudioWorker? existing]) async {
    if (snapshot.agents.isEmpty || snapshot.plugins.isEmpty) {
      if (mounted) {
        setState(() => workerActionMessage =
            'Connect a Workspace and make a Worker available before starting work.');
        await showDialog<void>(
          context: navigatorKey.currentContext ?? context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Worker prerequisites missing'),
            content: const Text(
                'A Worker needs one connected Workspace and an available Worker package. '
                'Open Workspaces or Workers in the navigation to finish setup, then '
                'return here.'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final workspaceId = executionWorkspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      if (mounted) {
        setState(() => workerActionMessage =
            'Select a workspace before creating a Worker.');
        await showDialog<void>(
          context: navigatorKey.currentContext ?? context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Workspace required'),
            content: const Text(
                'Select a workspace from the sidebar, then try creating the '
                'Worker again.'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final nameController = TextEditingController(text: existing?.name ?? '');
    final rolesController = TextEditingController(
        text: (existing?.roles.isNotEmpty == true
                ? existing!.roles
                : const ['researcher'])
            .join(', '));
    final capabilitiesController = TextEditingController(
        text: (existing?.capabilities.isNotEmpty == true
                ? existing!.capabilities
                : const ['repository_read'])
            .join(', '));
    final configController = TextEditingController(
        text:
            const JsonEncoder.withIndent('  ').convert(existing?.config ?? {}));
    final versionPolicyController =
        TextEditingController(text: existing?.workerVersionPolicy ?? 'latest');
    final independenceController =
        TextEditingController(text: existing?.independenceKey ?? '');
    final concurrencyController =
        TextEditingController(text: '${existing?.concurrencyLimit ?? 1}');
    final configuredAgentId = existing?.agentId;
    var agentId = configuredAgentId != null &&
            snapshot.agents.any((agent) => agent.id == configuredAgentId)
        ? configuredAgentId
        : snapshot.agents.firstOrNull?.id;
    final configuredPluginId = existing?.workerCatalogId;
    var workerCatalogId = configuredPluginId != null &&
            snapshot.plugins.any((plugin) => plugin.id == configuredPluginId)
        ? configuredPluginId
        : snapshot.plugins.firstOrNull?.id;
    var enabled = existing?.status.toLowerCase() != 'disabled';
    var sessionPolicy = existing?.sessionPolicy ?? 'stateless';
    var billingMode = existing?.billingMode ?? 'local_compute';
    bool? saved;
    try {
      saved = await showDialog<bool>(
        context: navigatorKey.currentContext ?? context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(existing == null ? 'Create Worker' : 'Edit Worker'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: nameController,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: agentId,
                  decoration: const InputDecoration(labelText: 'Workspace'),
                  items: snapshot.agents
                      .map((agent) => DropdownMenuItem(
                          value: agent.id, child: Text(agent.name)))
                      .toList(),
                  onChanged: (value) => setDialogState(() => agentId = value),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: workerCatalogId,
                  decoration: const InputDecoration(labelText: 'Worker'),
                  items: snapshot.plugins
                      .map((plugin) => DropdownMenuItem(
                          value: plugin.id, child: Text(plugin.name)))
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => workerCatalogId = value),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: rolesController,
                    decoration: const InputDecoration(
                        labelText: 'Roles (comma separated)')),
                const SizedBox(height: 10),
                TextField(
                    controller: capabilitiesController,
                    decoration: const InputDecoration(
                        labelText: 'Capabilities (comma separated)')),
                const SizedBox(height: 10),
                TextField(
                    controller: versionPolicyController,
                    decoration: const InputDecoration(
                        labelText: 'Worker version policy')),
                const SizedBox(height: 10),
                TextField(
                    controller: configController,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                        labelText: 'Model/config (JSON)')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: sessionPolicy,
                  decoration:
                      const InputDecoration(labelText: 'Session policy'),
                  items: const [
                    DropdownMenuItem(
                        value: 'stateless', child: Text('Stateless')),
                    DropdownMenuItem(
                        value: 'isolated_workspace',
                        child: Text('Isolated workspace')),
                    DropdownMenuItem(
                        value: 'reuse_session', child: Text('Reuse session')),
                    DropdownMenuItem(
                        value: 'persistent_context',
                        child: Text('Persistent context')),
                  ],
                  onChanged: (value) => setDialogState(() {
                    if (value != null) sessionPolicy = value;
                  }),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: concurrencyController,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Concurrency limit')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: billingMode,
                  decoration: const InputDecoration(labelText: 'Billing mode'),
                  items: const [
                    DropdownMenuItem(
                        value: 'local_compute', child: Text('Local compute')),
                    DropdownMenuItem(
                        value: 'subscription', child: Text('Subscription')),
                    DropdownMenuItem(
                        value: 'api_metered', child: Text('API metered')),
                    DropdownMenuItem(
                        value: 'external', child: Text('External')),
                    DropdownMenuItem(value: 'manual', child: Text('Manual')),
                    DropdownMenuItem(value: 'free', child: Text('Free')),
                  ],
                  onChanged: (value) => setDialogState(() {
                    if (value != null) billingMode = value;
                  }),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: independenceController,
                    decoration: const InputDecoration(
                        labelText: 'Independence key (optional)')),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enabled'),
                    value: enabled,
                    onChanged: (value) =>
                        setDialogState(() => enabled = value)),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: nameController.text.trim().isEmpty ||
                        agentId == null ||
                        workerCatalogId == null
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        _showSnackBar('Could not open Worker editor: $error');
      }
      nameController.dispose();
      rolesController.dispose();
      capabilitiesController.dispose();
      configController.dispose();
      versionPolicyController.dispose();
      independenceController.dispose();
      concurrencyController.dispose();
      return;
    }
    if (saved != true || agentId == null || workerCatalogId == null) {
      nameController.dispose();
      rolesController.dispose();
      capabilitiesController.dispose();
      configController.dispose();
      versionPolicyController.dispose();
      independenceController.dispose();
      concurrencyController.dispose();
      return;
    }
    try {
      await store.workers.save(
        workspaceId: workspaceId,
        workerId: existing?.id,
        name: nameController.text.trim(),
        agentId: agentId!,
        workerCatalogId: workerCatalogId!,
        roles: rolesController.text
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
        capabilities: capabilitiesController.text
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
        enabled: enabled,
        workerVersionPolicy: versionPolicyController.text.trim().isEmpty
            ? 'latest'
            : versionPolicyController.text.trim(),
        config: _parseWorkerConfig(configController.text),
        sessionPolicy: sessionPolicy,
        concurrencyLimit: _parseConcurrency(concurrencyController.text),
        billingMode: billingMode,
        independenceKey: independenceController.text.trim(),
      );
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    } finally {
      nameController.dispose();
      rolesController.dispose();
      capabilitiesController.dispose();
      configController.dispose();
      versionPolicyController.dispose();
      independenceController.dispose();
      concurrencyController.dispose();
    }
  }

  Map<String, dynamic> _parseWorkerConfig(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
    } catch (_) {
      // The API will not receive malformed config; the editor falls back to {}.
    }
    return <String, dynamic>{};
  }

  int _parseConcurrency(String value) {
    final parsed = int.tryParse(value.trim()) ?? 1;
    return parsed < 1 ? 1 : parsed;
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    navigationSubscription?.cancel();
    lifecycleSubscription?.cancel();
    realtimeSubscription?.cancel();
    unawaited(realtimeClient.close());
    browserNavigation.dispose();
    objectiveController.dispose();
    revisionController.dispose();
    chatController.dispose();
    promptResponseController.dispose();
    authNameController.dispose();
    authEmailController.dispose();
    authPasswordController.dispose();
    authConfirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _createGoal() async {
    final projectId = selectedProjectId;
    final objective = objectiveController.text.trim();
    final commitSha = revisionController.text.trim();
    if (projectId == null || objective.isEmpty || commitSha.isEmpty) {
      if (mounted) {
        _showSnackBar('Enter an objective and expected commit SHA.');
      }
      return;
    }
    try {
      await store.dataSource.createGoal(
        projectId: projectId,
        objective: objective,
        revision: commitSha,
      );
      objectiveController.clear();
      if (!mounted) return;
      setState(() => showNewGoal = false);
      await _loadSnapshot(projectId: projectId);
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
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
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              _openCommandPalette,
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _openCommandPalette,
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
                  if (isLoading) return _loadingScaffold();
                  if (authRequired) return _authScaffold();
                  if (loadError != null) return _errorScaffold();
                  final isDesktop = constraints.maxWidth >= 1100;
                  final isTablet = constraints.maxWidth >= 768 &&
                      constraints.maxWidth < 1100;
                  final isMobile = constraints.maxWidth < 768;
                  final shell = _shellContext;

                  return Scaffold(
                    drawer: (isTablet || isMobile)
                        ? Drawer(
                            child: StudioSidebar(
                              shellContext: shell,
                              onNavigateTo: _navigateTo,
                              onToggleProjectExpanded: _toggleProjectExpanded,
                              onCreateProject: _createProject,
                              onCreateWorkstream: _createWorkstream,
                              onToggleTheme: _toggleTheme,
                              onLogout: () => unawaited(_logout()),
                              onOpenAbout: () =>
                                  unawaited(_showAboutConclave()),
                              onOpenExternal: (uri) =>
                                  browserNavigation.openExternal(uri),
                              compact: true,
                            ),
                          )
                        : null,
                    body: Row(
                      children: [
                        if (isDesktop)
                          SizedBox(
                            width: 248,
                            child: StudioSidebar(
                              shellContext: shell,
                              onNavigateTo: _navigateTo,
                              onToggleProjectExpanded:
                                  _toggleProjectExpanded,
                              onCreateProject: _createProject,
                              onCreateWorkstream: _createWorkstream,
                              onToggleTheme: _toggleTheme,
                              onLogout: () => unawaited(_logout()),
                              onOpenAbout: () =>
                                  unawaited(_showAboutConclave()),
                              onOpenExternal: (uri) =>
                                  browserNavigation.openExternal(uri),
                            ),
                          )
                        else if (isTablet)
                          SizedBox(
                            width: 64,
                            child: StudioIconRail(
                              shellContext: shell,
                              onNavigateTo: _navigateTo,
                              onOpenDrawer: () =>
                                  Scaffold.of(context).openDrawer(),
                              onToggleTheme: _toggleTheme,
                              onLogout: () => unawaited(_logout()),
                              onOpenAbout: () =>
                                  unawaited(_showAboutConclave()),
                              onOpenExternal: (uri) =>
                                  browserNavigation.openExternal(uri),
                            ),
                          ),
                        Expanded(child: _content(isMobile)),
                      ],
                    ),
                  );
                },
              ),
              ToastOverlay(
                toasts: activeToasts,
                onDismiss: (id) =>
                    setState(() => activeToasts.removeWhere((t) => t.id == id)),
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
                    Container(
                      width: 52,
                      height: 52,
                      decoration: ConclaveBrand.brandMark,
                      alignment: Alignment.center,
                      child: const Text('C',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w800)),
                    ),
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
                                    : 'Sign in securely to access your Projects, Workspaces, Workers, and Accounts.',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    if (!resetPassword && authSignUp) ...[
                      TextField(
                        controller: authNameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Name'),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (!resetPassword) ...[
                      TextField(
                        controller: authEmailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: 'Email'),
                      ),
                      if (!authResetRequest) const SizedBox(height: 10),
                    ],
                    if (resetPassword || !authResetRequest) ...[
                      TextField(
                        controller: authPasswordController,
                        obscureText: true,
                        textInputAction: TextInputAction.next,
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
    var repository = '';
    var instructions = '';
    final values = await showDialog<(String, String?, String?, String?)>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create project'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                onChanged: (value) => name = value,
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
                onChanged: (value) => repository = value,
                decoration: const InputDecoration(
                  labelText: 'Repository (optional)',
                ),
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
            onPressed: () {
              Navigator.pop(
                dialogContext,
                (
                  name.isEmpty ? 'My first project' : name,
                  description.trim(),
                  repository.trim(),
                  instructions.trim(),
                ),
              );
            },
            child: const Text('Create'),
          ),
        ],
      ),
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
        repository: values.$3,
        instructions: values.$4,
      );
      if (!mounted) return;
      setState(() {
        snapshot = snapshot.copyWith(
          projects: [...snapshot.projects, project],
        );
        selectedProjectId = project.id;
        selectedChatId = null;
        isLoading = false;
      });
      _navigateTo(StudioNavigation.project(project.id), replace: true);
      _showSnackBar('Project created. Start your first chat.');
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

  Future<void> _createWorkstream([StudioProject? targetProject]) async {
    final project = targetProject ?? selectedProject;
    if (project == null) return;
    final nameController = TextEditingController();
    final created = await showDialog<bool>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Workstream'),
        content: TextField(
          controller: nameController,
          autofocus: true,
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
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final value = nameController.text.trim();
    nameController.dispose();
    if (created != true || value.isEmpty) return;

    final newWorkstreamId =
        'workstream-${DateTime.now().microsecondsSinceEpoch}';
    final newWorkstream = StudioWorkstream(
      id: newWorkstreamId,
      projectId: project.id,
      name: value,
      lead: _shellContext.viewerDisplayName ?? 'You',
      status: 'active',
      brief: 'Add a brief so collaborators understand the intended outcome.',
      primaryWorkspace: _shellContext.workspaces.isNotEmpty
          ? _shellContext.workspaces.first.name
          : 'Not selected',
      currentCheckpoint: 'Not started',
      queueStatus: 'Idle',
    );

    final updatedProjects = snapshot.projects.map((p) {
      if (p.id == project.id) {
        return StudioProject(
          id: p.id,
          name: p.name,
          repository: p.repository,
          branch: p.branch,
          activeGoals: p.activeGoals,
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
        StudioNavigation.workstream(project.id, newWorkstreamId),
      );
      _showSnackBar('Workstream created.');
    }
  }

  Future<void> _editProject(StudioProject project) async {
    var name = project.name;
    var description = project.description;
    var repository = project.repository;
    var instructions = project.instructions;
    final values = await showDialog<(String, String, String, String)?>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Project settings'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: TextEditingController(text: project.name),
                onChanged: (value) => name = value,
                decoration: const InputDecoration(labelText: 'Project name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: TextEditingController(text: project.description),
                onChanged: (value) => description = value,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: TextEditingController(text: project.repository),
                onChanged: (value) => repository = value,
                decoration:
                    const InputDecoration(labelText: 'Repository (optional)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: TextEditingController(text: project.instructions),
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
              (
                name.trim(),
                description.trim(),
                repository.trim(),
                instructions.trim()
              ),
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
        repository: values.$3,
        instructions: values.$4,
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

  Future<void> _archiveProject(StudioProject project) async {
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
      _navigateTo(const StudioNavigation.projects(), replace: true);
      _showSnackBar('Project archived.');
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _deleteProject(String projectId) async {
    final confirmed = await _confirmProjectAction(
      title: 'Delete project?',
      message: 'This permanently removes the Project and its Chats.',
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
        selectedChatId = null;
      });
      _navigateTo(const StudioNavigation.projects(), replace: true);
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

  Widget _pendingInvitationBanner() => Card(
        color: const Color(0xfff4f1ff),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mail_outline, color: Color(0xff5143b8)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  '${pendingInvitations.length} Workspace invitation${pendingInvitations.length == 1 ? '' : 's'} waiting for your review.',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _content(bool compact) {
    return Column(children: [
      StudioTopBar(
        shellContext: _shellContext,
        onNavigateTo: _navigateTo,
        onOpenCommandPalette: _openCommandPalette,
        onOpenNotifications: _showNotifications,
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
      if (pendingInvitations.isNotEmpty) _pendingInvitationBanner(),
      Expanded(
          child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  compact ? 18 : 34, 26, compact ? 18 : 34, 40),
              child: showRunDetails
                  ? _runDetailsView(compact)
                  : navigation.kind == StudioRouteKind.home
                      ? _homeView()
                      : _chatView(compact))),
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

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  Widget _projectsView() => ProjectsPage(
        projects: snapshot.projects,
        onCreateProject: _createProject,
        onOpenProject: (projectId) =>
            _navigateTo(StudioNavigation.project(projectId)),
        onDeleteProject: _deleteProject,
      );

  Widget _homeView() => HomePage(
        projects: snapshot.projects,
        hosts: snapshot.agents,
        workers: snapshot.workers,
        accounts: snapshot.accounts,
        run: snapshot.run,
        openFindingCount: snapshot.findings
            .where((finding) => finding.status == FindingStatus.open)
            .length,
        usageTokens: store.usage.tokens,
        usageCostMicros: store.usage.costMicros,
        onOpenHosts: () => _navigateTo(const StudioNavigation.hosts()),
        onOpenWorkers: () => _navigateTo(const StudioNavigation.workers()),
        onOpenAccounts: () => _navigateTo(const StudioNavigation.accounts()),
        onOpenUsage: () => _navigateTo(const StudioNavigation.usage()),
        onOpenProject: (projectId) =>
            _navigateTo(StudioNavigation.project(projectId)),
        onOpenChat: (projectId, chatId) =>
            _navigateTo(StudioNavigation.chat(projectId, chatId)),
        onOpenRun: (projectId, runId) =>
            _navigateTo(StudioNavigation.run(projectId, runId)),
        onCreateProject: _createProject,
      );

  Widget _projectOverviewView() {
    final project = selectedProject;
    if (project == null) return _projectsView();
    return ProjectPage(
      project: project,
      dataSource: widget.dataSource,
      onOpenWorkstream: (workstreamId) =>
          _navigateTo(StudioNavigation.workstream(project.id, workstreamId)),
      onEdit: () => _editProject(project),
      onArchive: () => _archiveProject(project),
      onDelete: () => _deleteProject(project.id),
    );
  }

  Widget _workstreamView() {
    final project = selectedProject;
    final workstream = selectedWorkstream;
    if (project == null || workstream == null) return _projectsView();
    return WorkstreamPage(
      project: project,
      workstream: workstream,
      onBackToProject: () =>
          _navigateTo(StudioNavigation.project(project.id)),
      onArchive: () => _showSnackBar('Workstream archived in the v6 shell.'),
      onProvisionCheckout: () async {
        try {
          await widget.dataSource.provisionWorkstreamCheckout(
            workstreamId: workstream.id,
          );
          if (mounted) {
            _showSnackBar('Checkout provisioning requested.');
          }
        } catch (error) {
          if (mounted) _showSnackBar(error.toString());
        }
      },
    );
  }

  Widget _runDetailsView(bool compact) {
    switch (navigation.kind) {
      case StudioRouteKind.hosts:
        return _hostsView();
      case StudioRouteKind.workers:
        return _catalogView();
      case StudioRouteKind.accounts:
        return _accountsView();
      case StudioRouteKind.usage:
        return _usageView();
      case StudioRouteKind.profileSecurity:
        return _profileSecurityView();
      case StudioRouteKind.projects:
        return _projectsView();
      case StudioRouteKind.project:
        return _projectOverviewView();
      case StudioRouteKind.workstream:
        return _workstreamView();
      case StudioRouteKind.run:
      case StudioRouteKind.home:
      case StudioRouteKind.chat:
      case StudioRouteKind.login:
        break;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(
          spacing: 16,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(selectedProject?.name ?? 'Project',
                  style:
                      const TextStyle(color: Color(0xff777683), fontSize: 12)),
              const SizedBox(height: 7),
              const Text('Run details',
                  style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff20202c),
                      letterSpacing: -.5)),
              const SizedBox(height: 5),
              const Text(
                  'Follow execution, results, verification, and diagnostics.',
                  style: TextStyle(color: Color(0xff777683), fontSize: 13))
            ]),
            FilledButton.icon(
                key: const Key('new-work-request-button'),
                onPressed: () => setState(() => showNewGoal = true),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New work request'),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xff6254d9),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 13))),
          ]),
      const SizedBox(height: 20),
      _runSection(
        title: 'Overview',
        subtitle: 'Status, elapsed work, Workers, Account, and usage',
        icon: Icons.dashboard_outlined,
        child: Column(children: [
          _runHeader(compact),
          const SizedBox(height: 16),
          _runContextCard(),
          const SizedBox(height: 16),
          _policyCard(),
        ]),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Execution',
        subtitle: 'Task DAG, progress, and active Worker details',
        icon: Icons.account_tree_outlined,
        child: compact
            ? Column(children: [
                _executionCard(),
                const SizedBox(height: 16),
                _taskDetailsCard(),
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 6, child: _executionCard()),
                const SizedBox(width: 16),
                Expanded(flex: 4, child: _taskDetailsCard()),
              ]),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Results',
        subtitle: 'Candidate answers, synthesis, and artifacts',
        icon: Icons.auto_awesome_outlined,
        child: _resultsDetailsCard(),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Verification',
        subtitle: 'Tests, findings, review, and completion criteria',
        icon: Icons.verified_outlined,
        child: _evidenceCard(),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Technical',
        subtitle: 'Events, model calls, correlation IDs, and diagnostics',
        icon: Icons.code_outlined,
        initiallyExpanded: false,
        child: Column(children: [
          _technicalDetailsCard(),
          const SizedBox(height: 16),
          _timelineCard(),
        ]),
      ),
      if (showNewGoal) _newGoalDialog(),
    ]);
  }

  Widget _runSection({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
    bool initiallyExpanded = true,
  }) =>
      Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: Icon(icon, color: const Color(0xff6254d9)),
          title: Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          children: [child],
        ),
      );

  Future<void> _sendChatMessage([String? submittedText]) async {
    final chat = selectedChat;
    final text = (submittedText ?? chatController.text).trim();
    if (chat == null || text.isEmpty) return;
    chatController.clear();
    final pending = _PendingChatMessage(
      id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
      text: text,
    );
    setState(() {
      pendingChatMessages.add(pending);
      isSendingChat = true;
    });
    try {
      final response = await store.chats.send(chat.projectId, chat.id, text);
      if (!mounted) return;
      setState(() {
        pendingChatMessages.removeWhere((item) => item.id == pending.id);
        isSendingChat = false;
      });
      if (response.runId != null && response.runId!.isNotEmpty) {
        await _loadSnapshot(projectId: chat.projectId, showSpinner: false);
        if (!mounted) return;
        _navigateTo(StudioNavigation.run(chat.projectId, response.runId!));
      } else {
        await _loadSnapshot(projectId: chat.projectId, showSpinner: false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          pending.status = _ChatDeliveryStatus.failed;
          pending.error = error.toString();
          isSendingChat = false;
        });
      }
    }
  }

  Future<void> _retryPendingChat(_PendingChatMessage pending) async {
    if (!mounted) return;
    setState(
        () => pendingChatMessages.removeWhere((item) => item.id == pending.id));
    await _sendChatMessage(pending.text);
  }

  Future<void> _createChat() async {
    final projectId = selectedProjectId;
    if (projectId == null) return;
    var titleValue = '';
    final title = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (context) => AlertDialog(
        title: const Text('New chat'),
        content: TextField(
          autofocus: true,
          onChanged: (value) => titleValue = value,
          decoration: const InputDecoration(
              hintText: 'What would you like to work on?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, titleValue.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    try {
      final chat = await store.chats.create(projectId, title);
      if (!mounted) return;
      setState(() {
        selectedChatId = chat.id;
      });
      await _loadSnapshot(projectId: projectId, showSpinner: false);
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Widget _chatView(bool compact) {
    final chat = selectedChat;
    final messages = [
      ...?chat?.messages,
      ...localChatMessages,
    ];
    if (chat == null) {
      return _panel(
        title: 'Start a conversation',
        subtitle: selectedProject == null
            ? 'Create a project to start working with Conclave AX.'
            : 'Start the first chat for this project.',
        child: FilledButton.icon(
          onPressed: selectedProject == null ? _createProject : _createChat,
          icon: const Icon(Icons.add),
          label: Text(selectedProject == null ? 'Create project' : 'New chat'),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(selectedProject?.name ?? 'Project',
                style: const TextStyle(color: Color(0xff777683), fontSize: 12)),
            const SizedBox(height: 6),
            Text(chat.title,
                style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff20202c))),
            const SizedBox(height: 5),
          const Text(
                'Historical discussion. Create or open a Workstream for execution.',
                style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          ]),
        ),
        OutlinedButton.icon(
          onPressed: _createChat,
          icon: const Icon(Icons.add, size: 17),
          label: const Text('New chat'),
        ),
      ]),
      const SizedBox(height: 22),
      _panel(
        title: 'Conversation',
          subtitle: '${messages.length} messages · discussion only',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...messages.map(_chatMessage),
            if (snapshot.tasks.any((t) => t.status == TaskStatus.running) ||
                snapshot.run?.status == RunStatus.running ||
                snapshot.run?.status == RunStatus.active) ...[
              StreamingTypingIndicator(
                workerName: snapshot.tasks
                    .where((t) => t.status == TaskStatus.running)
                    .firstOrNull
                    ?.assignedWorkerId,
                statusText: 'Executing verification pipeline…',
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 10),
            ...pendingChatMessages.map(_pendingChatMessage),
            PromptComposer(
              controller: chatController,
              onSubmitted: _sendChatMessage,
              selectedQuality: selectedQuality,
              onQualityChanged: (value) =>
                  setState(() => selectedQuality = value),
              selectedWorker: selectedExecutionWorker,
              onWorkerChanged: (value) =>
                  setState(() => selectedExecutionWorker = value),
              selectedModel: selectedExecutionModel,
              onModelChanged: (value) =>
                  setState(() => selectedExecutionModel = value),
              selectedAccount: selectedExecutionAccount,
              onAccountChanged: (value) =>
                  setState(() => selectedExecutionAccount = value),
              selectedHost: selectedExecutionHost,
              onHostChanged: (value) =>
                  setState(() => selectedExecutionHost = value),
              showAdvanced: showAdvancedExecution,
              onToggleAdvanced: () => setState(
                  () => showAdvancedExecution = !showAdvancedExecution),
              snapshot: snapshot,
              isBusy: isSendingChat,
              discussionOnly: true,
            ),
          ],
        ),
      ),
    ]);
  }



  Widget _pendingChatMessage(_PendingChatMessage pending) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 760),
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xff6254d9).withValues(alpha: .12),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: pending.status == _ChatDeliveryStatus.failed
                  ? Colors.redAccent
                  : const Color(0xffc8c2f3),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(pending.text, textAlign: TextAlign.right),
                    const SizedBox(height: 5),
                    Text(
                      pending.status == _ChatDeliveryStatus.failed
                          ? 'Not sent${pending.error == null ? '' : ': ${pending.error}'}'
                          : 'Sending…',
                      style: TextStyle(
                        fontSize: 11,
                        color: pending.status == _ChatDeliveryStatus.failed
                            ? Colors.redAccent
                            : const Color(0xff777683),
                      ),
                    ),
                  ],
                ),
              ),
              if (pending.status == _ChatDeliveryStatus.failed) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _retryPendingChat(pending),
                  child: const Text('Retry'),
                ),
              ] else ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
      );



  Widget _chatMessage(StudioChatMessage message) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isUser = message.sender == StudioMessageSender.user;
    final surfaceColor = isUser
        ? ConclaveBrand.accent
        : (isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface);
    final borderColor = isUser
        ? null
        : (isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine);
    final inkColor = isUser
        ? Colors.white
        : (isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk);
    final mutedInk = isUser
        ? Colors.white.withValues(alpha: 0.7)
        : (isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(13),
          border: borderColor != null ? Border.all(color: borderColor) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MarkdownMessageBody(
            text: message.text,
            textStyle: TextStyle(
              color: inkColor,
              fontSize: 13.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 5),
          Text(message.timestamp,
              style: TextStyle(color: mutedInk, fontSize: 10)),
          if (message.runPreview != null) ...[
            const SizedBox(height: 14),
            _runPreviewCard(message.runPreview!),
          ],
        ]),
      ),
    );
  }

  Widget _runPreviewCard(StudioRunPreview preview) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: const Color(0xffdfdcf7))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.hub_rounded, color: Color(0xff6254d9), size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(preview.statusSummary,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 12))),
            Text('${preview.workerCount} workers',
                style: const TextStyle(color: Color(0xff888691), fontSize: 10)),
          ]),
          const SizedBox(height: 12),
          ...preview.phases.map((phase) => _phaseIndicator(phase)),
          if (preview.finalAnswer != null) ...[
            const Divider(height: 20),
            const Text('Final synthesized answer',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            const SizedBox(height: 6),
            Text(preview.finalAnswer!,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xff575564), fontSize: 12, height: 1.4)),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () {
                final project = selectedProject;
                final run = snapshot.run;
                if (project != null && run != null) {
                  _navigateTo(StudioNavigation.run(project.id, run.id));
                }
              },
              icon: const Icon(Icons.open_in_new, size: 15),
              label: const Text('Open run details'),
            ),
          ),
        ]),
      );

  Widget _phaseIndicator(StudioPhaseItem phase) {
    final (icon, color) = switch (phase.status) {
      StudioPhaseStatus.completed => (
          Icons.check_circle_rounded,
          const Color(0xff43b17f)
        ),
      StudioPhaseStatus.inProgress => (
          Icons.radio_button_checked,
          const Color(0xff6254d9)
        ),
      StudioPhaseStatus.pending => (
          Icons.radio_button_unchecked,
          const Color(0xffaaa8b1)
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(phase.name,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        if (phase.detail != null) ...[
          const SizedBox(width: 8),
          Expanded(
              child: Text(phase.detail!,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Color(0xff96949e), fontSize: 10))),
        ],
      ]),
    );
  }

  Color _runStatusColor(RunStatus status) => switch (status) {
        RunStatus.completed => const Color(0xff43b17f),
        RunStatus.failed || RunStatus.cancelled => const Color(0xffbd6565),
        RunStatus.paused || RunStatus.waiting => const Color(0xffedb84d),
        _ => const Color(0xff6254d9),
      };

  String _statusLabel(RunStatus status) =>
      status.name[0].toUpperCase() + status.name.substring(1);

  Future<void> _controlRun(String command) async {
    final runId = snapshot.run?.id ?? snapshot.activeRunId;
    if (runId == null) return;
    try {
      await store.runs.control(runId, command);
      if (!mounted) return;
      setState(() {
        optimisticRunStatus = switch (command) {
          'pause' => RunStatus.paused,
          'resume' => RunStatus.running,
          'cancel' => RunStatus.cancelled,
          _ => optimisticRunStatus,
        };
      });
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Widget _runHeader(bool compact) {
    final run = snapshot.run;
    final status = optimisticRunStatus ?? run?.status ?? RunStatus.completed;
    final canControl = run != null &&
        {
          RunStatus.active,
          RunStatus.running,
          RunStatus.waiting,
          RunStatus.paused
        }.contains(status);
    final paused = status == RunStatus.paused;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child: Wrap(
                spacing: 18,
                runSpacing: 15,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Icon(Icons.bolt_rounded,
                      color: Color(0xff6254d9), size: 24),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            run?.objective ??
                                'No work request has been started',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text(
                            run == null
                                ? 'Select New work request to begin'
                                : 'Run ${run.id} · Forge',
                            style: const TextStyle(
                                color: Color(0xff898896), fontSize: 11))
                      ]),
                  _statusChip(_statusLabel(status), _runStatusColor(status)),
                  const SizedBox(width: 5),
                  if (!compact)
                    Text(
                        '${run?.verifiedCriterionCount ?? 0} / ${run?.criterionCount ?? 0} criteria verified',
                        style: const TextStyle(
                            color: Color(0xff777683), fontSize: 11)),
                  OutlinedButton.icon(
                      onPressed: canControl
                          ? () => _controlRun(paused ? 'resume' : 'pause')
                          : null,
                      icon: Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 16),
                      label: Text(paused ? 'Resume' : 'Pause'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                  OutlinedButton.icon(
                      onPressed:
                          canControl ? () => _controlRun('cancel') : null,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xffa45555),
                          side: const BorderSide(color: Color(0xffefd5d5)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                ])));
  }

  Widget _executionCard() {
    final run = snapshot.run;
    if (snapshot.tasks.isEmpty) {
      return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(run == null
              ? 'No active run for this project.'
              : 'The run has not created tasks yet.'),
        ),
      );
    }
    final completed = snapshot.tasks
        .where((task) => task.status == TaskStatus.completed)
        .length;
    return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        trailing: _statusChip('$completed / ${snapshot.tasks.length} tasks',
            const Color(0xff6254d9)),
        child: Column(children: [
          TaskPipelineDAG(
            tasks: snapshot.tasks,
            selectedTaskId: selectedTaskId,
            onSelectTask: (taskId) => setState(() => selectedTaskId = taskId),
          ),
          ...snapshot.tasks.map(_taskRow),
        ]));
  }

  Widget _runContextCard() {
    final call = snapshot.modelCalls.firstOrNull;
    final task = selectedTask ?? snapshot.tasks.firstOrNull;
    final worker =
        call?.worker.isNotEmpty == true ? call!.worker : task?.worker ?? 'Auto';
    final model = call?.model.isNotEmpty == true ? call!.model : 'Auto';
    final account = snapshot.accounts
        .where((value) => value.id == call?.account)
        .map((value) => value.displayName)
        .firstOrNull;
    final host = snapshot.agents
        .where((value) => value.id == call?.host)
        .map((value) => value.name)
        .firstOrNull;
    return _panel(
      title: 'Execution context',
      subtitle: 'Trusted assignment details',
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _contextLine(Icons.extension_outlined, 'Worker', worker),
          _contextLine(
              Icons.account_circle_outlined, 'Account', account ?? 'Auto'),
          _contextLine(Icons.computer_outlined, 'Workspace', host ?? 'Auto'),
          _contextLine(Icons.smart_toy_outlined, 'Model', model),
        ],
      ),
    );
  }

  Widget _contextLine(IconData icon, String label, String value) => SizedBox(
        width: 190,
        child: Row(children: [
          Icon(icon, size: 16, color: const Color(0xff9997a3)),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style:
                      const TextStyle(color: Color(0xff9997a3), fontSize: 10)),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      );

  String _qualityLabel(StudioQualityPreset preset) => switch (preset) {
        StudioQualityPreset.highAssurance => 'High Assurance',
        StudioQualityPreset.exploration => 'Exploration',
        StudioQualityPreset.custom => 'Custom',
        StudioQualityPreset.economy => 'Economy',
        StudioQualityPreset.balanced => 'Balanced',
      };

  Widget _policyCard() {
    final policy = snapshot.policy;
    return _panel(
      title: 'Execution policy',
      subtitle: 'Configure worker routing for this run',
      trailing: _statusChip(
        policy?.mode ?? 'parallel',
        const Color(0xff6254d9),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...StudioQualityPreset.values.map(
            (preset) => ChoiceChip(
              label: Text(_qualityLabel(preset)),
              selected: selectedQuality == preset,
              onSelected: (_) => setState(() => selectedQuality = preset),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            policy == null
                ? 'No server policy attached'
                : '${policy.candidateCount} candidates · ${policy.maxParallel} parallel · ${policy.costCeiling}',
            style: const TextStyle(color: Color(0xff777683), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _resultsDetailsCard() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _candidateOutputsCard(),
          const SizedBox(height: 16),
          _panel(
            title: 'Artifacts and changes',
            subtitle: '${snapshot.artifacts.length} stored result artifacts',
            child: snapshot.artifacts.isEmpty
                ? const Text(
                    'Artifacts will appear here as the Run produces results.')
                : Column(
                    children: snapshot.artifacts
                        .map((artifact) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.description_outlined),
                              title: Text(artifact.name),
                              subtitle:
                                  Text('${artifact.type} · ${artifact.size}'),
                              trailing: Text(artifact.source),
                            ))
                        .toList(),
                  ),
          ),
        ],
      );

  Widget _technicalDetailsCard() => _panel(
        title: 'Technical context',
        subtitle: 'Read-only execution diagnostics',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot.modelCalls.isEmpty)
              const Text('Model calls will appear as Workers execute.')
            else
              ...snapshot.modelCalls.map((call) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.smart_toy_outlined),
                    title: Text('${call.worker} · ${call.model}'),
                    subtitle: Text(
                        '${call.task} · ${call.tokens} tokens · ${call.duration}'),
                    trailing: _statusChip(call.status, const Color(0xff6254d9)),
                  )),
            const Divider(),
            Text(
                'Correlation IDs: ${snapshot.events.where((event) => event.correlationId != null).map((event) => event.correlationId).toSet().join(', ')}',
                style: const TextStyle(fontSize: 11, color: Color(0xff777683))),
          ],
        ),
      );

  Widget _candidateOutputsCard() {
    final outputs = snapshot.candidateOutputs;
    final decision = snapshot.synthesisDecision;
    if (outputs.isEmpty && decision == null) {
      return _panel(
        title: 'Candidate outputs',
        subtitle: 'Read-only multi-worker synthesis',
        child: const Text(
            'Candidate outputs will appear when a multi-worker policy runs.'),
      );
    }
    return _panel(
      title: 'Candidate outputs',
      subtitle: '${outputs.length} independent results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...outputs.map(
            (output) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfffafaff),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xffe6e3f8)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.account_tree_outlined,
                      size: 18, color: Color(0xff6254d9)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${output.worker} · ${output.role}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(output.summary,
                            style: const TextStyle(
                                color: Color(0xff777683), fontSize: 11)),
                      ],
                    ),
                  ),
                  _statusChip(output.status, const Color(0xff43b17f)),
                ],
              ),
            ),
          ),
          if (decision != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.auto_awesome,
                  color: Color(0xff6254d9), size: 18),
              const SizedBox(width: 8),
              const Text('Synthesis decision',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              const Spacer(),
              _statusChip(decision.status, const Color(0xff43b17f)),
            ]),
            const SizedBox(height: 6),
            Text(decision.summary,
                style: const TextStyle(color: Color(0xff777683), fontSize: 11)),
            const SizedBox(height: 4),
            Text('${decision.worker} · ${decision.evidence}',
                style: const TextStyle(color: Color(0xff9a98a3), fontSize: 10)),
          ],
        ],
      ),
    );
  }

  Widget _taskRow(StudioTask task, {bool selected = false}) {
    final active = selectedTaskId == task.id;
    final color = task.status == TaskStatus.completed
        ? const Color(0xff43b17f)
        : task.status == TaskStatus.running
            ? const Color(0xff6254d9)
            : const Color(0xffaaa8b2);
    return InkWell(
        onTap: () => setState(() => selectedTaskId = task.id),
        borderRadius: BorderRadius.circular(9),
        child: Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: active ? const Color(0xfff3f1ff) : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color:
                        active ? const Color(0xffdcd7ff) : Colors.transparent)),
            child: Row(children: [
              Icon(
                  task.status == TaskStatus.completed
                      ? Icons.check_circle_rounded
                      : task.status == TaskStatus.running
                          ? Icons.timelapse_rounded
                          : Icons.radio_button_unchecked,
                  size: 17,
                  color: color),
              const SizedBox(width: 9),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(task.title,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${task.worker}  ·  ${task.status.name}',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xff95939e)))
                  ])),
              if (task.status == TaskStatus.running)
                SizedBox(
                    width: 45,
                    child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 5,
                        borderRadius: BorderRadius.circular(4),
                        color: const Color(0xff7467e4),
                        backgroundColor: const Color(0xffe3e0f7))),
              const SizedBox(width: 5),
              const Icon(Icons.chevron_right_rounded,
                  size: 17, color: Color(0xffb5b3bd))
            ])));
  }

  Widget _taskDetailsCard() {
    final task = selectedTask ?? snapshot.tasks.firstOrNull;
    if (task == null) {
      return _panel(
        title: 'Task details',
        subtitle: 'No task selected',
        child: const Text('Tasks will appear here when a run begins.'),
      );
    }
    return _panel(
        title: 'Task details',
        subtitle: task.id.toUpperCase(),
        trailing: _statusChip(
            task.status.name,
            task.status == TaskStatus.running
                ? const Color(0xff6254d9)
                : const Color(0xff43b17f)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(task.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 8),
          Text(task.detail,
              style: const TextStyle(
                  color: Color(0xff777683), fontSize: 12, height: 1.45)),
          const SizedBox(height: 18),
          _detailLine(Icons.person_outline, 'Worker', task.worker),
          _detailLine(
              Icons.account_tree_outlined,
              'Dependencies',
              task.dependencies.isEmpty
                  ? 'None'
                  : task.dependencies.join(', ')),
          _detailLine(Icons.token_outlined, 'Usage',
              '${task.tokens} tokens  ·  ${task.cost}'),
          if (task.detail.contains('diff') ||
              task.detail.contains('@@') ||
              task.detail.startsWith('---') ||
              task.detail.startsWith('+++')) ...[
            const SizedBox(height: 16),
            const Text('Generated Artifact / Diff',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 8),
            DiffViewer(filePath: task.title, diffContent: task.detail),
          ],
          const SizedBox(height: 15),
          if (task.status == TaskStatus.running)
            FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry task'),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffefedf9),
                    foregroundColor: const Color(0xff5549be),
                    elevation: 0))
        ]));
  }

  Widget _detailLine(IconData icon, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: const Color(0xff9997a3)),
        const SizedBox(width: 9),
        SizedBox(
            width: 82,
            child: Text(label,
                style:
                    const TextStyle(color: Color(0xff9997a3), fontSize: 11))),
        Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Color(0xff454450),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)))
      ]));

  Widget _timelineCard() => _panel(
        title: 'Run timeline',
        subtitle: 'Ordered events',
        trailing: TextButton(
            onPressed: _copyRunDiagnostics,
            child: const Text('Export diagnostics')),
        child: Column(
          children: snapshot.events
              .map(
                (event) => Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 42,
                          child: Text(event.time,
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xffaaa8b1)))),
                      Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 3, right: 11),
                          decoration: const BoxDecoration(
                              color: Color(0xff786be4),
                              shape: BoxShape.circle)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(event.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12)),
                            const SizedBox(height: 3),
                            Text(event.detail,
                                style: const TextStyle(
                                    color: Color(0xff898792), fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );

  Widget _evidenceCard() => _panel(
      title: 'Evidence & findings',
      subtitle:
          '${snapshot.findings.length} findings · ${snapshot.artifacts.length} artifacts',
      trailing: TextButton(
          onPressed: () {
            final project = selectedProject;
            final run = snapshot.run;
            if (project != null && run != null) {
              _navigateTo(StudioNavigation.run(project.id, run.id));
            }
          },
          child: const Text('Open run details')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _metric('Tokens', _formatNumber(snapshot.run?.tokens ?? 0)),
          _metric('Cost', _formatCost(snapshot.run?.costMicros ?? 0)),
          _metric('Checks',
              '${snapshot.run?.verifiedCriterionCount ?? 0} / ${snapshot.run?.criterionCount ?? 0}')
        ]),
        const SizedBox(height: 16),
        ...snapshot.findings.map((finding) => _findingRow(finding))
      ]));

  Widget _metric(String label, String value) => Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface))
      ]));

  Widget _usageMetric(String label, String value) => SizedBox(
        width: 150,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 10)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface)),
        ]),
      );

  String _formatNumber(int value) => value == 0
      ? '0'
      : '${(value / 1000).toStringAsFixed(value >= 10000 ? 1 : 2)}k';

  String _formatCost(int micros) =>
      '\$${(micros / 1000000).toStringAsFixed(2)}';

  Widget _findingRow(StudioFinding finding) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outline)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            finding.status == FindingStatus.verified
                ? Icons.verified_rounded
                : Icons.warning_amber_rounded,
            size: 17,
            color: finding.status == FindingStatus.verified
                ? ConclaveBrand.success
                : ConclaveBrand.warning),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(finding.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
          const SizedBox(height: 3),
          Text('${finding.severity.name} · ${finding.status.name}',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 10))
        ]))
      ]));

  Widget _panel(
          {required String title,
          required String subtitle,
          required Widget child,
          Widget? trailing}) =>
      Builder(
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final mutedColor =
              isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted;
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 14)),
                            const SizedBox(height: 3),
                            Text(subtitle,
                                style:
                                    TextStyle(color: mutedColor, fontSize: 10)),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (trailing != null) trailing,
                    ],
                  ),
                  const SizedBox(height: 15),
                  child,
                ],
              ),
            ),
          );
        },
      );

  Widget _statusChip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w700))
      ]));

  Widget _fleetHeader(String title, String subtitle, IconData icon) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 13),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(
                header: true,
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 25, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 5),
              Text(subtitle,
                  style:
                      const TextStyle(color: Color(0xff777683), fontSize: 13)),
            ]),
          ),
        ],
      );

  Future<void> _setWorkerAvailability(
      StudioPlugin plugin, StudioAgent host, bool enabled) async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    try {
      await store.workers.setEnabled(
        workspaceId,
        plugin.id,
        enabled,
        hostId: host.id,
      );
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
      if (mounted) {
        _showSnackBar(enabled
            ? '${plugin.name} is now available on ${host.name}.'
            : '${plugin.name} was removed from ${host.name}.');
      }
    } catch (error) {
      if (mounted) _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _showWorkerDetails(StudioPlugin plugin) async {
    await showDialog<void>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: Text(plugin.name),
        content: SingleChildScrollView(
          child: Text([
            if (plugin.description.isNotEmpty) plugin.description,
            'Version: ${plugin.version}',
            'Publisher: ${plugin.publisher.isEmpty ? 'Unknown' : plugin.publisher}',
            'Capabilities: ${plugin.capabilities.isEmpty ? 'None listed' : plugin.capabilities.join(', ')}',
            'Roles: ${plugin.roles.isEmpty ? 'None listed' : plugin.roles.join(', ')}',
            'Requirements: ${plugin.permissions.isEmpty ? 'No special permissions' : plugin.permissions.join(', ')}',
            'Platforms: ${[
              ...plugin.supportedOS,
              ...plugin.supportedArchitecture
            ].isEmpty ? 'Any compatible Workspace' : [
                ...plugin.supportedOS,
                ...plugin.supportedArchitecture
              ].join(', ')}',
          ].join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  bool _workerDesiredOn(StudioPlugin plugin, StudioAgent host) =>
      host.desiredWorkers.any((worker) => worker.workerId == plugin.id);

  bool _workerInstalledOn(StudioPlugin plugin, StudioAgent host) =>
      host.installedWorkers.any((worker) =>
          worker.workerId == plugin.id &&
          worker.status.toLowerCase() != 'failed');

  Widget _workerHostRow(StudioPlugin plugin, StudioAgent host) {
    final desired = _workerDesiredOn(plugin, host);
    final installed = _workerInstalledOn(plugin, host);
    final state = !desired
        ? 'Not installed'
        : installed
            ? 'Installed'
            : 'Installing';
    final stateColor = !desired
        ? const Color(0xff777683)
        : installed
            ? const Color(0xff3ca879)
            : const Color(0xffc1842d);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check_circle_outline : Icons.circle_outlined,
            size: 18,
            color: stateColor,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(host.name)),
          Text(state, style: TextStyle(color: stateColor)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _setWorkerAvailability(plugin, host, !desired),
            child: Text(desired ? 'Remove from Workspace' : 'Make available'),
          ),
          if (desired)
            IconButton(
              tooltip: 'Update Worker',
              onPressed: () => _setWorkerAvailability(plugin, host, true),
              icon: const Icon(Icons.system_update_outlined, size: 19),
            ),
        ],
      ),
    );
  }

  Widget _hostsView() => WorkspacesPage(
        workspaces: snapshot.agents,
        workers: snapshot.workers,
        accounts: snapshot.accounts,
        onAdd: _enrollAgent,
        onRename: _renameHost,
        onUpdate: _announceAgentUpdate,
        onRevoke: (workspace) => _revokeAgent(workspace.id),
        onGrant: _bindHost,
      );



  Widget _catalogView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fleetHeader(
              'Workers',
              'Capabilities available to your paired Workspaces.',
              Icons.extension_outlined),
          const SizedBox(height: 24),
          if (snapshot.plugins.isEmpty)
            _emptyFleetCard('No Workers available',
                'Workers appear when the catalog has a compatible release.')
          else
            ...snapshot.plugins.map((plugin) {
              final readyHosts = snapshot.agents
                  .where((host) => _workerInstalledOn(plugin, host))
                  .length;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const CircleAvatar(
                            backgroundColor: Color(0xffeeecff),
                            child: Icon(Icons.extension_outlined,
                                color: Color(0xff6254d9)),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 220,
                            child: Text(plugin.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16)),
                          ),
                          Text('Ready on $readyHosts Workspaces',
                              style: const TextStyle(color: Color(0xff777683))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                          '${plugin.version} · ${plugin.publisher.isEmpty ? 'Unknown publisher' : plugin.publisher} · ${plugin.capabilities.join(' · ')}'),
                      const SizedBox(height: 6),
                      Text(plugin.permissions.isEmpty
                          ? 'No special permissions'
                          : 'Requirements: ${plugin.permissions.join(', ')}'),
                      if (snapshot.agents.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ...snapshot.agents
                            .map((host) => _workerHostRow(plugin, host)),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _showWorkerDetails(plugin),
                            icon: const Icon(Icons.info_outline, size: 18),
                            label: const Text('View capabilities'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _showWorkerDetails(plugin),
                            icon: const Icon(Icons.rule_outlined, size: 18),
                            label: const Text('View requirements'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                _navigateTo(const StudioNavigation.accounts()),
                            icon: const Icon(Icons.account_circle_outlined,
                                size: 18),
                            label: const Text('Connect Account'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      );

  Widget _emptyFleetCard(String title, String subtitle) => _panel(
        title: title,
        subtitle: subtitle,
        child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Text('Nothing to configure yet.',
                style: TextStyle(color: Color(0xff777683)))),
      );

  Future<void> _createCredentialProfile() async {
    final workspaceId = executionWorkspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    if (snapshot.plugins.isEmpty) {
      _showSnackBar('Add a Worker before creating an AI Account.',
          type: ToastType.error);
      return;
    }

    final nameController = TextEditingController();
    var workerId = snapshot.plugins.first.id;
    var hostId = snapshot.agents.firstOrNull?.id;
    var authType = snapshot.agents.isEmpty ? 'none' : 'oauth_browser';
    var ownerType = 'user';
    var sharingPolicy = 'private_only';
    final values = await showDialog<Map<String, dynamic>>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final needsHost = authType != 'none';
          return AlertDialog(
            title: const Text('Add AI Account'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                        'Connect an AI identity to a Worker. Secrets stay on the selected Workspace.'),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Account name',
                        hintText: 'My Codex',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: workerId,
                      decoration: const InputDecoration(labelText: 'Worker'),
                      items: snapshot.plugins
                          .map((worker) => DropdownMenuItem(
                                value: worker.id,
                                child: Text(worker.name),
                              ))
                          .toList(),
                      onChanged: (value) =>
                          setDialogState(() => workerId = value ?? workerId),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: authType,
                      decoration:
                          const InputDecoration(labelText: 'Authentication'),
                      items: const [
                        DropdownMenuItem(
                            value: 'oauth_browser',
                            child: Text('Browser OAuth')),
                        DropdownMenuItem(
                            value: 'api_key',
                            child: Text('API key on Workspace')),
                        DropdownMenuItem(
                            value: 'local_cli_session',
                            child: Text('CLI login on Workspace')),
                        DropdownMenuItem(
                            value: 'none', child: Text('No authentication')),
                      ],
                      onChanged: (value) => setDialogState(() {
                        authType = value ?? authType;
                        if (authType == 'none') hostId = null;
                        if (authType != 'none' &&
                            hostId == null &&
                            snapshot.agents.isNotEmpty) {
                          hostId = snapshot.agents.first.id;
                        }
                      }),
                    ),
                    if (needsHost) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: hostId,
                        decoration: const InputDecoration(
                            labelText: 'Workspace storage'),
                        items: snapshot.agents
                            .map((host) => DropdownMenuItem(
                                  value: host.id,
                                  child: Text(host.name),
                                ))
                            .toList(),
                        onChanged: (value) =>
                            setDialogState(() => hostId = value),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                          'The Workspace will show the local authentication action. Conclave AX never receives the secret.',
                          style: TextStyle(
                              color: Color(0xff777683), fontSize: 12)),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: ownerType,
                      decoration: const InputDecoration(labelText: 'Owner'),
                      items: const [
                        DropdownMenuItem(
                            value: 'user', child: Text('Personal account')),
                        DropdownMenuItem(
                            value: 'workspace',
                            child: Text('Workspace account')),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => ownerType = value ?? ownerType),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: sharingPolicy,
                      decoration: const InputDecoration(labelText: 'Sharing'),
                      items: const [
                        DropdownMenuItem(
                            value: 'private_only', child: Text('Private')),
                        DropdownMenuItem(
                            value: 'owner_controlled',
                            child: Text('Selected users')),
                        DropdownMenuItem(
                            value: 'workspace_capable',
                            child: Text('Workspace')),
                      ],
                      onChanged: (value) => setDialogState(
                          () => sharingPolicy = value ?? sharingPolicy),
                    ),
                    if (sharingPolicy == 'owner_controlled') ...[
                      const SizedBox(height: 6),
                      const Text(
                          'You can add individual users after creation. They can use the Account but never read its secret.',
                          style: TextStyle(
                              color: Color(0xff777683), fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, {
                  'displayName': nameController.text.trim(),
                  'workerId': workerId,
                  'hostId': hostId,
                  'authType': authType,
                  'ownerType': ownerType,
                  'sharingPolicy': sharingPolicy,
                }),
                child: const Text('Create Account'),
              ),
            ],
          );
        },
      ),
    );
    nameController.dispose();
    if (values == null) return;
    final displayName = values['displayName'] as String? ?? '';
    if (displayName.isEmpty) {
      _showSnackBar('Enter an Account name.', type: ToastType.error);
      return;
    }
    final selectedAuthType = values['authType'] as String;
    final selectedHostId = values['hostId'] as String?;
    if (selectedAuthType != 'none' && selectedHostId == null) {
      _showSnackBar('Choose a Workspace for local authentication.',
          type: ToastType.error);
      return;
    }
    setState(() => workerActionMessage = 'Creating Account…');
    try {
      final account = await widget.dataSource.createCredentialProfile(
        workspaceId: workspaceId,
        displayName: displayName,
        workerId: values['workerId'] as String,
        authType: selectedAuthType,
        ownerType: values['ownerType'] as String,
        sharingPolicy: values['sharingPolicy'] as String,
        hostId: selectedHostId,
      );
      if (selectedHostId != null && selectedAuthType != 'none') {
        await widget.dataSource.requestCredentialSetup(
          workspaceId: workspaceId,
          profileId: account.id,
          action: 'setup',
        );
      }
      await _loadSnapshot(workspaceId: workspaceId, showSpinner: false);
      if (mounted) {
        setState(() => workerActionMessage = null);
        _showSnackBar(selectedHostId == null
            ? 'AI Account created.'
            : 'AI Account created. Complete setup on the Workspace.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => workerActionMessage = null);
        _showSnackBar(error.toString(), type: ToastType.error);
      }
    }
  }

  Widget _accountsView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fleetHeader(
              'AI Accounts',
              'Accounts used by Workers on your Workspaces.',
              Icons.account_circle_outlined),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _createCredentialProfile,
              icon: const Icon(Icons.add),
              label: const Text('Add AI Account'),
            ),
          ),
          const SizedBox(height: 20),
          if (workerActionMessage != null) ...[
            MaterialBanner(
              content: Text(workerActionMessage!),
              leading: const Icon(Icons.info_outline),
              actions: [
                TextButton(
                  onPressed: () => setState(() => workerActionMessage = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (snapshot.accounts.isEmpty)
            _emptyFleetCard('No Accounts connected',
                'Connect an Account to make a Worker ready for execution.')
          else ...[
            const Text('Accounts',
                style: TextStyle(color: Color(0xff777683), fontSize: 13)),
            const SizedBox(height: 24),
            ...snapshot.accounts.map(
              (account) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xffeeecff),
                    child: Icon(Icons.account_circle_outlined,
                        color: Color(0xff6254d9), size: 20),
                  ),
                  title: Text(account.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      'Owner: ${account.owner}\nWorker: ${account.worker} · Workspace: ${account.host}\nStorage: ${account.storageLocation} · Sharing: ${account.sharing}\nLast used: ${account.lastUsed} · Usage: ${account.usage}'),
                  isThreeLine: true,
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Account actions',
                    onSelected: (action) {
                      if (action == 'setup') {
                        _requestCredentialSetup(account);
                      } else if (action == 'revoke') {
                        _revokeCredentialProfile(account);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'setup',
                        child: Text(account.status.toLowerCase() == 'ready'
                            ? 'Reconnect / re-authenticate'
                            : 'Connect Account'),
                      ),
                      const PopupMenuItem(
                        value: 'revoke',
                        child: Text('Revoke Account'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      );

  Widget _usageView() {
    final report = snapshot.usageReport;
    final rows = report.rows.where((row) {
      final inRange = usageCustomRange == null ||
          (() {
            final date = DateTime.tryParse(row.recordedAt);
            return date == null ||
                (!date.isBefore(usageCustomRange!.start) &&
                    !date.isAfter(usageCustomRange!.end));
          })();
      return inRange &&
          (usageProjectFilter == 'all' ||
              row.projectName == usageProjectFilter) &&
          (usageUserFilter == 'all' || row.requesterName == usageUserFilter) &&
          (usageAccountFilter == 'all' ||
              row.accountName == usageAccountFilter) &&
          (usageWorkerFilter == 'all' || row.workerName == usageWorkerFilter) &&
          (usageProviderFilter == 'all' ||
              row.provider == usageProviderFilter) &&
          (usageModelFilter == 'all' || row.model == usageModelFilter);
    }).toList();
    final tokens = rows.fold<int>(0, (sum, row) => sum + row.tokens);
    final duration = rows.fold<int>(0, (sum, row) => sum + row.durationMs);
    final apiCost = rows
        .where((row) => row.billingCategory == 'api' && row.costMicros != null)
        .fold<int>(0, (sum, row) => sum + row.costMicros!);
    final subscriptionUses =
        rows.where((row) => row.billingCategory == 'subscription').length;
    final runIds =
        rows.map((row) => row.runId).where((id) => id.isNotEmpty).toSet();
    List<String> options(String Function(StudioUsageRow) selector) => [
          'all',
          ...rows.map(selector).where((value) => value.isNotEmpty).toSet()
        ];
    Widget filter(String label, String value, List<String> values,
            ValueChanged<String?> onChanged) =>
        SizedBox(
          width: 150,
          child: DropdownButtonFormField<String>(
            initialValue: values.contains(value) ? value : 'all',
            decoration: InputDecoration(labelText: label, isDense: true),
            items: values
                .map((item) => DropdownMenuItem(
                    value: item, child: Text(item == 'all' ? 'All' : item)))
                .toList(),
            onChanged: onChanged,
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        header: true,
        child: const Text('Usage',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(height: 6),
      const Text(
          'Workspace usage across Projects, Accounts, Workers and people.',
          style: TextStyle(color: Color(0xff777683), fontSize: 13)),
      const SizedBox(height: 20),
      Wrap(spacing: 12, runSpacing: 12, children: [
        filter('Period', usageRange, const ['7d', '30d', 'custom'],
            (value) async {
          if (value == null) return;
          if (value == 'custom') {
            final range = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime.now(),
                initialDateRange: usageCustomRange);
            if (range == null) return;
            setState(() {
              usageRange = value;
              usageCustomRange = range;
            });
          } else {
            setState(() {
              usageRange = value;
              usageCustomRange = null;
            });
          }
        }),
        filter('Project', usageProjectFilter, options((row) => row.projectName),
            (value) => setState(() => usageProjectFilter = value ?? 'all')),
        filter('User', usageUserFilter, options((row) => row.requesterName),
            (value) => setState(() => usageUserFilter = value ?? 'all')),
        filter(
            'AI Account',
            usageAccountFilter,
            options((row) => row.accountName),
            (value) => setState(() => usageAccountFilter = value ?? 'all')),
        filter('Worker', usageWorkerFilter, options((row) => row.workerName),
            (value) => setState(() => usageWorkerFilter = value ?? 'all')),
        filter('Provider', usageProviderFilter, options((row) => row.provider),
            (value) => setState(() => usageProviderFilter = value ?? 'all')),
        filter('Model', usageModelFilter, options((row) => row.model),
            (value) => setState(() => usageModelFilter = value ?? 'all')),
      ]),
      const SizedBox(height: 20),
      Wrap(spacing: 12, runSpacing: 12, children: [
        _usageMetric('Tokens', _formatNumber(tokens)),
        _usageMetric('Known API cost', _formatCost(apiCost)),
        _usageMetric('Subscription usage', '$subscriptionUses uses'),
        _usageMetric('Runs', '${runIds.length}'),
        _usageMetric('Duration', '${(duration / 1000).round()} s'),
      ]),
      const SizedBox(height: 20),
      _panel(
        title: 'Usage details',
        subtitle: 'Subscription usage has no invented monetary cost.',
        child: rows.isEmpty
            ? const Text('No usage matches these filters.')
            : Column(
                children: rows
                    .take(100)
                    .map((row) => ListTile(
                          dense: true,
                          title: Text('${row.workerName} · ${row.model}'),
                          subtitle: Text(
                              '${row.projectName} · Requester: ${row.requesterName} · Account owner: ${row.accountOwnerName}'),
                          trailing: Text(row.billingCategory == 'subscription'
                              ? 'Subscription · ${_formatNumber(row.tokens)} tokens'
                              : '${_formatCost(row.costMicros ?? 0)} · ${_formatNumber(row.tokens)} tokens'),
                        ))
                    .toList()),
      ),
    ]);
  }

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

  Widget _newGoalDialog() => Card(
        margin: const EdgeInsets.only(top: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 510),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Create a Work Request',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Start a new run in the selected project.',
                    style: TextStyle(color: Color(0xff777683), fontSize: 12)),
                const SizedBox(height: 18),
                TextField(
                    controller: objectiveController,
                    decoration: const InputDecoration(
                        labelText: 'What should Conclave accomplish?',
                        hintText: 'Describe the outcome, not just the task',
                        border: OutlineInputBorder())),
                const SizedBox(height: 14),
                TextField(
                    controller: revisionController,
                    decoration: const InputDecoration(
                        labelText: 'Expected commit SHA',
                        hintText: 'The commit CI must verify',
                        border: OutlineInputBorder())),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => setState(() => showNewGoal = false),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                        onPressed: _createGoal,
                        child: const Text('Create work request')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}

class _RecoveryPanel extends StatelessWidget {
  const _RecoveryPanel({
    required this.icon,
    required this.title,
    required this.happened,
    required this.safe,
    required this.nextStep,
    required this.retrying,
    required this.onRetry,
  });

  final IconData icon;
  final String title;
  final String happened;
  final String safe;
  final String nextStep;
  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 42, color: colors.error),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 18),
              _RecoveryLine(label: 'What happened', value: happened),
              const SizedBox(height: 10),
              _RecoveryLine(label: 'Is my work safe?', value: safe),
              const SizedBox(height: 10),
              _RecoveryLine(label: 'What can I do?', value: nextStep),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: retrying ? null : onRetry,
                icon: retrying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(retrying ? 'Retrying…' : 'Try again'),
              ),
              const SizedBox(height: 8),
              Text(
                retrying
                    ? 'Conclave AX is retrying automatically.'
                    : 'If an active run exists, Conclave AX will keep checking for updates.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecoveryLine extends StatelessWidget {
  const _RecoveryLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(value),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

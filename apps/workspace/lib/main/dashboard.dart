part of '../main.dart';

class WorkspaceDashboard extends StatefulWidget {
  const WorkspaceDashboard({
    required this.snapshot,
    this.onSignIn,
    this.onSignOut,
    this.onStartService,
    this.onRegisterService,
    this.onUnregisterService,
    this.onRestartService,
    this.onRegister,
    this.onRecoverCredential,
    this.onConnectCloud,
    this.onDisconnectCloud,
    this.onChangeWorkspaceName,
    this.onStopService,
    this.onRelease,
    this.onReset,
    this.onAccountAction,
    this.requireStepUp,
    this.onQuit,
    this.onRetry,
    this.onCheckForUpdates,
    this.onChangeWorkRoot,
    this.onReadinessCheck,
    this.workerRevision = 0,
    this.credentialStore = const PlatformSecureCredentialStore(),
    this.workerCatalogCoordinator,
    this.onConfigureWorker,
    this.onSetWorkerEnabled,
    this.signedIn = false,
    super.key,
  });

  final WorkspaceUiSnapshot snapshot;
  final Future<void> Function()? onSignIn;
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onStartService;
  final Future<void> Function()? onRegisterService;
  final Future<void> Function()? onUnregisterService;
  final Future<void> Function()? onRestartService;
  final Future<void> Function([String? name])? onRegister;
  final Future<void> Function([String? name])? onRecoverCredential;
  final Future<void> Function()? onConnectCloud;
  final Future<void> Function()? onDisconnectCloud;
  final Future<void> Function(String name)? onChangeWorkspaceName;
  final Future<void> Function()? onStopService;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final VoidCallback? onAccountAction;
  final Future<bool> Function(String reason)? requireStepUp;
  final VoidCallback? onQuit;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onCheckForUpdates;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;
  final int workerRevision;
  final SecureCredentialStore credentialStore;
  final WorkspaceWorkerCatalogClient? workerCatalogCoordinator;
  final Future<void> Function(WorkerDescriptor worker)? onConfigureWorker;
  final Future<void> Function(String workerId, bool enabled)?
      onSetWorkerEnabled;
  final bool signedIn;

  @override
  State<WorkspaceDashboard> createState() => _WorkspaceDashboardState();
}

class _WorkspaceDashboardState extends State<WorkspaceDashboard> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = widget.snapshot;
    final effectiveSignedIn = widget.signedIn ||
        _hasValidCachedDesktopSession(widget.credentialStore);
    final userEmail = effectiveSignedIn
        ? _readUserEmailFromCredentialStore(widget.credentialStore)
        : null;

    final isConnected = snapshot.cloudConnected;
    final serviceHealthy = snapshot.serviceHealthy || snapshot.serviceRunning;
    final serviceNotRegistered = snapshot.serviceInfo.registration ==
            WorkspaceBackgroundServiceRegistration.notRegistered ||
        snapshot.serviceInfo.registration ==
            WorkspaceBackgroundServiceRegistration.serviceMissing;
    final transportLabel = switch (snapshot.activeTransportMode) {
      'websocket' => 'WebSocket',
      'http_long_poll' => 'HTTPS fallback',
      _ => null,
    };
    final connectionLabel = serviceNotRegistered
        ? 'Service not registered'
        : serviceHealthy
            ? (isConnected
                ? 'Service running · Cloud connected${transportLabel == null ? '' : ' · $transportLabel'}'
                : 'Service running · Cloud disconnected')
            : 'Service ${snapshot.serviceStatusDescription.toLowerCase()}';

    return Column(
      children: [
        // App Header Bar
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    ConclaveBrand.logoMark(size: 26),
                    const SizedBox(width: 12),
                    Text(
                      'Conclave Workspace',
                      style: ConclaveTypography.wordmark.copyWith(fontSize: 14),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'v${snapshot.appVersion}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: serviceHealthy
                            ? ConclaveBrand.success
                            : ConclaveBrand.warning,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        connectionLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isConnected
                              ? (theme.brightness == Brightness.dark
                                  ? const Color(0xff86efac)
                                  : const Color(0xff15803d))
                              : (theme.brightness == Brightness.dark
                                  ? const Color(0xfffcd34d)
                                  : const Color(0xffb45309)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (userEmail != null && userEmail.isNotEmpty) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    userEmail,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              PopupMenuButton<_HeaderMenuAction>(
                icon: const Icon(Icons.menu, size: 20),
                tooltip: 'Menu',
                constraints: const BoxConstraints(minWidth: 200),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                onSelected: (action) {
                  switch (action) {
                    case _HeaderMenuAction.openConclaveAX:
                      WorkspaceLifecycleController.openAX();
                      break;
                    case _HeaderMenuAction.checkForUpdates:
                      widget.onCheckForUpdates?.call();
                      break;
                    case _HeaderMenuAction.about:
                      showAboutDialog(
                        context: context,
                        applicationName: 'Conclave Workspace',
                        applicationVersion: 'v${snapshot.appVersion}',
                        applicationIcon: ConclaveBrand.logoMark(size: 40),
                        children: const [
                          Text(
                            'Conclave Workspace Runtime and Local Worker Manager.',
                          ),
                        ],
                      );
                      break;
                    case _HeaderMenuAction.signOut:
                      widget.onSignOut?.call();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _HeaderMenuAction.openConclaveAX,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.open_in_new, size: 16),
                        SizedBox(width: 10),
                        Text('Open Conclave AX'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _HeaderMenuAction.checkForUpdates,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.system_update_alt, size: 16),
                        SizedBox(width: 10),
                        Text('Check for Updates'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _HeaderMenuAction.about,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline, size: 16),
                        SizedBox(width: 10),
                        Text('About'),
                      ],
                    ),
                  ),
                  if (effectiveSignedIn && widget.onSignOut != null) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _HeaderMenuAction.signOut,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.logout, size: 16),
                          SizedBox(width: 10),
                          Text('Sign out'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        // Content Area
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 24, 24, 0),
                      child: Text(
                        'Workspace',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _WorkspaceTab(
                      snapshot: snapshot,
                      signedIn: effectiveSignedIn,
                      credentialStore: widget.credentialStore,
                      onStartService: widget.onStartService,
                      onRegisterService: widget.onRegisterService,
                      onUnregisterService: widget.onUnregisterService,
                      onRestartService: widget.onRestartService,
                      onRegister: widget.onRegister,
                      onRecoverCredential: widget.onRecoverCredential,
                      onChangeWorkspaceName: widget.onChangeWorkspaceName,
                      onRetry: widget.onRetry,
                      onConnectCloud: widget.onConnectCloud,
                      onDisconnectCloud: widget.onDisconnectCloud,
                      onChangeWorkRoot: widget.onChangeWorkRoot,
                      onStopService: widget.onStopService,
                      onRelease: widget.onRelease,
                      onReset: widget.onReset,
                    ),
                    if (snapshot.workspaceReady || effectiveSignedIn) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Workers',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Refresh Worker catalog',
                              onPressed: snapshot.serviceHealthy ||
                                      snapshot.serviceRunning
                                  ? () => unawaited(
                                        widget.workerCatalogCoordinator
                                            ?.refresh(force: true),
                                      )
                                  : null,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                      ),
                      _WorkersTab(
                        key: ValueKey(widget.workerRevision),
                        catalogCoordinator: widget.workerCatalogCoordinator,
                        serviceAvailable:
                            snapshot.serviceHealthy || snapshot.serviceRunning,
                        isSelected: true,
                        onReadinessCheck: widget.onReadinessCheck,
                        onConfigureWorker: widget.onConfigureWorker,
                        onSetWorkerEnabled: widget.onSetWorkerEnabled,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WorkspaceTab extends StatefulWidget {
  const _WorkspaceTab({
    required this.snapshot,
    this.signedIn = false,
    this.onStartService,
    this.onRegisterService,
    this.onUnregisterService,
    this.onRestartService,
    this.onRegister,
    this.onRecoverCredential,
    this.onConnectCloud,
    this.onDisconnectCloud,
    this.onChangeWorkspaceName,
    required this.credentialStore,
    this.onRetry,
    this.onChangeWorkRoot,
    this.onStopService,
    this.onRelease,
    this.onReset,
  });

  final WorkspaceUiSnapshot snapshot;
  final bool signedIn;
  final Future<void> Function()? onStartService;
  final Future<void> Function()? onRegisterService;
  final Future<void> Function()? onUnregisterService;
  final Future<void> Function()? onRestartService;
  final Future<void> Function([String? name])? onRegister;
  final Future<void> Function([String? name])? onRecoverCredential;
  final Future<void> Function()? onConnectCloud;
  final Future<void> Function()? onDisconnectCloud;
  final Future<void> Function(String name)? onChangeWorkspaceName;
  final SecureCredentialStore credentialStore;
  final Future<void> Function()? onRetry;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final Future<void> Function()? onStopService;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;

  @override
  State<_WorkspaceTab> createState() => _WorkspaceTabState();
}

class _WorkspaceTabState extends State<_WorkspaceTab> {
  bool _serviceActionPending = false;
  late final TextEditingController _nameController;
  late final TextEditingController _workRootController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.snapshot.workspaceName ??
          widget.snapshot.hostname ??
          'Conclave Workspace',
    );
    _workRootController = TextEditingController(
      text: _displayWorkRoot(widget.snapshot.workRootPath),
    );
  }

  @override
  void didUpdateWidget(covariant _WorkspaceTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldName = oldWidget.snapshot.workspaceName ??
        oldWidget.snapshot.hostname ??
        'Conclave Workspace';
    final newName = widget.snapshot.workspaceName ??
        widget.snapshot.hostname ??
        'Conclave Workspace';
    // Do not overwrite an in-progress edit when the parent rebuilds after
    // onChanged. The controller already contains the latest user text in
    // that case; assigning it again resets the selection and makes the next
    // Backspace act on the whole field.
    if (oldName != newName && _nameController.text == oldName) {
      _nameController.value = TextEditingValue(
        text: newName,
        selection: TextSelection.collapsed(offset: newName.length),
      );
    }
    if (oldWidget.snapshot.workRootPath != widget.snapshot.workRootPath) {
      _workRootController.text = _displayWorkRoot(widget.snapshot.workRootPath);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _workRootController.dispose();
    super.dispose();
  }

  Future<void> _browseWorkRoot() async {
    final selected = await WorkspaceLifecycleController.chooseDirectory(
      initialPath: widget.snapshot.workRootPath,
    );
    if (selected != null && selected.isNotEmpty) {
      if (widget.onChangeWorkRoot != null) {
        await widget.onChangeWorkRoot!(selected);
      }
    }
  }

  Future<void> _runServiceAction(Future<void> Function() action) async {
    if (_serviceActionPending) return;
    setState(() => _serviceActionPending = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _serviceActionPending = false);
    }
  }

  String _displayWorkRoot(String? path) {
    if (path == null || path.isEmpty) return '';
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && path == home) return '~';
    final separator = Platform.pathSeparator;
    if (home != null && home.isNotEmpty && path.startsWith('$home$separator')) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveSignedIn = widget.signedIn ||
        _hasValidCachedDesktopSession(widget.credentialStore);
    final isRegistered = widget.snapshot.registered ||
        (widget.snapshot.workspaceId != null &&
            widget.snapshot.workspaceId!.isNotEmpty);
    final stage = widget.snapshot.connectionStage;
    final isConnecting = widget.snapshot.mode == WorkspaceUiMode.starting ||
        stage == WorkspaceConnectionStage.validating ||
        stage == WorkspaceConnectionStage.connecting ||
        stage == WorkspaceConnectionStage.authenticating ||
        stage == WorkspaceConnectionStage.synchronizing ||
        stage == WorkspaceConnectionStage.reconnecting;
    final serviceHealthy =
        widget.snapshot.serviceHealthy || widget.snapshot.serviceRunning;
    final isError = !serviceHealthy &&
        (widget.snapshot.mode == WorkspaceUiMode.offline ||
            widget.snapshot.mode == WorkspaceUiMode.installFailure) &&
        !isConnecting &&
        widget.snapshot.serviceInfo.process !=
            WorkspaceServiceProcessStatus.stopped;
    // Protect identity and user file location while the service owns them.
    final canEditWorkspaceSettings = !widget.snapshot.serviceProcessRunning &&
        !widget.snapshot.serviceRunning &&
        !widget.snapshot.cloudConnected;

    final serviceInfo = widget.snapshot.serviceInfo;
    final serviceRegistrationMissing = serviceInfo.registration ==
            WorkspaceBackgroundServiceRegistration.notRegistered ||
        serviceInfo.registration ==
            WorkspaceBackgroundServiceRegistration.serviceMissing ||
        serviceInfo.registration ==
            WorkspaceBackgroundServiceRegistration.unsupported;
    // An unknown host snapshot is used while the native manager is still
    // being queried. Keep the existing Start Service affordance during that
    // short window; an explicit notRegistered/serviceMissing response is what
    // renders the Register Service state.
    final serviceRegistered = !serviceRegistrationMissing &&
        (serviceInfo.registered ||
            widget.snapshot.serviceRunning ||
            serviceInfo.registration ==
                WorkspaceBackgroundServiceRegistration.approvalRequired ||
            serviceInfo.registration ==
                WorkspaceBackgroundServiceRegistration.unknown);
    final serviceLaunchSupported = serviceInfo.registration ==
            WorkspaceBackgroundServiceRegistration.unknown ||
        (serviceInfo.supported &&
            serviceInfo.launchSupported &&
            serviceInfo.helperPresent &&
            serviceInfo.plistPresent);
    final serviceProcessRunning = widget.snapshot.serviceProcessRunning ||
        widget.snapshot.serviceRunning ||
        serviceInfo.process == WorkspaceServiceProcessStatus.running;
    final ipcReady = widget.snapshot.serviceIpcReady ||
        widget.snapshot.serviceRunning ||
        serviceInfo.ipc == WorkspaceServiceIpcStatus.ready;
    final cloudRegistered = isRegistered;
    final serviceActionInProgress = _serviceActionPending ||
        serviceInfo.process == WorkspaceServiceProcessStatus.starting ||
        serviceInfo.process == WorkspaceServiceProcessStatus.stopping;
    final showStartupError = isError && !serviceActionInProgress;
    final showReleaseAction = cloudRegistered && widget.onRelease != null;
    final showResetAction = widget.onReset != null;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                enabled: canEditWorkspaceSettings &&
                    widget.onChangeWorkspaceName != null,
                readOnly: !canEditWorkspaceSettings ||
                    widget.onChangeWorkspaceName == null,
                maxLength: 200,
                onChanged: widget.onChangeWorkspaceName,
                decoration: const InputDecoration(
                  labelText: 'Workspace name',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _workRootController,
                enabled: canEditWorkspaceSettings,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Work Root',
                  hintText: 'Not configured',
                  border: const OutlineInputBorder(),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: TextButton.icon(
                      onPressed: canEditWorkspaceSettings &&
                              widget.onChangeWorkRoot != null
                          ? _browseWorkRoot
                          : null,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('Browse'),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (!serviceLaunchSupported)
                          Text(
                            'Background Service unavailable. Rebuild this app with an Apple signing identity for macOS background service execution.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          )
                        else if (!serviceRegistered)
                          FilledButton.icon(
                            onPressed: _serviceActionPending ||
                                    widget.onRegisterService == null
                                ? null
                                : () => _runServiceAction(
                                      widget.onRegisterService!,
                                    ),
                            icon: const Icon(Icons.app_registration, size: 16),
                            label: const Text('Register Service'),
                          )
                        else if (serviceProcessRunning)
                          FilledButton.icon(
                            onPressed: _serviceActionPending ||
                                    widget.onStopService == null
                                ? null
                                : () =>
                                    _runServiceAction(widget.onStopService!),
                            icon: _serviceActionPending
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.stop, size: 16),
                            label: Text(_serviceActionPending
                                ? 'Stopping…'
                                : 'Stop Service'),
                          )
                        else
                          FilledButton.icon(
                            onPressed: _serviceActionPending ||
                                    widget.onStartService == null
                                ? null
                                : () =>
                                    _runServiceAction(widget.onStartService!),
                            icon: _serviceActionPending
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.play_arrow, size: 16),
                            label: Text(_serviceActionPending
                                ? 'Starting…'
                                : 'Start Service'),
                          ),
                        if (serviceProcessRunning)
                          OutlinedButton.icon(
                            onPressed: _serviceActionPending ||
                                    widget.onRestartService == null
                                ? null
                                : () => _runServiceAction(
                                      widget.onRestartService!,
                                    ),
                            icon: const Icon(Icons.restart_alt, size: 16),
                            label: const Text('Restart'),
                          ),
                        if (serviceRegistered && !serviceProcessRunning)
                          OutlinedButton.icon(
                            onPressed: _serviceActionPending ||
                                    widget.onUnregisterService == null
                                ? null
                                : () => _runServiceAction(
                                      widget.onUnregisterService!,
                                    ),
                            icon: const Icon(Icons.remove_circle_outline,
                                size: 16),
                            label: const Text('Unregister'),
                          ),
                        if (!cloudRegistered)
                          FilledButton.icon(
                            onPressed: isConnecting || !effectiveSignedIn
                                ? null
                                : widget.onRegister == null &&
                                        widget.onRecoverCredential == null
                                    ? null
                                    : () {
                                        final name =
                                            _nameController.text.trim();
                                        if (widget.onRegister != null) {
                                          unawaited(widget.onRegister!(name));
                                        } else {
                                          unawaited(widget
                                              .onRecoverCredential!(name));
                                        }
                                      },
                            icon: const Icon(Icons.cloud_upload_outlined,
                                size: 16),
                            label: const Text('Register'),
                          )
                        else if (serviceProcessRunning && ipcReady)
                          widget.snapshot.cloudConnected
                              ? OutlinedButton.icon(
                                  onPressed: widget.onDisconnectCloud == null
                                      ? null
                                      : () => _runServiceAction(
                                          widget.onDisconnectCloud!),
                                  icon: const Icon(Icons.cloud_off_outlined,
                                      size: 16),
                                  label: const Text('Disconnect'),
                                )
                              : FilledButton.icon(
                                  onPressed: widget.onConnectCloud == null
                                      ? null
                                      : () => _runServiceAction(
                                          widget.onConnectCloud!),
                                  icon: const Icon(Icons.cloud_queue, size: 16),
                                  label: const Text('Connect'),
                                ),
                      ],
                    ),
                  ),
                  if (showReleaseAction || showResetAction) ...[
                    const SizedBox(width: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      alignment: WrapAlignment.end,
                      children: [
                        if (showReleaseAction)
                          OutlinedButton.icon(
                            onPressed: () => unawaited(widget.onRelease!()),
                            icon: const Icon(Icons.person_remove_outlined,
                                size: 16),
                            label: const Text('Release'),
                          ),
                        if (showResetAction)
                          OutlinedButton.icon(
                            onPressed: widget.onReset,
                            icon: Icon(Icons.delete_forever_outlined,
                                size: 16, color: theme.colorScheme.error),
                            label: Text('Reset',
                                style:
                                    TextStyle(color: theme.colorScheme.error)),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: theme.colorScheme.error
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (showStartupError) ...[
            _WorkspaceRecoveryPanel(
              issue: widget.snapshot.issue,
              retryLabel: !serviceProcessRunning
                  ? 'Retry service startup'
                  : 'Retry Cloud connection',
              onRetry: widget.onRetry,
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

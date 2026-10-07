part of '../main.dart';

class WorkspaceDashboard extends StatefulWidget {
  const WorkspaceDashboard({
    required this.snapshot,
    this.onSignIn,
    this.onSignOut,
    this.onConnect,
    this.onRegister,
    this.onRecoverCredential,
    this.onChangeWorkspaceName,
    this.onDisconnect,
    this.onRelease,
    this.onReset,
    this.onAccountAction,
    this.launchAtLogin = false,
    this.onLaunchAtLoginChanged,
    this.requireStepUp,
    this.onQuit,
    this.onRetry,
    this.onExportDiagnostics,
    this.onChangeWorkRoot,
    this.onReadinessCheck,
    this.onRollbackToolProfile,
    this.workerRevision = 0,
    this.localWorkerRegistry,
    this.credentialStore = const PlatformSecureCredentialStore(),
    this.workerCatalogCoordinator,
    this.signedIn = false,
    super.key,
  });

  final WorkspaceUiSnapshot snapshot;
  final Future<void> Function()? onSignIn;
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onConnect;
  final Future<void> Function([String? name])? onRegister;
  final Future<void> Function([String? name])? onRecoverCredential;
  final Future<void> Function(String name)? onChangeWorkspaceName;
  final VoidCallback? onDisconnect;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final VoidCallback? onAccountAction;
  final bool launchAtLogin;
  final ValueChanged<bool>? onLaunchAtLoginChanged;
  final LocalWorkerRegistry? localWorkerRegistry;
  final Future<bool> Function(String reason)? requireStepUp;
  final VoidCallback? onQuit;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;
  final Future<bool> Function(String workerTypeId)? onRollbackToolProfile;
  final int workerRevision;
  final SecureCredentialStore credentialStore;
  final WorkerCatalogCoordinator? workerCatalogCoordinator;
  final bool signedIn;

  @override
  State<WorkspaceDashboard> createState() => _WorkspaceDashboardState();
}

enum WorkspaceSurface { workspace, workers }

class _WorkspaceDashboardState extends State<WorkspaceDashboard> {
  WorkspaceSurface _selectedSurface = WorkspaceSurface.workspace;

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
    final stage = snapshot.connectionStage;
    final isConnecting = snapshot.mode == WorkspaceUiMode.starting ||
        stage == WorkspaceConnectionStage.validating ||
        stage == WorkspaceConnectionStage.connecting ||
        stage == WorkspaceConnectionStage.authenticating ||
        stage == WorkspaceConnectionStage.synchronizing ||
        stage == WorkspaceConnectionStage.reconnecting;
    final connectionLabel =
        snapshot.activeTransportMode == 'switching_to_websocket' ||
                stage == WorkspaceConnectionStage.switchingToWebSocket
            ? 'Switching to WebSocket…'
            : isConnected
                ? switch (snapshot.activeTransportMode) {
                    'websocket' => 'Connected · WebSocket',
                    'http_long_poll' => 'Connected · HTTPS fallback',
                    'switching_to_websocket' => 'Switching to WebSocket…',
                    _ => 'Connected',
                  }
                : isConnecting
                    ? (stage == WorkspaceConnectionStage.reconnecting
                        ? 'Reconnecting...'
                        : 'Connecting...')
                    : 'Offline';

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
                    const SizedBox(width: 10),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isConnected
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
                      widget.onRetry?.call();
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

        // Two-Surface Horizontal Tab Switcher
        if (snapshot.workspaceReady || effectiveSignedIn)
          Container(
            width: double.infinity,
            color: theme.colorScheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SurfaceTabButton(
                  icon: Icons.computer_outlined,
                  selectedIcon: Icons.computer,
                  label: 'Workspace',
                  selected: _selectedSurface == WorkspaceSurface.workspace,
                  onTap: () => setState(
                      () => _selectedSurface = WorkspaceSurface.workspace),
                ),
                const SizedBox(width: 16),
                _SurfaceTabButton(
                  icon: Icons.memory_outlined,
                  selectedIcon: Icons.memory,
                  label: 'Workers',
                  selected: _selectedSurface == WorkspaceSurface.workers,
                  onTap: () => setState(
                      () => _selectedSurface = WorkspaceSurface.workers),
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
              child: IndexedStack(
                index: _selectedSurface.index,
                children: [
                  _WorkspaceTab(
                    snapshot: snapshot,
                    signedIn: effectiveSignedIn,
                    credentialStore: widget.credentialStore,
                    onConnect: widget.onConnect,
                    onRegister: widget.onRegister,
                    onRecoverCredential: widget.onRecoverCredential,
                    onChangeWorkspaceName: widget.onChangeWorkspaceName,
                    onRetry: widget.onRetry,
                    onExportDiagnostics: widget.onExportDiagnostics,
                    onChangeWorkRoot: widget.onChangeWorkRoot,
                    launchAtLogin: widget.launchAtLogin,
                    onLaunchAtLoginChanged: widget.onLaunchAtLoginChanged,
                    onDisconnect:
                        snapshot.workspaceReady ? widget.onDisconnect : null,
                    onRelease: widget.onRelease,
                    onReset: widget.onReset,
                  ),
                  _WorkersTab(
                    key: ValueKey(widget.workerRevision),
                    registry: widget.localWorkerRegistry,
                    catalogCoordinator: widget.workerCatalogCoordinator,
                    isSelected: _selectedSurface == WorkspaceSurface.workers,
                    onRollbackToolProfile: widget.onRollbackToolProfile,
                    onReadinessCheck: widget.onReadinessCheck,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SurfaceTabButton extends StatelessWidget {
  const _SurfaceTabButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? activeColor : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? selectedIcon : icon,
              size: 18,
              color:
                  selected ? activeColor : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color:
                    selected ? activeColor : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceTab extends StatefulWidget {
  const _WorkspaceTab({
    required this.snapshot,
    this.signedIn = false,
    this.onConnect,
    this.onRegister,
    this.onRecoverCredential,
    this.onChangeWorkspaceName,
    required this.credentialStore,
    this.onRetry,
    this.onExportDiagnostics,
    this.onChangeWorkRoot,
    this.onDisconnect,
    this.onRelease,
    this.onReset,
    this.launchAtLogin = false,
    this.onLaunchAtLoginChanged,
  });

  final WorkspaceUiSnapshot snapshot;
  final bool signedIn;
  final Future<void> Function()? onConnect;
  final Future<void> Function([String? name])? onRegister;
  final Future<void> Function([String? name])? onRecoverCredential;
  final Future<void> Function(String name)? onChangeWorkspaceName;
  final SecureCredentialStore credentialStore;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final VoidCallback? onDisconnect;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final bool launchAtLogin;
  final ValueChanged<bool>? onLaunchAtLoginChanged;

  @override
  State<_WorkspaceTab> createState() => _WorkspaceTabState();
}

class _WorkspaceTabState extends State<_WorkspaceTab> {
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
      text: widget.snapshot.workRootPath ?? '',
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
    if (oldName != newName && widget.snapshot.workspaceReady) {
      _nameController.text = newName;
    }
    if (oldWidget.snapshot.workRootPath != widget.snapshot.workRootPath) {
      _workRootController.text = widget.snapshot.workRootPath ?? '';
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
    final isError = (widget.snapshot.mode == WorkspaceUiMode.offline ||
            widget.snapshot.mode == WorkspaceUiMode.installFailure) &&
        !isConnecting &&
        widget.snapshot.desiredRuntimeConnected;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (isError) ...[
          _WorkspaceRecoveryPanel(
            issue: widget.snapshot.issue,
            retryLabel: widget.snapshot.mode == WorkspaceUiMode.offline
                ? 'Retry connection'
                : 'Retry update',
            onRetry: widget.onRetry,
          ),
          const SizedBox(height: 24),
        ],
        TextField(
          controller: _nameController,
          enabled: !isRegistered,
          readOnly: isRegistered,
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
          enabled: !widget.snapshot.workspaceReady,
          readOnly: true,
          decoration: InputDecoration(
            labelText: 'Work Root',
            hintText: 'Not configured',
            border: const OutlineInputBorder(),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton.icon(
                onPressed:
                    widget.snapshot.workspaceReady ? null : _browseWorkRoot,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Browse'),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: widget.launchAtLogin,
          onChanged: widget.onLaunchAtLoginChanged,
          title: const Text('Start at login'),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            // Button 1: Connect / Disconnect
            if (widget.snapshot.workspaceReady ||
                widget.snapshot.cloudConnected)
              FilledButton.icon(
                onPressed: widget.onDisconnect,
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Disconnect'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              )
            else
              FilledButton.icon(
                onPressed: (!isRegistered || isConnecting)
                    ? null
                    : () {
                        if (widget.onConnect != null) {
                          unawaited(widget.onConnect!());
                        } else if (widget.onRecoverCredential != null) {
                          unawaited(widget.onRecoverCredential!(
                            _nameController.text.trim(),
                          ));
                        }
                      },
                icon: isConnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.sync, size: 16),
                label: Text(
                  isConnecting ? 'Connecting…' : 'Connect',
                ),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),

            // Button 2: Register / Release
            if (isRegistered)
              OutlinedButton.icon(
                onPressed: widget.onRelease != null
                    ? () => unawaited(widget.onRelease!())
                    : null,
                icon: const Icon(Icons.person_remove_outlined, size: 16),
                label: const Text('Release'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              )
            else
              FilledButton.icon(
                onPressed: (isConnecting || !effectiveSignedIn)
                    ? null
                    : () {
                        if (widget.onRegister != null) {
                          unawaited(widget.onRegister!(
                            _nameController.text.trim(),
                          ));
                        } else if (widget.onRecoverCredential != null) {
                          unawaited(widget.onRecoverCredential!(
                            _nameController.text.trim(),
                          ));
                        }
                      },
                icon: const Icon(Icons.app_registration, size: 16),
                label: const Text('Register'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),

            // Button 3: Reset
            if (widget.onReset != null)
              OutlinedButton.icon(
                onPressed: widget.onReset,
                icon: Icon(Icons.delete_forever_outlined,
                    size: 16, color: theme.colorScheme.error),
                label: Text('Reset',
                    style: TextStyle(color: theme.colorScheme.error)),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  side: BorderSide(
                      color: theme.colorScheme.error.withValues(alpha: 0.5)),
                ),
              ),
          ],
        ),
        if (isRegistered) ...[
          const SizedBox(height: 8),
          Text(
            'Disconnect keeps this installation owned by your account. '
            'Release lets another account claim it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 24),
        _WorkspaceDiagnosticsSection(
          snapshot: widget.snapshot,
          onExportDiagnostics: widget.onExportDiagnostics,
        ),
      ],
    );
  }
}

class _WorkspaceDiagnosticsSection extends StatelessWidget {
  const _WorkspaceDiagnosticsSection({
    required this.snapshot,
    this.onExportDiagnostics,
  });

  final WorkspaceUiSnapshot snapshot;
  final Future<void> Function()? onExportDiagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.analytics_outlined, size: 20),
          title: const Text(
            'Advanced Diagnostics',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            const Divider(height: 16),
            // Connection
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Connection',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Gateway state',
              value: snapshot.cloudConnected
                  ? switch (snapshot.activeTransportMode) {
                      'websocket' => 'Connected · WebSocket',
                      'http_long_poll' => 'Connected · HTTPS fallback',
                      'switching_to_websocket' => 'Switching to WebSocket',
                      _ => 'Connected',
                    }
                  : 'Disconnected',
            ),
            if (snapshot.cloudConnected &&
                snapshot.activeTransportMode == 'http_long_poll')
              const _DetailRow(
                label: 'Fallback status',
                value: 'WebSocket is unavailable. Work can continue.',
              ),
            if (snapshot.fallbackHealthStatus != null)
              _DetailRow(
                label: 'HTTPS fallback health',
                value: snapshot.fallbackHealthStatus!,
              ),
            if (snapshot.lastWebSocketFailure != null)
              _DetailRow(
                label: 'Last WSS failure',
                value: snapshot.lastWebSocketHttpStatusCode == null
                    ? snapshot.lastWebSocketFailure!
                    : '${snapshot.lastWebSocketFailure} (HTTP ${snapshot.lastWebSocketHttpStatusCode})',
              ),
            _DetailRow(
              label: 'Gateway URL',
              value: snapshot.cloudUrl ?? 'Not configured',
            ),
            _DetailRow(
              label: 'Connection stage',
              value: snapshot.connectionStage?.name ?? 'Offline',
            ),
            _DetailRow(
              label: 'Runtime credential',
              value: snapshot.runtimeCredentialStatus,
            ),
            _DetailRow(
              label: 'DNS / TLS',
              value: snapshot.dnsTlsStatus ?? 'not checked',
            ),
            _DetailRow(
              label: 'WebSocket upgrade',
              value: snapshot.webSocketUpgradeStatus ?? 'not completed',
            ),
            _DetailRow(
              label: 'Protocol hello',
              value: snapshot.protocolHelloStatus ?? 'not started',
            ),
            _DetailRow(
              label: 'Last attempt',
              value: snapshot.lastConnectionAttemptAt?.toLocal().toString() ??
                  'Never',
            ),
            if (snapshot.connectionError != null)
              _DetailRow(
                label: 'Connection detail',
                value: snapshot.connectionError!,
              ),
            _DetailRow(
              label: 'Session ID',
              value: snapshot.sessionId ?? 'No active session',
            ),
            _DetailRow(
              label: 'Reconnect count',
              value: '${snapshot.reconnectCount}',
            ),
            _DetailRow(
              label: 'Last inventory sync',
              value: snapshot.lastInventorySyncAt != null
                  ? '${snapshot.lastInventorySyncAt!.toLocal()}'
                  : 'Never',
            ),
            _DetailRow(
              label: 'Active assignments',
              value: '${snapshot.activeAssignments}',
            ),
            if (snapshot.activeAssignmentIds.isNotEmpty) ...[
              const SizedBox(height: 4),
              for (final id in snapshot.activeAssignmentIds)
                Padding(
                  padding: const EdgeInsets.only(left: 138, bottom: 2),
                  child: Text(id, style: ConclaveTypography.monoSmall),
                ),
            ],
            const SizedBox(height: 12),

            // Identity
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Identity',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            if (snapshot.installationId != null)
              _CopyableDetailRow(
                label: 'Installation ID',
                value: snapshot.installationId!,
              ),
            _CopyableDetailRow(
              label: 'Workspace ID',
              value: snapshot.workspaceId ??
                  snapshot.workspaceRuntimeId ??
                  'Not registered',
            ),
            _CopyableDetailRow(
              label: 'Runtime ID',
              value: snapshot.workspaceRuntimeId ?? 'Not assigned',
            ),
            const SizedBox(height: 12),

            // System
            Align(
              alignment: Alignment.centerLeft,
              child: Text('System',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            _CopyableDetailRow(
              label: 'Hostname',
              value: snapshot.hostname ?? Platform.localHostname,
            ),
            _DetailRow(
              label: 'OS',
              value:
                  '${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
            ),
            const SizedBox(height: 12),

            // Logs
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Logs',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: Text(
                    'Logs Path',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    snapshot.logsPath ?? 'Not available',
                    style: ConclaveTypography.monoSmall,
                  ),
                ),
                if (snapshot.logsPath != null)
                  TextButton.icon(
                    onPressed: () => WorkspaceLifecycleController.openPath(
                        snapshot.logsPath!),
                    icon: const Icon(Icons.open_in_new, size: 14),
                    label: const Text('Open Log File',
                        style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final uri = Uri.tryParse(snapshot.cloudUrl ?? '');
                    final origin = uri == null
                        ? 'Not configured'
                        : Uri(
                            scheme: uri.scheme == 'wss'
                                ? 'https'
                                : uri.scheme == 'ws'
                                    ? 'http'
                                    : uri.scheme,
                            host: uri.host,
                            port: uri.hasPort ? uri.port : null,
                          ).toString();
                    final report = [
                      'Cloud origin: $origin',
                      'WebSocket endpoint: ${uri == null ? 'Not configured' : Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path)}',
                      'Workspace runtime ID: ${snapshot.workspaceRuntimeId ?? 'Not assigned'}',
                      'Runtime credential: ${snapshot.runtimeCredentialAvailable ? 'available locally (value withheld)' : snapshot.desiredRuntimeConnected ? 'missing from secure storage (runtime desired connected)' : 'not present (runtime desired disconnected; expected)'}',
                      'DNS/TLS: ${snapshot.dnsTlsStatus ?? 'not checked'}',
                      'WebSocket upgrade: ${snapshot.webSocketUpgradeStatus ?? 'not completed'}',
                      'Active transport: ${snapshot.activeTransportMode ?? 'offline'}',
                      'HTTPS fallback health: ${snapshot.fallbackHealthStatus ?? 'not configured'}',
                      'Last WSS failure: ${snapshot.lastWebSocketFailure ?? 'none'}${snapshot.lastWebSocketHttpStatusCode == null ? '' : ' (HTTP ${snapshot.lastWebSocketHttpStatusCode})'}',
                      'Last WSS failure at: ${snapshot.lastWebSocketFailureAt?.toUtc().toIso8601String() ?? 'never'}',
                      'Protocol hello: ${snapshot.protocolHelloStatus ?? 'not started'}',
                      'Connection stage: ${snapshot.connectionStage?.name ?? 'offline'}',
                      'HTTP status: ${snapshot.connectionHttpStatus ?? 'none'}',
                      'Last attempt: ${snapshot.lastConnectionAttemptAt?.toUtc().toIso8601String() ?? 'never'}',
                      'Last error: ${snapshot.connectionError ?? 'none'}',
                    ].join('\n');
                    await Clipboard.setData(ClipboardData(text: report));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Connection diagnostics copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy connection details'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onExportDiagnostics,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('Export Report'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

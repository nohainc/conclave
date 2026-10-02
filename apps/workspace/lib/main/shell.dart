part of '../main.dart';

class _ShellAccess {
  const _ShellAccess(
    this.humanAuth, {
    this.session,
    this.signInRequired = false,
  });

  final HumanAuthState humanAuth;
  final DesktopHumanSession? session;
  final bool signInRequired;
}

/// Selects a shell only after validating the desktop management session.
/// The runtime is owned by [WorkspaceLifecycleController] and keeps running while
/// this widget checks or changes the management surface.
class WorkspaceShellRouter extends StatefulWidget {
  const WorkspaceShellRouter({
    required this.snapshot,
    required this.credentialStore,
    required this.cloudUrl,
    required this.refreshToken,
    required this.restoreSession,
    required this.onSignIn,
    required this.onConnectWorkspace,
    required this.onSignOut,
    this.onRelease,
    required this.onQuit,
    this.onRetry,
    this.onManagementAuthRequiredChanged,
    required this.managementShellBuilder,
    super.key,
  });

  final WorkspaceUiSnapshot snapshot;
  final SecureCredentialStore credentialStore;
  final String cloudUrl;
  final int refreshToken;
  final Future<DesktopHumanSession?> Function(DesktopHumanSession session)
      restoreSession;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onConnectWorkspace;
  final Future<void> Function() onSignOut;
  final Future<void> Function()? onRelease;
  final Future<void> Function() onQuit;
  final Future<void> Function()? onRetry;
  final ValueChanged<bool>? onManagementAuthRequiredChanged;
  final Widget Function() managementShellBuilder;

  @override
  State<WorkspaceShellRouter> createState() => _WorkspaceShellRouterState();
}

enum _HeaderMenuAction {
  openConclaveAX,
  checkForUpdates,
  about,
  signOut,
}

class _WorkspaceShellRouterState extends State<WorkspaceShellRouter> {
  late Future<_ShellAccess> _access;

  @override
  void initState() {
    super.initState();
    _access = _loadAccess();
  }

  @override
  void didUpdateWidget(covariant WorkspaceShellRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      _access = _loadAccess();
    }
  }

  Future<_ShellAccess> _loadAccess() async {
    final access = await _resolveAccess();
    widget.onManagementAuthRequiredChanged?.call(
      access.humanAuth == HumanAuthState.reauthRequired,
    );
    return access;
  }

  Future<_ShellAccess> _resolveAccess() async {
    final runtimeIntendedConnected = widget.snapshot.cloudConnected ||
        widget.snapshot.desiredRuntimeConnected;
    _ShellAccess invalidSession([DesktopHumanSession? session]) => _ShellAccess(
          runtimeIntendedConnected
              ? HumanAuthState.reauthRequired
              : HumanAuthState.signedOut,
          session: session,
          signInRequired: true,
        );

    final stored = await widget.credentialStore.read(desktopHumanCredentialKey);
    if (stored == null || stored.isEmpty) {
      return _ShellAccess(
        widget.snapshot.registered && runtimeIntendedConnected
            ? HumanAuthState.reauthRequired
            : HumanAuthState.signedOut,
      );
    }

    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) throw const FormatException('Invalid session data');
      final credential = decoded['credential'];
      final sessionId = decoded['sessionId'];
      final userId = decoded['userId'];
      final displayName = decoded['displayName'];
      final email = decoded['email'];
      final expiresAt =
          DateTime.tryParse(decoded['expiresAt']?.toString() ?? '');
      final issuedAt = DateTime.tryParse(decoded['issuedAt']?.toString() ?? '');
      if (credential is! String ||
          sessionId is! String ||
          userId is! String ||
          displayName is! String ||
          email is! String ||
          expiresAt == null) {
        throw const FormatException('Invalid session identity');
      }
      final session = DesktopHumanSession(
        credential: credential,
        sessionId: sessionId,
        userId: userId,
        displayName: displayName,
        email: email,
        expiresAt: expiresAt,
        issuedAt: issuedAt,
      );
      if (!expiresAt.isAfter(DateTime.now().toUtc())) {
        return invalidSession(session);
      }
      final ownerUserId = widget.snapshot.ownerUserId;
      if (widget.snapshot.registered &&
          (ownerUserId == null || ownerUserId != session.userId)) {
        return _ShellAccess(
          HumanAuthState.reauthRequired,
          session: session,
        );
      }
      final restored = await widget.restoreSession(session);
      if (restored == null ||
          restored.sessionId != session.sessionId ||
          restored.userId != session.userId) {
        return invalidSession(session);
      }
      if (restored.credential != session.credential) {
        await widget.credentialStore.write(
          desktopHumanCredentialKey,
          jsonEncode(restored.toSecureJson()),
        );
      }
      return _ShellAccess(HumanAuthState.signedIn, session: restored);
    } on Object {
      return runtimeIntendedConnected
          ? _ShellAccess(HumanAuthState.reauthRequired)
          : _ShellAccess(HumanAuthState.signedOut, signInRequired: true);
    }
  }

  WorkspaceLifecycleState _lifecycleState(HumanAuthState humanAuth) {
    final snapshot = widget.snapshot;
    final stage = snapshot.connectionStage;
    final connecting = snapshot.mode == WorkspaceUiMode.starting ||
        stage == WorkspaceConnectionStage.validating ||
        stage == WorkspaceConnectionStage.connecting ||
        stage == WorkspaceConnectionStage.authenticating ||
        stage == WorkspaceConnectionStage.synchronizing ||
        stage == WorkspaceConnectionStage.reconnecting ||
        stage == WorkspaceConnectionStage.switchingToWebSocket;
    final participation = snapshot.cloudConnected
        ? WorkspaceParticipationState.connected
        : snapshot.desiredRuntimeConnected && connecting
            ? WorkspaceParticipationState.connecting
            : WorkspaceParticipationState.disconnected;
    return WorkspaceLifecycleState(
      humanAuth: humanAuth,
      participation: participation,
      managementLock: ManagementLockState.unlocked,
      desiredRuntime: snapshot.desiredRuntimeConnected
          ? DesiredRuntimeState.connected
          : DesiredRuntimeState.disconnected,
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Conclave Workspace',
      applicationVersion: 'v${widget.snapshot.appVersion}',
      applicationIcon: ConclaveBrand.logoMark(size: 40),
      children: const [
        Text('Conclave Workspace Runtime and Local Worker Manager.'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_ShellAccess>(
        future: _access,
        builder: (context, result) {
          final access = result.data;
          if (access == null) {
            return const _MinimalShell(
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final lifecycle = _lifecycleState(access.humanAuth);
          switch (lifecycle.humanAuth) {
            case HumanAuthState.signedOut:
              return _MinimalShell(
                onAbout: _showAbout,
                onRetry: widget.onRetry,
                child: _SignedOutShell(
                  onSignIn: widget.onSignIn,
                  signInRequired: access.signInRequired,
                ),
              );
            case HumanAuthState.reauthRequired:
              return _MinimalShell(
                onAbout: _showAbout,
                onRetry: widget.onRetry,
                child: _ReauthRequiredShell(
                  runtimeConnected: widget.snapshot.cloudConnected,
                  onSignIn: widget.onSignIn,
                ),
              );
            case HumanAuthState.signedIn:
              return widget.managementShellBuilder();
          }
        },
      );
}

class _MinimalShell extends StatelessWidget {
  const _MinimalShell({
    required this.child,
    this.onAbout,
    this.onRetry,
  });

  final Widget child;
  final VoidCallback? onAbout;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(children: [
            ConclaveBrand.logoMark(size: 26),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Conclave Workspace',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 4),
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
                    onRetry?.call();
                    break;
                  case _HeaderMenuAction.about:
                    onAbout?.call();
                    break;
                  case _HeaderMenuAction.signOut:
                    break;
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
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
                PopupMenuItem(
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
                PopupMenuItem(
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
              ],
            ),
          ]),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _SignedOutShell extends StatelessWidget {
  const _SignedOutShell({required this.onSignIn, this.signInRequired = false});

  final Future<void> Function() onSignIn;
  final bool signInRequired;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ConclaveBrand.logoMark(size: 48),
                const SizedBox(height: 18),
                Text(
                    signInRequired
                        ? 'Sign in required'
                        : 'Sign in to Conclave Workspace',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                const Text(
                  'Sign in with your Conclave account to manage this computer.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => unawaited(onSignIn()),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _ReauthRequiredShell extends StatelessWidget {
  const _ReauthRequiredShell({
    required this.runtimeConnected,
    required this.onSignIn,
  });

  final bool runtimeConnected;
  final Future<void> Function() onSignIn;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline, size: 42),
                const SizedBox(height: 16),
                Text('Sign in again to manage Workspace',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(runtimeConnected
                    ? 'The runtime remains connected. Sign in as the Workspace owner to manage it.'
                    : 'Sign in as the Workspace owner to continue managing this computer.'),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => unawaited(onSignIn()),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
              ]),
            ),
          ),
        ),
      );
}

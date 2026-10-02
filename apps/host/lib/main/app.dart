part of '../main.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WorkspacePaths.migrateLegacyMacLayout(
    migrateState: Platform.environment['CONCLAVE_HOST_DATA_DIR'] == null,
  );
  const credentialStore = PlatformSecureCredentialStore(
    nativeKeychain: FlutterMacKeychainBridge(),
  );
  final dataDirectory = HostConfig.resolveDataDirectory(const []);
  final preferencesStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
  final registration = HostRegistrationStore(dataDirectory).readSync();
  var runtimeCredentialLoaded = false;
  var hasRuntimeCredential = false;
  if (preferencesStore.needsRuntimeCredentialMigrationCheck &&
      registration != null) {
    hasRuntimeCredential =
        (await credentialStore.readForSynchronousConfig(registration.hostId))
                ?.isNotEmpty ==
            true;
    runtimeCredentialLoaded = true;
  }
  try {
    await preferencesStore.migrateLegacyIfNeeded(
      hasRuntimeRegistrationAndCredential:
          registration != null && hasRuntimeCredential,
    );
  } on Object catch (error) {
    // A failed preference migration must not prevent the management shell from
    // opening. The unversioned state reader still preserves any valid explicit
    // intent; otherwise its safe default suppresses runtime auto-connect.
    debugPrint('Could not migrate Workspace lifecycle preferences: $error');
  }
  final startupPreferences = preferencesStore.readSync();
  final desiredRuntime = startupPreferences.desiredRuntime;
  if (shouldHideManagementWindowOnStartup(
    isMacOS: Platform.isMacOS,
    launchAtLogin: startupPreferences.launchAtLogin,
  )) {
    unawaited(const MethodChannel('com.conclave.workspace/desktop')
        .invokeMethod<void>('hideMainWindow')
        .catchError((_) {}));
  }
  if (registration != null &&
      desiredRuntime == DesiredRuntimeState.connected &&
      !runtimeCredentialLoaded) {
    await credentialStore.readForSynchronousConfig(registration.hostId);
  }
  await credentialStore.read(desktopHumanCredentialKey);
  final config = HostConfig.fromArgs(
    const [],
    credentialStore: credentialStore,
    ignoreSavedRegistration: desiredRuntime == DesiredRuntimeState.disconnected,
  );
  final host = await buildWorkspaceRuntime(
    config,
    credentialStore: credentialStore,
  );
  runApp(ConclaveHostApp(lifecycle: HostLifecycleController(host)));
}

class ConclaveHostApp extends StatefulWidget {
  const ConclaveHostApp({
    required this.lifecycle,
    this.localAuthenticator = const MethodChannelLocalManagementAuthenticator(),
    super.key,
  });

  final HostLifecycleController lifecycle;
  final LocalManagementAuthenticator localAuthenticator;

  @override
  State<ConclaveHostApp> createState() => _ConclaveHostAppState();
}

class _ConclaveHostAppState extends State<ConclaveHostApp>
    with WidgetsBindingObserver {
  int _workerRevision = 0;
  late final RecentLocalAuthenticationGate _stepUpGate;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stepUpGate = RecentLocalAuthenticationGate(
      authenticator: widget.localAuthenticator,
    );
    widget.lifecycle.addListener(_refresh);
    const desktopChannel = MethodChannel('com.conclave.workspace/desktop');
    desktopChannel.setMethodCallHandler((call) async {
      if (call.method == 'menuAction' && call.arguments is String) {
        final action = call.arguments as String;
        if (action == 'quit') {
          await _confirmQuit();
        } else {
          await widget.lifecycle.handleDesktopAction(action);
        }
      } else if (call.method == 'requestQuit') {
        await _confirmQuit();
      }
    });
    unawaited(widget.lifecycle.launch());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.lifecycle.removeListener(_refresh);
    unawaited(widget.lifecycle.quit());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.lifecycle.checkWorkerReadiness());
    }
  }

  void _refresh() => setState(() {});

  WorkspaceLifecyclePreferences get _preferences =>
      WorkspaceLifecyclePreferencesStore(
        widget.lifecycle.host.config.dataDirectory,
      ).readSync();

  Future<bool> _requireStepUp(String reason) async {
    var authenticated = false;
    try {
      authenticated = await _stepUpGate.require(reason);
    } on Object {
      authenticated = false;
    }
    if (!authenticated && mounted) {
      final context = _navigatorKey.currentContext;
      if (context != null) {
        showCopyableMessageSnackBar(
          context,
          'Local authentication was not completed.',
          isError: true,
        );
      }
    }
    return authenticated;
  }

  Future<void> _setLaunchAtLogin(bool enabled) async {
    try {
      await HostLifecycleController.setLaunchAtLogin(enabled);
    } catch (e) {
      debugPrint('Could not set launch at login via desktop channel: $e');
    }
    final store = WorkspaceLifecyclePreferencesStore(
      widget.lifecycle.host.config.dataDirectory,
    );
    final p = store.readSync();
    await store.write(WorkspaceLifecyclePreferences(
      desiredRuntime: p.desiredRuntime,
      launchAtLogin: enabled,
      managementLockPreference: p.managementLockPreference,
      autoLockTimeout: p.autoLockTimeout,
      ownerUserId: p.ownerUserId,
      ownerDisplayName: p.ownerDisplayName,
      customWorkspaceName: p.customWorkspaceName,
    ));
    if (mounted) setState(() {});
  }

  Future<void> _confirmQuit() async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final lifecycle = widget.lifecycle;
    final connection = lifecycle.host.cloudConnection;
    final initialCount = connection?.activeAssignmentCount ?? 0;
    if (initialCount > 0) {
      final drainAndQuit = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('Assignments are running'),
          content: CopyableMessageText(
            'There ${initialCount == 1 ? 'is 1 active assignment' : 'are $initialCount active assignments'}. '
            'Drain and quit stops accepting new work, waits for active assignments to finish, then closes the runtime. '
            'If they do not finish within 15 seconds, the Workspace stays open.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Drain and quit'),
            ),
          ],
        ),
      );
      if (drainAndQuit != true || !mounted) return;

      if (connection != null) {
        final acceptingBeforeDrain = connection.acceptingNewWork;
        final drained = await drainWorkspaceAssignments(
          activeAssignmentCount: () => connection.activeAssignmentCount,
          beginDrain: () {
            connection.beginDrain();
            lifecycle.refreshMenuStatus();
          },
          restoreNewWorkState: acceptingBeforeDrain
              ? () {
                  connection.resumeNewWork();
                  lifecycle.refreshMenuStatus();
                }
              : () {
                  connection.pauseNewWork();
                  lifecycle.refreshMenuStatus();
                },
        );
        if (!drained) {
          if (!mounted) return;
          await showDialog<void>(
            context: dialogContext,
            builder: (context) => AlertDialog(
              title: const Text('Assignments are still running'),
              content: CopyableMessageText(
                'The Workspace remains open with ${connection.activeAssignmentCount} active assignments. '
                '${acceptingBeforeDrain ? 'New work has resumed.' : 'New work remains paused.'}',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Keep Workspace running'),
                ),
              ],
            ),
          );
          return;
        }
      }
    } else {
      // Prevent an assignment racing the shutdown between the count check and
      // closing the transport.
      connection?.beginDrain();
      lifecycle.refreshMenuStatus();
    }

    try {
      await lifecycle.quit();
      const desktopChannel = MethodChannel('com.conclave.workspace/desktop');
      await desktopChannel.invokeMethod<void>('terminate');
    } catch (error) {
      if (mounted) {
        await showDialog<void>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: const Text('Unable to Quit'),
            content: CopyableMessageText(
              'An error occurred while stopping the Workspace: $error\n\n'
              'Conclave Workspace did not close.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _exportDiagnostics() async {
    final file = await widget.lifecycle.exportDiagnostics();
    final ctx = _navigatorKey.currentContext;
    if (!mounted || ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text('Diagnostics exported to ${file.path}')),
    );
  }

  Future<DesktopHumanSession?> _approveDesktopAuthInBrowser(
    DesktopAuthClient client,
    DesktopAuthIntent intent, {
    required String title,
    required String description,
  }) async {
    final context = _navigatorKey.currentContext;
    if (context == null) return null;
    var browserOpened = false;
    var browserOpening = false;
    var cancelled = false;
    var dialogOpen = true;
    String? browserError;
    final dialogResult = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(browserOpened
                  ? 'Complete sign-in and approve Conclave Workspace in your browser. This window will update automatically.'
                  : description),
              if (browserError != null) ...[
                const SizedBox(height: 12),
                SelectableText(browserError!),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: browserOpening
                  ? null
                  : () async {
                      setDialogState(() {
                        browserOpening = true;
                        browserError = null;
                      });
                      try {
                        await client.cancelIntent(intent);
                      } on Object catch (error) {
                        // The request may already have been approved or expired.
                        // Closing the desktop dialog still stops its local wait;
                        // browser tabs observe the server's terminal state.
                        browserError = error.toString();
                      }
                      cancelled = true;
                      dialogOpen = false;
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    },
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: browserOpening
                  ? null
                  : () async {
                      setDialogState(() {
                        browserOpening = true;
                        browserError = null;
                      });
                      try {
                        await client.openVerification(intent);
                        if (!dialogOpen) return;
                        setDialogState(() {
                          browserOpened = true;
                          browserOpening = false;
                        });
                      } on Object catch (error) {
                        if (!dialogOpen) return;
                        setDialogState(() {
                          browserOpening = false;
                          browserError = error.toString();
                        });
                      }
                    },
              icon: const Icon(Icons.open_in_browser),
              label: Text(browserOpening
                  ? 'Opening…'
                  : browserOpened
                      ? 'Open browser again'
                      : 'Open browser'),
            ),
          ],
        ),
      ),
    );
    try {
      return await Future.any<DesktopHumanSession>([
        client.waitForApprovalAndClaim(
          intent,
          isCancelled: () => cancelled,
        ),
        dialogResult
            .then((_) => throw StateError('Workspace sign-in was cancelled.')),
      ]);
    } on StateError {
      if (cancelled) return null;
      rethrow;
    } finally {
      if (mounted && dialogOpen) {
        dialogOpen = false;
        Navigator.of(context, rootNavigator: true).pop(false);
      }
    }
  }

  Future<void> _signInDesktopHuman() async {
    final lifecycle = widget.lifecycle;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    final registration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    final client = DesktopAuthClient(cloudUrl: cloudUrl);
    DesktopHumanSession? previousSession;
    var failureContext = 'creating the sign-in request';
    DesktopHumanSession? claimedSession;
    try {
      final previousRecord =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (previousRecord != null) {
        try {
          final decoded = jsonDecode(previousRecord);
          if (decoded is Map) {
            previousSession = DesktopHumanSession.fromSecureJson(
              Map<String, dynamic>.from(decoded),
            );
          }
        } on Object {
          // Replace malformed local session data after the new session succeeds.
        }
      }
      final intent = await client.createIntent();
      failureContext = 'waiting for browser approval';
      final session = await _approveDesktopAuthInBrowser(
        client,
        intent,
        title: 'Sign in to Conclave Workspace',
        description:
            'Open the secure sign-in request in your browser, then sign in to your Conclave account and approve Conclave Workspace.',
      );
      if (session == null) return;
      claimedSession = session;
      failureContext = 'validating the desktop session';
      await client.validateSession(session);
      final existingRegistration = HostRegistrationStore(
        lifecycle.host.config.dataDirectory,
      ).readSync();
      final identityStore =
          InstallationIdentityStore(lifecycle.host.config.dataDirectory);
      final installationId = existingRegistration?.installationId ??
          identityStore.readSync() ??
          (existingRegistration == null
              ? null
              : await identityStore.getOrCreate());
      if (installationId != null) {
        failureContext = 'checking Workspace account ownership';
        final cloudOwnerUserId = await client.checkWorkspaceOwnership(
          session: session,
          installationId: installationId,
          workspaceId: existingRegistration?.workspaceId,
          runtimeId: existingRegistration?.hostId,
        );
        if (cloudOwnerUserId != session.userId) {
          throw StateError(
            'This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.',
          );
        }
        if (previousSession != null &&
            previousSession.userId != session.userId &&
            !await _requireStepUp('Switch the Workspace account')) {
          throw StateError(
              'Local authentication is required to switch accounts.');
        }
        if (existingRegistration != null) {
          await HostRegistrationStore(
            lifecycle.host.config.dataDirectory,
          ).write(HostRegistration(
            hostId: existingRegistration.hostId,
            workspaceId: existingRegistration.workspaceId,
            cloudUrl: existingRegistration.cloudUrl,
            name: existingRegistration.name,
            hostname: existingRegistration.hostname,
            ownerUserId: cloudOwnerUserId,
            installationId: installationId,
            credentialRef: existingRegistration.credentialRef,
            pairedAt: existingRegistration.pairedAt,
          ));
        }
      }
      if (previousSession != null &&
          previousSession.userId != session.userId &&
          installationId == null &&
          !await _requireStepUp('Switch the Workspace account')) {
        throw StateError(
            'Local authentication is required to switch accounts.');
      }
      await lifecycle.host.credentialStore.write(
        desktopHumanCredentialKey,
        jsonEncode(session.toSecureJson()),
      );
      if (previousSession != null &&
          previousSession.sessionId != session.sessionId) {
        try {
          await client.revokeSession(previousSession);
        } on Object {
          // Replacing local state must not fail if the old session already expired.
        }
      }
      final preferenceStore = WorkspaceLifecyclePreferencesStore(
        lifecycle.host.config.dataDirectory,
      );
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: existingRegistration == null
            ? DesiredRuntimeState.disconnected
            : preferences.desiredRuntime,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
      ));
      if (!mounted) return;
      setState(() => _workerRevision++);
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        SnackBar(content: Text('Signed in as ${session.displayName}.')),
      );
    } catch (error) {
      if (claimedSession != null) {
        try {
          await client.revokeSession(claimedSession);
        } on Object {
          // A failed ownership check must never replace the stored session.
        }
      }
      if (mounted) {
        showCopyableErrorSnackBar(
          dialogContext,
          'Sign-in failed while $failureContext: $error',
        );
      }
    } finally {
      client.close();
    }
  }

  Future<void> _signOutDesktopHuman() async {
    final lifecycle = widget.lifecycle;
    final registration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    final desiredRuntime = WorkspaceLifecyclePreferencesStore(
      lifecycle.host.config.dataDirectory,
    ).readSync().desiredRuntime;
    final runtimeIntendedConnected =
        desiredRuntime == DesiredRuntimeState.connected;
    if (registration != null && runtimeIntendedConnected) {
      final dialogContext = _navigatorKey.currentContext;
      if (dialogContext == null) return;
      final choice = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('This Workspace is connected.'),
          content: const Text(
            'Disconnect this Workspace before signing out. Disconnecting keeps '
            'the installation owner and local Workers, credentials, Profiles, '
            'and Work Root.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Disconnect and sign out'),
            ),
          ],
        ),
      );
      if (choice != true) return;
      await _disconnectWorkspace(confirmed: true);
      if (WorkspaceLifecyclePreferencesStore(
            lifecycle.host.config.dataDirectory,
          ).readSync().desiredRuntime !=
          DesiredRuntimeState.disconnected) {
        return;
      }
    }
    final stored =
        await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          final session = DesktopHumanSession.fromSecureJson(
            Map<String, dynamic>.from(decoded),
          );
          final client = DesktopAuthClient(
              cloudUrl: registration?.cloudUrl ?? conclaveProductionCloudUrl);
          try {
            await client.revokeSession(session);
          } finally {
            client.close();
          }
        }
      } on Object {
        // Local sign-out must remain available if Cloud is unreachable or the session expired.
      }
    }
    await lifecycle.host.credentialStore.delete(desktopHumanCredentialKey);
    if (mounted) setState(() => _workerRevision++);
  }

  Future<void> _registerWorkspace([String? name]) async {
    final lifecycle = widget.lifecycle;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final registration = HostRegistrationStore(dataDirectory).readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    try {
      final encoded =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (encoded == null) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final session = DesktopHumanSession.fromSecureJson(
        Map<String, dynamic>.from(decoded),
      );
      final authClient = DesktopAuthClient(cloudUrl: cloudUrl);
      try {
        await authClient.validateSession(session);
      } finally {
        authClient.close();
      }
      final installationId =
          await InstallationIdentityStore(dataDirectory).getOrCreate();
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final preferences = preferenceStore.readSync();
      final workspaceName = (name != null && name.trim().isNotEmpty)
          ? name.trim()
          : (registration?.name ??
              preferences.customWorkspaceName ??
              await resolveFriendlyComputerName());
      if (workspaceName.trim().isEmpty) {
        throw StateError('Workspace name cannot be empty.');
      }

      final facts = SafeMachineFacts.collect(
          installationId: installationId,
          name: workspaceName,
          hostname: Platform.localHostname);
      await WorkspacePairingService(
              dataDirectory: dataDirectory,
              credentialStore: lifecycle.host.credentialStore)
          .registerWithDesktopSession(
        cloudUrl: cloudUrl,
        desktopCredential: session.credential,
        facts: facts,
        expectedOwnerUserId: session.userId,
        existingWorkspaceId: registration?.workspaceId,
        existingRuntimeId: registration?.hostId,
      );
      try {
        await HostLifecycleController.setLaunchAtLogin(
            preferences.launchAtLogin);
      } catch (_) {}
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
        customWorkspaceName: workspaceName,
      ));
      final config = HostConfig.fromArgs(
        const [],
        credentialStore: lifecycle.host.credentialStore,
        ignoreSavedRegistration: true,
      );
      await lifecycle.replaceHost(await buildWorkspaceRuntime(
        config,
        credentialStore: lifecycle.host.credentialStore,
      ));
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Workspace registered.')));
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
            context, 'Could not register Workspace: $error');
      }
    }
  }

  Future<void> _connectWorkspace({String? name}) async {
    final lifecycle = widget.lifecycle;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    if (lifecycle.host.cloudConnection?.isConnected == true ||
        lifecycle.host.cloudConnection?.connectionStage ==
            HostConnectionStage.ready ||
        (lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      showCopyableErrorSnackBar(
        context,
        'Disconnect or let active work finish before connecting this Workspace again.',
      );
      return;
    }
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final registration = HostRegistrationStore(dataDirectory).readSync();
    if (registration == null) {
      await _registerWorkspace(name);
      return;
    }
    final cloudUrl = registration.cloudUrl;
    try {
      final encoded =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (encoded == null) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final session = DesktopHumanSession.fromSecureJson(
        Map<String, dynamic>.from(decoded),
      );
      final authClient = DesktopAuthClient(cloudUrl: cloudUrl);
      try {
        await authClient.validateSession(session);
      } finally {
        authClient.close();
      }
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final preferences = preferenceStore.readSync();
      try {
        await HostLifecycleController.setLaunchAtLogin(
            preferences.launchAtLogin);
      } catch (_) {}
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.connected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
        customWorkspaceName:
            preferences.customWorkspaceName ?? registration.name,
      ));
      final config = HostConfig.fromArgs(const [],
          credentialStore: lifecycle.host.credentialStore);
      await lifecycle.replaceHost(await buildWorkspaceRuntime(config,
          credentialStore: lifecycle.host.credentialStore));
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        final connection = lifecycle.host.cloudConnection;
        if (connection?.connectionStage == HostConnectionStage.ready) break;
        if (!lifecycle.running) {
          throw StateError('Workspace runtime stopped before becoming Ready.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (lifecycle.host.cloudConnection?.connectionStage !=
          HostConnectionStage.ready) {
        throw TimeoutException(
          'Workspace did not become Ready within 45 seconds.',
        );
      }
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Workspace is connected and Ready.')));
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
            context, 'Could not connect Workspace: $error');
      }
    }
  }

  Future<DesktopHumanSession?> _reauthenticateWorkspaceOwner(
    String expectedOwnerUserId, {
    bool revokeAfterVerification = true,
  }) async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return null;
    final registration = HostRegistrationStore(
      widget.lifecycle.host.config.dataDirectory,
    ).readSync();
    final cloudUrl = registration?.cloudUrl ?? conclaveProductionCloudUrl;
    final client = DesktopAuthClient(cloudUrl: cloudUrl);
    try {
      final intent = await client.createIntent();
      final session = await _approveDesktopAuthInBrowser(
        client,
        intent,
        title: 'Confirm your Conclave account',
        description:
            'Open the secure sign-in request in your browser and approve this action with the Workspace owner account.',
      );
      if (session == null) return null;
      await client.validateSession(session);
      if (session.userId != expectedOwnerUserId) {
        await client.revokeSession(session);
        throw StateError('Sign in as the Workspace owner to continue.');
      }
      if (revokeAfterVerification) await client.revokeSession(session);
      return session;
    } finally {
      client.close();
    }
  }

  Future<void> _releaseWorkspaceOwnership() async {
    final lifecycle = widget.lifecycle;
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final registration = HostRegistrationStore(dataDirectory).readSync();
    final dialogContext = _navigatorKey.currentContext;
    if (registration == null || dialogContext == null) return;
    if ((lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      showCopyableMessageSnackBar(
        dialogContext,
        'Wait for active work to finish before releasing Workspace ownership.',
        isError: true,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Release Workspace from this account?'),
        content: const Text(
          'This revokes the runtime credential, disconnects Cloud, and releases the installation owner binding so another Conclave account can connect it. Local Workers, provider credentials, Tool Profiles, and Work Root files remain on this computer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Release Workspace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final authClient = DesktopAuthClient(cloudUrl: registration.cloudUrl);
    try {
      final ownerUserId = registration.ownerUserId;
      if (ownerUserId == null) {
        throw StateError(
            'Verify this Workspace owner by reconnecting before release.');
      }
      DesktopHumanSession? session;
      final storedSessionData =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (storedSessionData != null) {
        try {
          final decoded = jsonDecode(storedSessionData);
          if (decoded is Map) {
            final candidate = DesktopHumanSession.fromSecureJson(
              Map<String, dynamic>.from(decoded),
            );
            await authClient.validateSession(candidate);
            if (candidate.userId != ownerUserId) {
              throw StateError('Sign in as the Workspace owner to release it.');
            }
            final issuedAt = candidate.issuedAt;
            final age = issuedAt == null
                ? null
                : DateTime.now().toUtc().difference(issuedAt.toUtc());
            if (age != null &&
                age >= Duration.zero &&
                age < const Duration(minutes: 4)) {
              session = candidate;
            }
          }
        } on Object {
          // An unavailable or stale session is renewed through browser approval.
        }
      }
      if (session == null) {
        // Cloud requires recent authentication for release. Browser approval
        // refreshes the desktop session without a native password prompt.
        session = await _reauthenticateWorkspaceOwner(
          ownerUserId,
          revokeAfterVerification: false,
        );
        if (session == null) return;
        await lifecycle.host.credentialStore.write(
          desktopHumanCredentialKey,
          jsonEncode(session.toSecureJson()),
        );
      }
      final installationId = registration.installationId ??
          await InstallationIdentityStore(dataDirectory).getOrCreate();
      await authClient.releaseWorkspace(
        session: session,
        installationId: installationId,
        workspaceId: registration.workspaceId,
        runtimeId: registration.hostId,
      );
      await lifecycle.host.credentialStore.delete(registration.hostId);
      await HostRegistrationStore(dataDirectory).clear();
      await LocalWorkspaceIdentityStore(dataDirectory).clear();
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
      ));
      final replacement = await buildWorkspaceRuntime(
        HostConfig.fromArgs(const [],
            credentialStore: lifecycle.host.credentialStore),
        credentialStore: lifecycle.host.credentialStore,
      );
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
              content: Text(
                  'Workspace ownership released. Local Workers and files are preserved.')),
        );
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
            dialogContext, 'Could not release Workspace ownership: $error');
      }
    } finally {
      authClient.close();
    }
  }

  Future<void> _disconnectWorkspace({bool confirmed = false}) async {
    final lifecycle = widget.lifecycle;
    final registration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    if (registration == null) return;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final accepted = confirmed ||
        (await showDialog<bool>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Disconnect Workspace?'),
                content: const Text(
                  'This computer will stop accepting Cloud work.\n\n'
                  'Active assignments will finish before it disconnects.\n\n'
                  'Local Worker credentials, configurations, and Workstream files remain on this machine unless '
                  'you explicitly choose to remove them.\n\n'
                  'You can reconnect to a Workspace at any time.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Disconnect Workspace'),
                  ),
                ],
              ),
            ) ??
            false);
    if (!accepted || !mounted) return;

    DesktopHumanSession? disconnectSession;
    var isTemporarySession = false;
    final authClient = DesktopAuthClient(cloudUrl: registration.cloudUrl);
    try {
      final ownerUserId = registration.ownerUserId;
      if (ownerUserId == null) {
        authClient.close();
        return;
      }
      final storedSessionData =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (storedSessionData != null) {
        try {
          final decoded = jsonDecode(storedSessionData);
          if (decoded is Map) {
            final parsedSession = DesktopHumanSession.fromSecureJson(
              Map<String, dynamic>.from(decoded),
            );
            await authClient.validateSession(parsedSession);
            if (parsedSession.userId == ownerUserId) {
              disconnectSession = parsedSession;
            }
          }
        } on Object {
          // Fall back to browser reauthentication
        }
      }
      if (disconnectSession == null) {
        disconnectSession = await _reauthenticateWorkspaceOwner(
          ownerUserId,
          revokeAfterVerification: false,
        );
        isTemporarySession = true;
        if (disconnectSession == null) {
          authClient.close();
          return;
        }
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
          dialogContext,
          'Could not verify the Workspace owner: $error',
        );
      }
      authClient.close();
      return;
    }

    try {
      final connection = lifecycle.host.cloudConnection;
      final drained = await drainWorkspaceAssignments(
        activeAssignmentCount: () => connection?.activeAssignmentCount ?? 0,
        beginDrain: () => connection?.beginDrain(),
        restoreNewWorkState: () => connection?.resumeNewWork(),
      );
      if (!drained) {
        throw StateError('Active assignments did not finish before timeout.');
      }
      final installationId = registration.installationId ??
          await InstallationIdentityStore(
            lifecycle.host.config.dataDirectory,
          ).getOrCreate();
      await authClient.disconnectWorkspace(
        session: disconnectSession,
        installationId: installationId,
        workspaceId: registration.workspaceId,
        runtimeId: registration.hostId,
      );
      await InstallationIdentityStore(lifecycle.host.config.dataDirectory)
          .authorizeRecovery();
      await lifecycle.host.credentialStore.delete(registration.hostId);
      final preferenceStore = WorkspaceLifecyclePreferencesStore(
        lifecycle.host.config.dataDirectory,
      );
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: preferences.ownerUserId ?? registration.ownerUserId,
        ownerDisplayName: preferences.ownerDisplayName,
        customWorkspaceName:
            preferences.customWorkspaceName ?? registration.name,
      ));
      final replacement = await buildWorkspaceRuntime(
        HostConfig.fromArgs(
          const [],
          credentialStore: lifecycle.host.credentialStore,
          ignoreSavedRegistration: true,
        ),
        credentialStore: lifecycle.host.credentialStore,
      );
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text(
              'Disconnected from Conclave AX. Local Workers and credentials are preserved.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      showCopyableErrorSnackBar(
        dialogContext,
        'Could not disconnect Workspace: $error',
      );
    } finally {
      if (isTemporarySession) {
        try {
          await authClient.revokeSession(disconnectSession);
        } on Object {
          // The temporary owner session expires automatically if revocation fails.
        }
      }
      authClient.close();
    }
  }

  Future<void> _resetLocalWorkspace() async {
    final lifecycle = widget.lifecycle;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    if ((lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      showCopyableMessageSnackBar(
        dialogContext,
        'Wait for active work to finish before resetting.',
        isError: true,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Reset Local Workspace?'),
        content: const Text(
          'Reset removes the local Workspace registration and runtime credential, '
          'local Worker registry entries, desktop sign-in '
          'session, and local runtime identity. It also '
          'disconnects the Cloud runtime when available.\n\n'
          'The persistent installation ID and its account ownership remain, so '
          'another account cannot claim this installation. Work Root metadata, '
          'Work Root contents, launch-at-login, management preferences, and '
          'other local files are kept. To transfer the '
          'installation, use the separate Release Workspace action.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset Local Workspace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final dataDir = lifecycle.host.config.dataDirectory;
      final registration = HostRegistrationStore(dataDir).readSync();
      if (registration != null) {
        final ownerUserId = registration.ownerUserId;
        if (ownerUserId == null) {
          return;
        }
        final resetAuthClient =
            DesktopAuthClient(cloudUrl: registration.cloudUrl);
        final resetSession = await _reauthenticateWorkspaceOwner(
          ownerUserId,
          revokeAfterVerification: false,
        );
        if (resetSession == null) {
          resetAuthClient.close();
          return;
        }
        if (!await _requireStepUp('Reset local Workspace')) return;
        final connection = lifecycle.host.cloudConnection;
        final drained = await drainWorkspaceAssignments(
          activeAssignmentCount: () => connection?.activeAssignmentCount ?? 0,
          beginDrain: () => connection?.beginDrain(),
          restoreNewWorkState: () => connection?.resumeNewWork(),
        );
        if (!drained) {
          throw StateError('Wait for active work to finish before resetting.');
        }
        final installationId = registration.installationId ??
            await InstallationIdentityStore(dataDir).getOrCreate();
        await resetAuthClient.disconnectWorkspace(
          session: resetSession,
          installationId: installationId,
          workspaceId: registration.workspaceId,
          runtimeId: registration.hostId,
        );
        try {
          await resetAuthClient.revokeSession(resetSession);
        } on Object {
          // This one-time session expires automatically if revocation fails.
        }
        resetAuthClient.close();
        await lifecycle.host.credentialStore.delete(registration.hostId);
      } else if (!await _requireStepUp('Reset local Workspace')) {
        return;
      }
      await lifecycle.host.credentialStore.delete(desktopHumanCredentialKey);
      await HostRegistrationStore(dataDir).clear();
      await LocalWorkspaceIdentityStore(dataDir).clear();
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDir);
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(
        WorkspaceLifecyclePreferences.afterLocalWorkspaceReset(preferences),
      );
      final workersFile = File(
          '${dataDir.path}${Platform.pathSeparator}configured-workers.json');
      if (await workersFile.exists()) await workersFile.delete();
      final replacement = await buildWorkspaceRuntime(
        HostConfig.fromArgs(
          const [],
          credentialStore: lifecycle.host.credentialStore,
        ),
        credentialStore: lifecycle.host.credentialStore,
      );
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(content: Text('Local Workspace has been reset.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      showCopyableErrorSnackBar(
        dialogContext,
        'Could not reset Workspace: $error',
      );
    }
  }

  Future<void> _changeWorkRoot(String newPath) async {
    if (!await _requireStepUp('Change the Workspace Work Root')) return;
    final currentHost = widget.lifecycle.host;
    final updatedConfig = HostConfig(
      dataDirectory: currentHost.config.dataDirectory,
      cloudUri: currentHost.config.cloudUri,
      hostId: currentHost.config.hostId,
      installationId: currentHost.config.installationId,
      workspaceId: currentHost.config.workspaceId,
      repositoriesFile: currentHost.config.repositoriesFile,
      authToken: currentHost.config.authToken,
      workRootPath: newPath,
    );
    final replacement = await buildWorkspaceRuntime(
      updatedConfig,
      credentialStore: currentHost.credentialStore,
    );
    await widget.lifecycle.replaceHost(replacement);
    if (mounted) {
      setState(() {});
      final ctx = _navigatorKey.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Work Root changed to: $newPath')),
        );
      }
    }
  }

  Future<DesktopHumanSession?> _restoreDesktopSession(
    DesktopHumanSession session,
  ) async {
    final registration =
        HostRegistrationStore(widget.lifecycle.host.config.dataDirectory)
            .readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    final client = DesktopAuthClient(cloudUrl: cloudUrl);
    try {
      await client.validateSession(session);
      final refreshWindow = DateTime.now().toUtc().add(
            const Duration(days: 5),
          );
      if (session.expiresAt.toUtc().isAfter(refreshWindow)) return session;
      try {
        return await client.rotateSession(session);
      } on Object {
        // Keep a still-valid session usable during transient refresh failures.
        // If Cloud revoked it during the rotation race, the second validation
        // fails and the management shell remains locked.
        await client.validateSession(session);
        return session;
      }
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _changeWorkspaceName(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final lifecycle = widget.lifecycle;
    final preferenceStore = WorkspaceLifecyclePreferencesStore(
      lifecycle.host.config.dataDirectory,
    );
    final preferences = preferenceStore.readSync();
    if (preferences.customWorkspaceName != trimmed) {
      await preferenceStore.write(
        preferences.copyWith(customWorkspaceName: trimmed),
      );
      if (mounted) setState(() {});
    }
  }

  Widget _buildManagementDashboard() {
    final lifecycle = widget.lifecycle;
    return HostDashboard(
      snapshot: lifecycle.uiSnapshot,
      launchAtLogin: _preferences.launchAtLogin,
      onLaunchAtLoginChanged: _setLaunchAtLogin,
      requireStepUp: _requireStepUp,
      onSignIn: _signInDesktopHuman,
      onSignOut: _signOutDesktopHuman,
      onConnect: () => _connectWorkspace(),
      onRegister: _registerWorkspace,
      onRecoverCredential: ([name]) => _connectWorkspace(name: name),
      onChangeWorkspaceName: _changeWorkspaceName,
      onDisconnect: _disconnectWorkspace,
      onRelease: _releaseWorkspaceOwnership,
      onReset: _resetLocalWorkspace,
      onQuit: _confirmQuit,
      onRetry: lifecycle.retryConnection,
      onExportDiagnostics: _exportDiagnostics,
      onChangeWorkRoot: _changeWorkRoot,
      onReadinessCheck: lifecycle.checkWorkerReadiness,
      onRollbackToolProfile: (workerTypeId) async =>
          await lifecycle.host.workerReadinessMonitor
              ?.rollbackToolProfile(workerTypeId) ??
          false,
      workerRevision: _workerRevision,
      localWorkerRegistry: lifecycle.host.localWorkerRegistry,
      credentialStore: lifecycle.host.credentialStore,
      toolProfileReleaseStore: lifecycle.host.toolProfileReleaseStore,
      toolProfileCatalog: lifecycle.host.toolProfileCatalog,
      signedIn: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final lifecycle = widget.lifecycle;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Conclave Workspace',
      debugShowCheckedModeBanner: false,
      theme: ConclaveBrand.lightTheme(),
      darkTheme: ConclaveBrand.darkTheme(),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 400, minHeight: 600),
          child: lifecycle.hidden
              ? const Center(
                  child: Text('Workspace is running in the background.'))
              : WorkspaceShellRouter(
                  snapshot: lifecycle.uiSnapshot,
                  credentialStore: lifecycle.host.credentialStore,
                  cloudUrl: lifecycle.uiSnapshot.cloudUrl ??
                      conclaveProductionCloudUrl,
                  refreshToken: _workerRevision,
                  restoreSession: _restoreDesktopSession,
                  onSignIn: _signInDesktopHuman,
                  onConnectWorkspace: () => _connectWorkspace(),
                  onSignOut: _signOutDesktopHuman,
                  onRelease: _releaseWorkspaceOwnership,
                  onQuit: _confirmQuit,
                  onManagementAuthRequiredChanged:
                      lifecycle.updateManagementAuthRequired,
                  managementShellBuilder: _buildManagementDashboard,
                ),
        ),
      ),
    );
  }
}

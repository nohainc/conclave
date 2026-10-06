part of '../main.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WorkspacePaths.preserveMacWorkRoot();
  const credentialStore = PlatformSecureCredentialStore(
    nativeKeychain: FlutterMacKeychainBridge(),
  );
  final dataDirectory = WorkspaceConfig.resolveDataDirectory(const []);
  final preferencesStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
  final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
  var runtimeCredentialLoaded = false;
  var hasRuntimeCredential = false;
  if (preferencesStore.needsRuntimeCredentialMigrationCheck &&
      registration != null) {
    hasRuntimeCredential = (await credentialStore
                .readForSynchronousConfig(registration.workspaceRuntimeId))
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
    await credentialStore
        .readForSynchronousConfig(registration.workspaceRuntimeId);
  }
  await credentialStore.read(desktopHumanCredentialKey);
  final config = WorkspaceConfig.fromArgs(
    const [],
    credentialStore: credentialStore,
    ignoreSavedRegistration: desiredRuntime == DesiredRuntimeState.disconnected,
  );
  final workspace = await buildWorkspaceRuntime(
    config,
    credentialStore: credentialStore,
  );
  runApp(
      ConclaveWorkspaceApp(lifecycle: WorkspaceLifecycleController(workspace)));
}

class ConclaveWorkspaceApp extends StatefulWidget {
  const ConclaveWorkspaceApp({
    required this.lifecycle,
    this.localAuthenticator = const MethodChannelLocalManagementAuthenticator(),
    super.key,
  });

  final WorkspaceLifecycleController lifecycle;
  final LocalManagementAuthenticator localAuthenticator;

  @override
  State<ConclaveWorkspaceApp> createState() => _ConclaveWorkspaceAppState();
}

class _ConclaveWorkspaceAppState extends State<ConclaveWorkspaceApp>
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
      unawaited(widget.lifecycle.handleSystemResume());
    }
  }

  void _refresh() => setState(() {});

  void _updateState(VoidCallback callback) => setState(callback);

  WorkspaceLifecyclePreferences get _preferences =>
      WorkspaceLifecyclePreferencesStore(
        widget.lifecycle.workspace.config.dataDirectory,
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
      await WorkspaceLifecycleController.setLaunchAtLogin(enabled);
    } catch (e) {
      debugPrint('Could not set launch at login via desktop channel: $e');
    }
    final store = WorkspaceLifecyclePreferencesStore(
      widget.lifecycle.workspace.config.dataDirectory,
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
    final connection = lifecycle.workspace.cloudConnection;
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
        WorkspaceRegistrationStore(lifecycle.workspace.config.dataDirectory)
            .readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_WORKSPACE_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    final client = DesktopAuthClient(cloudUrl: cloudUrl);
    DesktopHumanSession? previousSession;
    var failureContext = 'creating the sign-in request';
    DesktopHumanSession? claimedSession;
    var sessionCommitted = false;
    try {
      final previousRecord = await lifecycle.workspace.credentialStore
          .read(desktopHumanCredentialKey);
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
      WorkspaceRegistration? effectiveRegistration;
      var registrationRepaired = false;
      await persistDesktopHumanSessionAfterPreflight(
        credentialStore: lifecycle.workspace.credentialStore,
        session: session,
        preflight: () async {
          failureContext = 'validating the desktop session';
          await client.validateSession(session);
          // Preflight the installation against the claimed session before
          // replacing the currently stored human session.
          final existingRegistration = WorkspaceRegistrationStore(
            lifecycle.workspace.config.dataDirectory,
          ).readSync();
          effectiveRegistration = existingRegistration;
          WorkspaceOwnership? staleOwnershipForRepair;
          final identityStore = InstallationIdentityStore(
            lifecycle.workspace.config.dataDirectory,
          );
          final installationId =
              existingRegistration?.installationId ?? identityStore.readSync();
          if (installationId != null) {
            failureContext = 'checking Workspace account ownership';
            final ownership = await client.checkWorkspaceOwnership(
              session: session,
              installationId: installationId,
              workspaceId: existingRegistration?.workspaceId,
              runtimeId: existingRegistration?.workspaceRuntimeId,
            );
            String? cloudOwnerUserId;
            switch (ownership.state) {
              case WorkspaceOwnershipState.ownedByCurrentUser:
                if (ownership.ownerMatchesCurrentSession != true ||
                    ownership.ownerUserId != session.userId) {
                  throw StateError(
                    'Cloud could not confirm this account as the Workspace owner.',
                  );
                }
                if (existingRegistration == null ||
                    ownership.workspaceId != existingRegistration.workspaceId ||
                    ownership.workspaceRuntimeId !=
                        existingRegistration.workspaceRuntimeId) {
                  staleOwnershipForRepair = ownership;
                } else {
                  cloudOwnerUserId = ownership.ownerUserId;
                }
                break;
              case WorkspaceOwnershipState.ownedByOtherUser:
                throw StateError(
                  'This Workspace installation is owned by another Conclave account. Sign in as its current owner, disconnect the Workspace if it is connected, and release ownership before switching accounts.',
                );
              case WorkspaceOwnershipState.unbound:
                break;
              case WorkspaceOwnershipState.released:
                if (existingRegistration != null) {
                  throw StateError(
                    'Cloud confirms this Workspace ownership was released, but the local registration is still present. Reset the local Workspace registration before connecting it again.',
                  );
                }
                break;
              case WorkspaceOwnershipState.localRegistrationStale:
                var confirmedOwnership = ownership;
                if (ownership.ownerMatchesCurrentSession != true ||
                    ownership.ownerUserId != session.userId) {
                  final staleRegistration = existingRegistration;
                  if (staleRegistration == null) {
                    throw StateError(
                      'Cloud found a stale Workspace registration without a local identity to verify.',
                    );
                  }
                  failureContext =
                      'reconciling the migrated Workspace ownership';
                  confirmedOwnership = await client.reconcileWorkspaceOwnership(
                    session: session,
                    installationId: installationId,
                    workspaceId: staleRegistration.workspaceId,
                    runtimeId: staleRegistration.workspaceRuntimeId,
                  );
                }
                if (confirmedOwnership.ownerMatchesCurrentSession != true ||
                    confirmedOwnership.ownerUserId != session.userId) {
                  throw StateError(
                    'Cloud could not confirm this account as the owner of the canonical Workspace.',
                  );
                }
                staleOwnershipForRepair = confirmedOwnership;
              case WorkspaceOwnershipState.installationConflict:
                throw StateError(
                  'The local Workspace registration conflicts with its Cloud installation binding. Contact your administrator before continuing.',
                );
              case WorkspaceOwnershipState.corruptOrAmbiguous:
                throw StateError(
                  'Cloud found ambiguous Workspace ownership records. Sign-in was stopped to protect the existing registration.',
                );
            }
            if (previousSession != null &&
                previousSession.userId != session.userId &&
                !await _requireStepUp('Switch the Workspace account')) {
              throw StateError(
                  'Local authentication is required to switch accounts.');
            }
            if (staleOwnershipForRepair != null) {
              final staleRegistration = existingRegistration;
              final ownership = staleOwnershipForRepair;
              final canonicalWorkspaceId = ownership.workspaceId;
              final canonicalOwnerUserId = ownership.ownerUserId;
              if (canonicalWorkspaceId == null ||
                  canonicalOwnerUserId != session.userId) {
                throw StateError(
                  'Cloud found a stale Workspace registration but could not provide its canonical Workspace and owner. Check Cloud ownership before retrying.',
                );
              }
              failureContext = 'repairing the stale Workspace registration';
              final registrationService = WorkspaceRegistrationService(
                dataDirectory: lifecycle.workspace.config.dataDirectory,
                credentialStore: lifecycle.workspace.credentialStore,
              );
              effectiveRegistration = staleRegistration == null
                  ? await registrationService.registerWithDesktopSession(
                      cloudUrl: cloudUrl,
                      desktopCredential: session.credential,
                      expectedOwnerUserId: session.userId,
                      expectedWorkspaceId: canonicalWorkspaceId,
                      facts: SafeMachineFacts.collect(
                        installationId: installationId,
                        name: ownership.workspaceName ?? Platform.localHostname,
                      ),
                    )
                  : await registrationService.recoverStaleRegistration(
                      registration: staleRegistration,
                      desktopCredential: session.credential,
                      expectedOwnerUserId: session.userId,
                      confirmedOwnerUserId: canonicalOwnerUserId!,
                      canonicalWorkspaceId: canonicalWorkspaceId,
                    );
              registrationRepaired = true;
              cloudOwnerUserId = session.userId;
            }
            if (existingRegistration != null && !registrationRepaired) {
              await WorkspaceRegistrationStore(
                lifecycle.workspace.config.dataDirectory,
              ).write(WorkspaceRegistration(
                workspaceRuntimeId: existingRegistration.workspaceRuntimeId,
                workspaceId: existingRegistration.workspaceId,
                cloudUrl: existingRegistration.cloudUrl,
                name: existingRegistration.name,
                hostname: existingRegistration.hostname,
                ownerUserId: cloudOwnerUserId,
                installationId: installationId,
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
        },
      );
      sessionCommitted = true;
      if (previousSession != null &&
          previousSession.sessionId != session.sessionId) {
        try {
          await client.revokeSession(previousSession);
        } on Object {
          // Replacing local state must not fail if the old session already expired.
        }
      }
      final preferenceStore = WorkspaceLifecyclePreferencesStore(
        lifecycle.workspace.config.dataDirectory,
      );
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: effectiveRegistration == null
            ? DesiredRuntimeState.disconnected
            : preferences.desiredRuntime,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
      ));
      Object? restartFailure;
      if (registrationRepaired) {
        try {
          final config = WorkspaceConfig.fromArgs(
            const [],
            credentialStore: lifecycle.workspace.credentialStore,
          );
          await lifecycle.replaceWorkspace(await buildWorkspaceRuntime(
            config,
            credentialStore: lifecycle.workspace.credentialStore,
          ));
        } on Object catch (error) {
          restartFailure = error;
        }
      }
      if (!mounted) return;
      setState(() => _workerRevision++);
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        SnackBar(
          content: Text(restartFailure == null
              ? 'Signed in as ${session.displayName}.'
              : 'Signed in as ${session.displayName}, but the repaired Workspace could not restart: $restartFailure'),
        ),
      );
    } catch (error) {
      if (claimedSession != null && !sessionCommitted) {
        try {
          await client.revokeSession(claimedSession);
        } on Object {
          // A failed ownership check must never replace the stored session.
        }
      }
      if (mounted) {
        showCopyableErrorSnackBar(
          dialogContext,
          '${sessionCommitted ? 'Signed in, but' : 'Sign-in failed while'} $failureContext: $error',
        );
      }
    } finally {
      client.close();
    }
  }

  Future<void> _signOutDesktopHuman() async {
    final lifecycle = widget.lifecycle;
    final registration =
        WorkspaceRegistrationStore(lifecycle.workspace.config.dataDirectory)
            .readSync();
    final desiredRuntime = WorkspaceLifecyclePreferencesStore(
      lifecycle.workspace.config.dataDirectory,
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
            lifecycle.workspace.config.dataDirectory,
          ).readSync().desiredRuntime !=
          DesiredRuntimeState.disconnected) {
        return;
      }
    }
    final stored = await lifecycle.workspace.credentialStore
        .read(desktopHumanCredentialKey);
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
    await lifecycle.workspace.credentialStore.delete(desktopHumanCredentialKey);
    if (mounted) setState(() => _workerRevision++);
  }

  Future<void> _changeWorkRoot(String newPath) async {
    if (!await _requireStepUp('Change the Workspace Work Root')) return;
    final currentWorkspace = widget.lifecycle.workspace;
    final updatedConfig = WorkspaceConfig(
      dataDirectory: currentWorkspace.config.dataDirectory,
      cloudUri: currentWorkspace.config.cloudUri,
      workspaceRuntimeId: currentWorkspace.config.workspaceRuntimeId,
      installationId: currentWorkspace.config.installationId,
      workspaceId: currentWorkspace.config.workspaceId,
      authToken: currentWorkspace.config.authToken,
      workRootPath: newPath,
    );
    final replacement = await buildWorkspaceRuntime(
      updatedConfig,
      credentialStore: currentWorkspace.credentialStore,
    );
    await widget.lifecycle.replaceWorkspace(replacement);
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
    final registration = WorkspaceRegistrationStore(
            widget.lifecycle.workspace.config.dataDirectory)
        .readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_WORKSPACE_CLOUD_URL'] ??
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
      lifecycle.workspace.config.dataDirectory,
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
    return WorkspaceDashboard(
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
          await lifecycle.workspace.workerReadinessMonitor
              ?.rollbackToolProfile(workerTypeId) ??
          false,
      workerRevision: _workerRevision,
      localWorkerRegistry: lifecycle.workspace.localWorkerRegistry,
      credentialStore: lifecycle.workspace.credentialStore,
      workerCatalogCoordinator: lifecycle.workspace.workerCatalogCoordinator,
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
                  credentialStore: lifecycle.workspace.credentialStore,
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

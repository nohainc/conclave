part of '../main.dart';

extension _WorkspaceManagementActions on _ConclaveWorkspaceAppState {
  Future<void> _registerWorkspace([String? name]) async {
    final lifecycle = widget.lifecycle;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final dataDirectory = lifecycle.workspace.config.dataDirectory;
    final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_WORKSPACE_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    try {
      final encoded = await lifecycle.workspace.credentialStore
          .read(desktopHumanCredentialKey);
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
      await WorkspaceRegistrationService(
              dataDirectory: dataDirectory,
              credentialStore: lifecycle.workspace.credentialStore)
          .registerWithDesktopSession(
        cloudUrl: cloudUrl,
        desktopCredential: session.credential,
        facts: facts,
        expectedOwnerUserId: session.userId,
      );
      try {
        await WorkspaceLifecycleController.setLaunchAtLogin(
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
      final config = WorkspaceConfig.fromArgs(
        const [],
        credentialStore: lifecycle.workspace.credentialStore,
        ignoreSavedRegistration: true,
      );
      await lifecycle.replaceWorkspace(await buildWorkspaceRuntime(
        config,
        credentialStore: lifecycle.workspace.credentialStore,
      ));
      if (mounted) {
        _updateState(() => _workerRevision++);
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
    if (lifecycle.workspace.cloudConnection?.isConnected == true ||
        lifecycle.workspace.cloudConnection?.connectionStage ==
            WorkspaceConnectionStage.ready ||
        (lifecycle.workspace.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      showCopyableErrorSnackBar(
        context,
        'Disconnect or let active work finish before connecting this Workspace again.',
      );
      return;
    }
    final dataDirectory = lifecycle.workspace.config.dataDirectory;
    final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
    if (registration == null) {
      await _registerWorkspace(name);
      return;
    }
    final cloudUrl = registration.cloudUrl;
    try {
      final encoded = await lifecycle.workspace.credentialStore
          .read(desktopHumanCredentialKey);
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
        await WorkspaceLifecycleController.setLaunchAtLogin(
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
      final config = WorkspaceConfig.fromArgs(const [],
          credentialStore: lifecycle.workspace.credentialStore);
      await lifecycle.replaceWorkspace(await buildWorkspaceRuntime(config,
          credentialStore: lifecycle.workspace.credentialStore));
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        final connection = lifecycle.workspace.cloudConnection;
        if (connection?.connectionStage == WorkspaceConnectionStage.ready) {
          break;
        }
        if (!lifecycle.running) {
          throw StateError('Workspace runtime stopped before becoming Ready.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (lifecycle.workspace.cloudConnection?.connectionStage !=
          WorkspaceConnectionStage.ready) {
        throw TimeoutException(
          'Workspace did not become Ready within 45 seconds.',
        );
      }
      if (mounted) {
        _updateState(() => _workerRevision++);
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
    final registration = WorkspaceRegistrationStore(
      widget.lifecycle.workspace.config.dataDirectory,
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
    final dataDirectory = lifecycle.workspace.config.dataDirectory;
    final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
    final dialogContext = _navigatorKey.currentContext;
    if (registration == null || dialogContext == null) return;
    if ((lifecycle.workspace.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
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
      final storedSessionData = await lifecycle.workspace.credentialStore
          .read(desktopHumanCredentialKey);
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
        await lifecycle.workspace.credentialStore.write(
          desktopHumanCredentialKey,
          jsonEncode(session.toSecureJson()),
        );
      }
      final installationId = registration.installationId;
      await authClient.releaseWorkspace(
        session: session,
        installationId: installationId,
        workspaceId: registration.workspaceId,
        runtimeId: registration.workspaceRuntimeId,
      );
      await lifecycle.workspace.credentialStore
          .delete(registration.workspaceRuntimeId);
      await WorkspaceRegistrationStore(dataDirectory).clear();
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
        WorkspaceConfig.fromArgs(const [],
            credentialStore: lifecycle.workspace.credentialStore),
        credentialStore: lifecycle.workspace.credentialStore,
      );
      await lifecycle.replaceWorkspace(replacement);
      if (mounted) {
        _updateState(() => _workerRevision++);
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
        WorkspaceRegistrationStore(lifecycle.workspace.config.dataDirectory)
            .readSync();
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
      final storedSessionData = await lifecycle.workspace.credentialStore
          .read(desktopHumanCredentialKey);
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
      final connection = lifecycle.workspace.cloudConnection;
      final drained = await drainWorkspaceAssignments(
        activeAssignmentCount: () => connection?.activeAssignmentCount ?? 0,
        beginDrain: () => connection?.beginDrain(),
        restoreNewWorkState: () => connection?.resumeNewWork(),
      );
      if (!drained) {
        throw StateError('Active assignments did not finish before timeout.');
      }
      final installationId = registration.installationId;
      await authClient.disconnectWorkspace(
        session: disconnectSession,
        installationId: installationId,
        workspaceId: registration.workspaceId,
        runtimeId: registration.workspaceRuntimeId,
      );
      await lifecycle.workspace.credentialStore
          .delete(registration.workspaceRuntimeId);
      final preferenceStore = WorkspaceLifecyclePreferencesStore(
        lifecycle.workspace.config.dataDirectory,
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
        WorkspaceConfig.fromArgs(
          const [],
          credentialStore: lifecycle.workspace.credentialStore,
          ignoreSavedRegistration: true,
        ),
        credentialStore: lifecycle.workspace.credentialStore,
      );
      await lifecycle.replaceWorkspace(replacement);
      if (mounted) {
        _updateState(() => _workerRevision++);
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

    if ((lifecycle.workspace.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
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
      final dataDir = lifecycle.workspace.config.dataDirectory;
      final registration = WorkspaceRegistrationStore(dataDir).readSync();
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
        final connection = lifecycle.workspace.cloudConnection;
        final drained = await drainWorkspaceAssignments(
          activeAssignmentCount: () => connection?.activeAssignmentCount ?? 0,
          beginDrain: () => connection?.beginDrain(),
          restoreNewWorkState: () => connection?.resumeNewWork(),
        );
        if (!drained) {
          throw StateError('Wait for active work to finish before resetting.');
        }
        final installationId = registration.installationId;
        await resetAuthClient.disconnectWorkspace(
          session: resetSession,
          installationId: installationId,
          workspaceId: registration.workspaceId,
          runtimeId: registration.workspaceRuntimeId,
        );
        try {
          await resetAuthClient.revokeSession(resetSession);
        } on Object {
          // This one-time session expires automatically if revocation fails.
        }
        resetAuthClient.close();
        await lifecycle.workspace.credentialStore
            .delete(registration.workspaceRuntimeId);
      } else if (!await _requireStepUp('Reset local Workspace')) {
        return;
      }
      await lifecycle.workspace.credentialStore
          .delete(desktopHumanCredentialKey);
      await WorkspaceRegistrationStore(dataDir).clear();
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
        WorkspaceConfig.fromArgs(
          const [],
          credentialStore: lifecycle.workspace.credentialStore,
        ),
        credentialStore: lifecycle.workspace.credentialStore,
      );
      await lifecycle.replaceWorkspace(replacement);
      if (mounted) {
        _updateState(() => _workerRevision++);
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
}

part of '../main.dart';

bool _hasValidCachedDesktopSession(SecureCredentialStore credentialStore) {
  try {
    final stored = credentialStore.readSync(desktopHumanCredentialKey);
    if (stored == null || stored.isEmpty) return false;
    final decoded = jsonDecode(stored);
    if (decoded is! Map || decoded['credential'] is! String) return false;
    final expiresAt = DateTime.tryParse(decoded['expiresAt']?.toString() ?? '');
    return expiresAt != null && expiresAt.isAfter(DateTime.now().toUtc());
  } on Object {
    return false;
  }
}

String? _readUserEmailFromCredentialStore(
    SecureCredentialStore credentialStore) {
  try {
    final stored = credentialStore.readSync(desktopHumanCredentialKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map) return null;
    final email = decoded['email'];
    return email is String && email.isNotEmpty ? email : null;
  } on Object {
    return null;
  }
}

String _webSocketUpgradeStatus(WorkspaceCloudConnection? connection) {
  if (connection == null) return 'not configured';
  final failureAt = connection.lastWebSocketFailureAt;
  if (failureAt != null &&
      (connection.lastWebSocketUpgradeAt == null ||
          failureAt.isAfter(connection.lastWebSocketUpgradeAt!))) {
    final status = connection.lastWebSocketHttpStatusCode;
    return status == null ? 'failed' : 'failed (HTTP $status)';
  }
  final status = connection.lastHttpStatusCode;
  if (status != null) return 'failed (HTTP $status)';
  if (connection.lastWebSocketUpgradeAt != null) return 'succeeded';
  return 'not completed';
}

Future<bool> drainWorkspaceAssignments({
  required int Function() activeAssignmentCount,
  required void Function() beginDrain,
  required void Function() restoreNewWorkState,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 250),
  DateTime Function()? now,
  Future<void> Function(Duration)? wait,
}) async {
  beginDrain();
  final clock = now ?? DateTime.now;
  final delay = wait ?? Future<void>.delayed;
  final deadline = clock().add(timeout);
  while (activeAssignmentCount() > 0 && clock().isBefore(deadline)) {
    await delay(pollInterval);
  }
  if (activeAssignmentCount() == 0) return true;
  restoreNewWorkState();
  return false;
}

class WorkspaceLifecycleController extends ChangeNotifier {
  WorkspaceLifecycleController(this.workspace) {
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _publishMenuStatus();
      notifyListeners();
    });
  }

  Workspace workspace;
  bool _hidden = false;
  bool _quitting = false;
  Object? _startupError;
  Timer? _statusTimer;
  // Fail closed until the human session has been restored by the shell router.
  bool _managementAuthRequired = true;
  static const _desktopChannel =
      MethodChannel('com.conclave.workspace/desktop');

  static Future<void> setLaunchAtLogin(bool enabled) async {
    if (!Platform.isMacOS) {
      if (enabled) {
        throw UnsupportedError(
          'Launch at login is currently supported only on macOS.',
        );
      }
      return;
    }
    await _desktopChannel.invokeMethod<void>('setLaunchAtLogin', enabled);
  }

  bool get hidden => _hidden;
  bool get quitting => _quitting;
  bool get running => workspace.isRunning;
  Object? get startupError => _startupError;
  bool get acceptingNewWork =>
      workspace.cloudConnection?.acceptingNewWork ?? false;

  void updateManagementAuthRequired(bool required) {
    if (_managementAuthRequired == required) return;
    _managementAuthRequired = required;
    _publishMenuStatus();
  }

  void refreshMenuStatus() {
    _publishMenuStatus();
    notifyListeners();
  }

  Future<void> checkWorkerReadiness({
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
    String? workerTypeId,
  }) async {
    await workspace.workerReadinessMonitor?.checkNow(
      mode: mode,
      workerTypeId: workerTypeId,
    );
    notifyListeners();
  }

  Future<void> handleDesktopAction(String action) async {
    switch (action) {
      case 'openWorkspace':
        restore();
        break;
      case 'pause':
        workspace.cloudConnection?.pauseNewWork();
        break;
      case 'resume':
        workspace.cloudConnection?.resumeNewWork();
        break;
      case 'togglePause':
        final connection = workspace.cloudConnection;
        if (connection?.isDraining == true) break;
        if (connection?.acceptingNewWork == true) {
          connection?.pauseNewWork();
        } else if (connection?.isConnected == true) {
          connection?.resumeNewWork();
        }
        break;
      case 'diagnostics':
        final file = await exportDiagnostics();
        await openPath(file.path);
        break;
      case 'logs':
        await openPath(
            WorkspacePaths(workspace.config.dataDirectory).logsFile.path);
        break;
      case 'openAX':
        await openAX();
        break;
      default:
        return;
    }
    _publishMenuStatus();
    notifyListeners();
  }

  static Future<void> openPath(String path) async {
    try {
      await _desktopChannel.invokeMethod<void>('openPath', path);
    } catch (_) {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      }
    }
  }

  static Future<String?> chooseDirectory({String? initialPath}) async {
    try {
      final result = await _desktopChannel.invokeMethod<String>(
          'chooseDirectory', initialPath);
      if (result != null && result.trim().isNotEmpty) return result.trim();
    } catch (_) {}
    if (Platform.isMacOS) {
      try {
        final script = initialPath != null &&
                Directory(initialPath).existsSync()
            ? 'POSIX path of (choose folder with prompt "Select Work Root Directory" default location POSIX file "$initialPath")'
            : 'POSIX path of (choose folder with prompt "Select Work Root Directory")';
        final result = await Process.run('osascript', ['-e', script]);
        if (result.exitCode == 0) {
          final path = result.stdout.toString().trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    } else if (Platform.isLinux) {
      try {
        final result = await Process.run('zenity', [
          '--file-selection',
          '--directory',
          '--title=Select Work Root Directory'
        ]);
        if (result.exitCode == 0) {
          final path = result.stdout.toString().trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    } else if (Platform.isWindows) {
      try {
        final ps = '''
Add-Type -AssemblyName System.Windows.Forms
\$f = New-Object System.Windows.Forms.FolderBrowserDialog
\$f.Description = "Select Work Root Directory"
if (\$f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { \$f.SelectedPath }
''';
        final result =
            await Process.run('powershell', ['-NoProfile', '-Command', ps]);
        if (result.exitCode == 0) {
          final path = result.stdout.toString().trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<void> openAX([String? url]) async {
    try {
      await _desktopChannel.invokeMethod<void>('openAX');
    } catch (_) {
      final target = url ?? 'https://app.conclaveax.com';
      if (Platform.isMacOS) {
        await Process.run('open', [target]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [target]);
      }
    }
  }

  void _publishMenuStatus() {
    final connection = workspace.cloudConnection;
    final state = startupError != null
        ? 'Attention'
        : connection?.isConnected == true
            ? 'Connected'
            : WorkspaceLifecyclePreferencesStore(workspace.config.dataDirectory)
                        .readSync()
                        .desiredRuntime ==
                    DesiredRuntimeState.connected
                ? 'Connecting'
                : 'Disconnected';
    unawaited(_desktopChannel.invokeMethod<void>('status', {
      'state': state,
      'transportMode': connection?.activeTransportMode ?? 'offline',
      'fallbackHealth': connection?.fallbackHealthStatus ?? 'not configured',
      'lastWebSocketFailure': connection?.lastWebSocketFailure,
      'active': connection?.activeAssignmentCount ?? 0,
      'accepting': connection?.acceptingNewWork ?? false,
      'draining': connection?.isDraining ?? false,
      'managementLocked': WorkspaceLifecyclePreferencesStore(
            workspace.config.dataDirectory,
          ).readSync().managementLockPreference ==
          ManagementLockState.locked,
      'reauthRequired': _managementAuthRequired,
      'runtimeRunning': connection?.isConnected == true,
    }).catchError((_) {}));
  }

  WorkspaceUiSnapshot get uiSnapshot {
    final connection = workspace.cloudConnection;
    final registration =
        WorkspaceRegistrationStore(workspace.config.dataDirectory).readSync();
    final preferences =
        WorkspaceLifecyclePreferencesStore(workspace.config.dataDirectory)
            .readSync();
    final workspaceName = registration?.name ??
        preferences.customWorkspaceName ??
        resolveFriendlyComputerNameSync();
    final workspaceId =
        workspace.config.workspaceId ?? registration?.workspaceId;
    final workspaceRuntimeId =
        workspace.config.workspaceRuntimeId ?? registration?.workspaceRuntimeId;
    final installationId = workspace.installationId ??
        workspace.config.installationId ??
        registration?.installationId ??
        InstallationIdentityStore(workspace.config.dataDirectory).readSync();
    final hostname = registration?.hostname ?? Platform.localHostname;
    final ownerUserId = registration?.ownerUserId;
    final cloudUrl =
        workspace.config.cloudUri?.toString() ?? registration?.cloudUrl;
    final workRootPath =
        workspace.workRoot?.path ?? workspace.config.workRootPath;
    final desiredRuntimeConnected =
        WorkspaceLifecyclePreferencesStore(workspace.config.dataDirectory)
                .readSync()
                .desiredRuntime ==
            DesiredRuntimeState.connected;

    if (quitting) {
      return WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.stopped,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Stopping Workspace',
        detail: 'Stopping the runtime and closing its connection.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        workspaceRuntimeId: workspaceRuntimeId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Stopping',
        connectionStage: connection?.connectionStage,
        connectionError: connection?.lastConnectionError,
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable:
            workspace.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    if (startupError != null) {
      return WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.offline,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect. It will be safe to retry.',
        issue: startupError.toString(),
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        workspaceRuntimeId: workspaceRuntimeId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        registered: workspaceRuntimeId != null && workspaceId != null,
        ownerUserId: ownerUserId,
        workspaceReady:
            connection?.connectionStage == WorkspaceConnectionStage.ready,
        // A saved token can be present and still be revoked in Cloud. The
        // Account section can recover it through the human management API.
        statusLabel: 'Offline',
        logsPath:
            WorkspacePaths(workspace.config.dataDirectory).logsDirectory.path,
        connectionStage: connection?.connectionStage,
        connectionError:
            connection?.lastConnectionError ?? startupError.toString(),
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable:
            workspace.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    if (workspace.config.workspaceRuntimeId == null) {
      final isRegistered = registration != null;
      return WorkspaceUiSnapshot(
        mode: isRegistered
            ? WorkspaceUiMode.offline
            : WorkspaceUiMode.firstLaunch,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: isRegistered ? 'Workspace is offline' : 'Connect this Workspace',
        detail: isRegistered
            ? 'The Workspace is registered and ready to connect.'
            : 'Sign in to register this computer with Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        workspaceRuntimeId: workspaceRuntimeId,
        registered: isRegistered,
        ownerUserId: ownerUserId,
        installationId: installationId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: isRegistered ? 'Offline' : 'Not registered',
        connectionStage: connection?.connectionStage,
        runtimeCredentialAvailable:
            workspace.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
      );
    }
    if (!running) {
      return WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.starting,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Starting Workspace',
        detail: 'Checking this machine and reconnecting to Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        workspaceRuntimeId: workspaceRuntimeId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Starting',
        connectionStage: connection?.connectionStage,
        connectionError: connection?.lastConnectionError,
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable:
            workspace.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    final activeAssignments = connection?.activeAssignmentCount ?? 0;
    final isConnected = connection?.isConnected ?? false;
    final stage = connection?.connectionStage;
    final isConnecting = stage == WorkspaceConnectionStage.validating ||
        stage == WorkspaceConnectionStage.connecting ||
        stage == WorkspaceConnectionStage.authenticating ||
        stage == WorkspaceConnectionStage.synchronizing ||
        stage == WorkspaceConnectionStage.reconnecting ||
        stage == WorkspaceConnectionStage.switchingToWebSocket;
    final isOffline = !isConnected && !isConnecting;
    final statusLabel = isConnecting
        ? (stage == WorkspaceConnectionStage.reconnecting
            ? 'Reconnecting'
            : stage == WorkspaceConnectionStage.switchingToWebSocket
                ? 'Switching to WebSocket'
                : 'Connecting')
        : isOffline
            ? 'Offline'
            : (connection?.isDraining ?? false)
                ? 'Draining'
                : !(connection?.acceptingNewWork ?? true)
                    ? 'Paused'
                    : 'Connected';

    return WorkspaceUiSnapshot(
      mode: isConnecting
          ? WorkspaceUiMode.starting
          : isOffline
              ? WorkspaceUiMode.offline
              : activeAssignments > 0
                  ? WorkspaceUiMode.active
                  : WorkspaceUiMode.ready,
      desiredRuntimeConnected: desiredRuntimeConnected,
      title: isConnecting
          ? 'Connecting Workspace'
          : isOffline
              ? 'Workspace is offline'
              : activeAssignments > 0
                  ? 'Work in progress'
                  : 'Workspace is ready',
      detail: isConnecting
          ? 'Checking this machine and connecting to Conclave.'
          : isOffline
              ? activeAssignments > 0
                  ? 'Cloud is disconnected. Active work remains on this computer while the Workspace retries.'
                  : 'The Workspace is registered, but Cloud has not authenticated this connection.'
              : activeAssignments > 0
                  ? 'The Workspace is running assigned work.'
                  : 'This computer is registered and ready to run assigned work.',
      issue: isConnecting
          ? null
          : isOffline
              ? (connection?.lastConnectionError ??
                  'No authenticated Cloud session. Recover the Workspace connection from Account.')
              : null,
      workspaceName: workspaceName,
      workspaceId: workspaceId,
      installationId: installationId,
      workspaceRuntimeId: workspaceRuntimeId,
      hostname: hostname,
      cloudUrl: cloudUrl,
      workRootPath: workRootPath,
      registered: true,
      ownerUserId: ownerUserId,
      workspaceReady:
          connection?.connectionStage == WorkspaceConnectionStage.ready,
      cloudConnected: isConnected,
      statusLabel: statusLabel,
      logsPath: WorkspacePaths(workspace.config.dataDirectory).logsFile.path,
      activeAssignments: activeAssignments,
      activeAssignmentIds: connection?.activeAssignmentIds ?? const [],
      reconnectCount: connection?.reconnectCount ?? 0,
      sessionId: connection?.sessionId,
      lastInventorySyncAt: connection?.lastInventorySyncAt,
      connectionStage: connection?.connectionStage,
      connectionError: connection?.lastConnectionError,
      connectionHttpStatus: connection?.lastHttpStatusCode,
      runtimeCredentialAvailable:
          workspace.config.authToken?.isNotEmpty == true,
      protocolHelloStatus: connection?.protocolHelloStatus,
      dnsTlsStatus: connection?.lastDnsTlsStatus,
      webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
      activeTransportMode: connection?.activeTransportMode,
      fallbackHealthStatus: connection?.fallbackHealthStatus,
      lastWebSocketFailure: connection?.lastWebSocketFailure,
      lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
      lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
      lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
    );
  }

  Future<void> launch() async {
    _startupError = null;
    try {
      await workspace.start();
    } catch (error) {
      _startupError = error;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> retryConnection() async {
    final connection = workspace.cloudConnection;
    if (!running || connection == null) {
      await launch();
      return;
    }
    _startupError = null;
    try {
      await connection.retryNow();
    } catch (error) {
      _startupError = error;
    }
    notifyListeners();
  }

  Future<void> replaceWorkspace(Workspace nextWorkspace) async {
    await workspace.stop();
    workspace = nextWorkspace;
    _startupError = null;
    _hidden = false;
    notifyListeners();
    await launch();
  }

  void minimize() {
    if (_quitting) return;
    _hidden = true;
    notifyListeners();
  }

  void restore() {
    if (_quitting) return;
    _hidden = false;
    notifyListeners();
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    _statusTimer?.cancel();
    notifyListeners();
    await workspace.stop();
    notifyListeners();
  }

  Future<File> exportDiagnostics() async {
    final status = await workspace.statusProvider?.call() ?? const {};
    final update = await workspace.updateStatusProvider?.call() ?? const {};
    final checkAt =
        DateTime.tryParse(status['lastUpdateCheckAt'] as String? ?? '');
    return writeWorkspaceDiagnostics(
      config: workspace.config,
      connection: workspace.cloudConnection,
      journal: workspace.cloudConnection?.assignmentJournal,
      workerRegistry: workspace.localWorkerRegistry,
      toolProfileReleaseStore: workspace.toolProfileReleaseStore,
      lastUpdateCheckStatus: status['lastUpdateCheckStatus'] as String?,
      lastUpdateCheckAt: checkAt,
      updateStatus: update['phase'] as String?,
      workRootPath: workspace.workRoot?.path,
    );
  }
}

enum WorkspaceUiMode {
  firstLaunch,
  starting,
  ready,
  authNeeded,
  active,
  offline,
  installFailure,
  stopped,
}

class WorkspaceUiSnapshot {
  const WorkspaceUiSnapshot({
    required this.mode,
    required this.title,
    required this.detail,
    this.workspaceName,
    this.workspaceId,
    this.installationId,
    this.workspaceRuntimeId,
    this.hostname,
    this.cloudUrl,
    this.workRootPath,
    this.statusLabel = 'Offline',
    this.registered = false,
    this.ownerUserId,
    this.desiredRuntimeConnected = false,
    this.workspaceReady = false,
    this.cloudConnected = false,
    this.accountsNeedingAction = const [],
    this.workerSummary = 'Worker diagnostics are available after sign-in',
    this.logsPath,
    this.updateSummary = 'Up to date',
    this.activeAssignments = 0,
    this.activeAssignmentIds = const [],
    this.reconnectCount = 0,
    this.sessionId,
    this.lastInventorySyncAt,
    this.connectionStage,
    this.connectionError,
    this.connectionHttpStatus,
    this.runtimeCredentialAvailable = false,
    this.protocolHelloStatus,
    this.dnsTlsStatus,
    this.webSocketUpgradeStatus,
    this.activeTransportMode,
    this.fallbackHealthStatus,
    this.lastWebSocketFailure,
    this.lastWebSocketHttpStatusCode,
    this.lastWebSocketFailureAt,
    this.lastConnectionAttemptAt,
    this.appVersion = conclaveWorkspaceAppVersion,
    this.issue,
  });

  final WorkspaceUiMode mode;
  final String title;
  final String detail;
  final String? workspaceName;
  final String? workspaceId;
  final String? installationId;
  final String? workspaceRuntimeId;
  final String? hostname;
  final String? cloudUrl;
  final String? workRootPath;
  final String statusLabel;
  final bool registered;
  final String? ownerUserId;
  final bool desiredRuntimeConnected;
  final bool workspaceReady;
  final bool cloudConnected;
  final List<String> accountsNeedingAction;
  final String workerSummary;
  final String? logsPath;
  final String updateSummary;
  final int activeAssignments;
  final List<String> activeAssignmentIds;
  final int reconnectCount;
  final String? sessionId;
  final DateTime? lastInventorySyncAt;
  final WorkspaceConnectionStage? connectionStage;
  final String? connectionError;
  final int? connectionHttpStatus;
  final bool runtimeCredentialAvailable;
  final String? protocolHelloStatus;
  final String? dnsTlsStatus;
  final String? webSocketUpgradeStatus;
  final String? activeTransportMode;
  final String? fallbackHealthStatus;
  final String? lastWebSocketFailure;
  final int? lastWebSocketHttpStatusCode;
  final DateTime? lastWebSocketFailureAt;
  final DateTime? lastConnectionAttemptAt;
  final String appVersion;
  final String? issue;

  String get runtimeCredentialStatus => runtimeCredentialAvailable
      ? 'Available locally (value hidden)'
      : desiredRuntimeConnected
          ? 'Missing from secure storage'
          : 'Not needed while Workspace is disconnected';

  bool get hasLocalAction =>
      accountsNeedingAction.isNotEmpty ||
      mode == WorkspaceUiMode.authNeeded ||
      mode == WorkspaceUiMode.installFailure;
}

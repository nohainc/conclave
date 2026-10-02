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

String _webSocketUpgradeStatus(HostCloudConnection? connection) {
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

class HostLifecycleController extends ChangeNotifier {
  HostLifecycleController(this.host) {
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _publishMenuStatus();
      notifyListeners();
    });
  }

  Host host;
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
  bool get running => host.isRunning;
  Object? get startupError => _startupError;
  bool get acceptingNewWork => host.cloudConnection?.acceptingNewWork ?? false;

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
    await host.workerReadinessMonitor?.checkNow(
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
        host.cloudConnection?.pauseNewWork();
        break;
      case 'resume':
        host.cloudConnection?.resumeNewWork();
        break;
      case 'togglePause':
        final connection = host.cloudConnection;
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
        await openPath(WorkspacePaths(host.config.dataDirectory).logsFile.path);
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
    final connection = host.cloudConnection;
    final state = startupError != null
        ? 'Attention'
        : connection?.isConnected == true
            ? 'Connected'
            : WorkspaceLifecyclePreferencesStore(host.config.dataDirectory)
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
            host.config.dataDirectory,
          ).readSync().managementLockPreference ==
          ManagementLockState.locked,
      'reauthRequired': _managementAuthRequired,
      'runtimeRunning': connection?.isConnected == true,
    }).catchError((_) {}));
  }

  HostUiSnapshot get uiSnapshot {
    final connection = host.cloudConnection;
    final registration =
        HostRegistrationStore(host.config.dataDirectory).readSync();
    final preferences =
        WorkspaceLifecyclePreferencesStore(host.config.dataDirectory)
            .readSync();
    final workspaceName = registration?.name ??
        preferences.customWorkspaceName ??
        resolveFriendlyComputerNameSync();
    final workspaceId = host.config.workspaceId ?? registration?.workspaceId;
    final hostId = host.config.hostId ?? registration?.hostId;
    final installationId = host.installationId ??
        host.config.installationId ??
        registration?.installationId ??
        InstallationIdentityStore(host.config.dataDirectory).readSync();
    final hostname = registration?.hostname ?? Platform.localHostname;
    final ownerUserId = registration?.ownerUserId;
    final cloudUrl = host.config.cloudUri?.toString() ?? registration?.cloudUrl;
    final workRootPath = host.workRoot?.path ?? host.config.workRootPath;
    final desiredRuntimeConnected =
        WorkspaceLifecyclePreferencesStore(host.config.dataDirectory)
                .readSync()
                .desiredRuntime ==
            DesiredRuntimeState.connected;

    if (quitting) {
      return HostUiSnapshot(
        mode: HostUiMode.stopped,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Stopping Workspace',
        detail: 'Stopping the runtime and closing its connection.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Stopping',
        connectionStage: connection?.connectionStage,
        connectionError: connection?.lastConnectionError,
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
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
      return HostUiSnapshot(
        mode: HostUiMode.offline,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect. It will be safe to retry.',
        issue: startupError.toString(),
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        paired: hostId != null && workspaceId != null,
        ownerUserId: ownerUserId,
        workspaceReady:
            connection?.connectionStage == HostConnectionStage.ready,
        // A saved token can be present and still be revoked in Cloud. The
        // Account section can recover it through the human management API.
        statusLabel: 'Offline',
        logsPath: WorkspacePaths(host.config.dataDirectory).logsDirectory.path,
        connectionStage: connection?.connectionStage,
        connectionError:
            connection?.lastConnectionError ?? startupError.toString(),
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
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
    if (host.config.hostId == null) {
      final isPaired = registration != null;
      return HostUiSnapshot(
        mode: isPaired ? HostUiMode.offline : HostUiMode.firstLaunch,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: isPaired ? 'Workspace is offline' : 'Connect this Workspace',
        detail: isPaired
            ? 'The Workspace is registered and ready to connect.'
            : 'Sign in to register this computer with Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        hostId: hostId,
        paired: isPaired,
        ownerUserId: ownerUserId,
        installationId: installationId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: isPaired ? 'Offline' : 'Not paired',
        connectionStage: connection?.connectionStage,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
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
      return HostUiSnapshot(
        mode: HostUiMode.starting,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Starting Workspace',
        detail: 'Checking this machine and reconnecting to Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Starting',
        connectionStage: connection?.connectionStage,
        connectionError: connection?.lastConnectionError,
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
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
    final isConnecting = stage == HostConnectionStage.validating ||
        stage == HostConnectionStage.connecting ||
        stage == HostConnectionStage.authenticating ||
        stage == HostConnectionStage.synchronizing ||
        stage == HostConnectionStage.reconnecting ||
        stage == HostConnectionStage.switchingToWebSocket;
    final isOffline = !isConnected && !isConnecting;
    final statusLabel = isConnecting
        ? (stage == HostConnectionStage.reconnecting
            ? 'Reconnecting'
            : stage == HostConnectionStage.switchingToWebSocket
                ? 'Switching to WebSocket'
                : 'Connecting')
        : isOffline
            ? 'Offline'
            : (connection?.isDraining ?? false)
                ? 'Draining'
                : !(connection?.acceptingNewWork ?? true)
                    ? 'Paused'
                    : 'Connected';

    return HostUiSnapshot(
      mode: isConnecting
          ? HostUiMode.starting
          : isOffline
              ? HostUiMode.offline
              : activeAssignments > 0
                  ? HostUiMode.active
                  : HostUiMode.ready,
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
      hostId: hostId,
      hostname: hostname,
      cloudUrl: cloudUrl,
      workRootPath: workRootPath,
      paired: true,
      ownerUserId: ownerUserId,
      workspaceReady: connection?.connectionStage == HostConnectionStage.ready,
      cloudConnected: isConnected,
      statusLabel: statusLabel,
      logsPath: WorkspacePaths(host.config.dataDirectory).logsFile.path,
      activeAssignments: activeAssignments,
      activeAssignmentIds: connection?.activeAssignmentIds ?? const [],
      reconnectCount: connection?.reconnectCount ?? 0,
      sessionId: connection?.sessionId,
      lastInventorySyncAt: connection?.lastInventorySyncAt,
      connectionStage: connection?.connectionStage,
      connectionError: connection?.lastConnectionError,
      connectionHttpStatus: connection?.lastHttpStatusCode,
      runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
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
      await host.start();
    } catch (error) {
      _startupError = error;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> retryConnection() async {
    final connection = host.cloudConnection;
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

  Future<void> replaceHost(Host nextHost) async {
    await host.stop();
    host = nextHost;
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
    await host.stop();
    notifyListeners();
  }

  Future<File> exportDiagnostics() async {
    final status = await host.statusProvider?.call() ?? const {};
    final update = await host.updateStatusProvider?.call() ?? const {};
    final checkAt =
        DateTime.tryParse(status['lastUpdateCheckAt'] as String? ?? '');
    return writeHostDiagnostics(
      config: host.config,
      connection: host.cloudConnection,
      journal: host.cloudConnection?.assignmentJournal,
      workerRegistry: host.localWorkerRegistry,
      toolProfileReleaseStore: host.toolProfileReleaseStore,
      lastUpdateCheckStatus: status['lastUpdateCheckStatus'] as String?,
      lastUpdateCheckAt: checkAt,
      updateStatus: update['phase'] as String?,
      workRootPath: host.workRoot?.path,
    );
  }
}

enum HostUiMode {
  firstLaunch,
  starting,
  ready,
  authNeeded,
  active,
  offline,
  installFailure,
  stopped,
}

class HostUiSnapshot {
  const HostUiSnapshot({
    required this.mode,
    required this.title,
    required this.detail,
    this.workspaceName,
    this.workspaceId,
    this.installationId,
    this.hostId,
    this.hostname,
    this.cloudUrl,
    this.workRootPath,
    this.statusLabel = 'Offline',
    this.paired = false,
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

  final HostUiMode mode;
  final String title;
  final String detail;
  final String? workspaceName;
  final String? workspaceId;
  final String? installationId;
  final String? hostId;
  final String? hostname;
  final String? cloudUrl;
  final String? workRootPath;
  final String statusLabel;
  final bool paired;
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
  final HostConnectionStage? connectionStage;
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
      mode == HostUiMode.authNeeded ||
      mode == HostUiMode.installFailure;
}

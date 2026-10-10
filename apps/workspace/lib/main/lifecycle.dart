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

class WorkspaceLifecycleController extends ChangeNotifier {
  WorkspaceLifecycleController(
    this.config, {
    required this.credentialStore,
    Map<String, Object?>? initialManagerSnapshot,
  }) {
    if (initialManagerSnapshot != null) {
      _managerSnapshot = initialManagerSnapshot;
      _managerConnected = true;
    }
    _managerRetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_closed && !_managerConnected) unawaited(_connectToManager());
    });
  }

  final WorkspaceConfig config;
  final SecureCredentialStore credentialStore;
  bool _hidden = false;
  bool _quitting = false;
  Object? _startupError;
  Timer? _managerRetryTimer;
  WorkspaceManagerIpcConnection? _manager;
  StreamSubscription<Map<String, Object?>>? _managerEvents;
  Map<String, Object?> _managerSnapshot = const {};
  bool _managerConnected = false;
  bool _closed = false;
  late final IpcWorkspaceWorkerCatalog workerCatalog =
      IpcWorkspaceWorkerCatalog(
          (command, {payload = const {}}) => request(
                command,
                payload: payload,
              ),
          cacheFile: File(
            '${config.dataDirectory.path}/runtime/manager-worker-display.json',
          ));
  // Fail closed until the human session has been restored by the shell router.
  bool _managementAuthRequired = true;
  static const _desktopChannel =
      MethodChannel('com.conclave.workspace/desktop');
  static const WorkspaceServiceManager _serviceManager =
      MethodChannelWorkspaceServiceManager();

  static Future<WorkspaceBackgroundServiceStatus>
      getBackgroundServiceStatus() async {
    return _serviceManager.status();
  }

  static Future<WorkspaceBackgroundServiceStatus>
      registerBackgroundService() async {
    return _serviceManager.register();
  }

  static Future<WorkspaceBackgroundServiceStatus>
      unregisterBackgroundService() async {
    return _serviceManager.unregister();
  }

  static Future<void> openLoginItemsSettings() async {
    await _serviceManager.openSettings();
  }

  Future<void> changeWorkRoot(String path) async {
    if (_managerConnected) {
      throw StateError('Stop the service before changing Work Root.');
    }
    final installationId = config.installationId ??
        WorkspaceRegistrationStore(config.dataDirectory)
            .readSync()
            ?.installationId ??
        InstallationIdentityStore(config.dataDirectory).readSync();
    await StoppedWorkspaceConfiguration(config.dataDirectory,
            installationId: installationId)
        .setWorkRoot(path);
    notifyListeners();
  }

  Future<void> ensureBackgroundService() async {
    var status = await _serviceManager.status();
    if (!status.supported) {
      throw UnsupportedError(
        'Background service management is unavailable on this platform.',
      );
    }
    await _connectToManager();
    if (_managerConnected) return;
    // The host refreshes stale/stopped registrations, never a running job.
    status = await _serviceManager.register();
    if (status.registration ==
        WorkspaceBackgroundServiceRegistration.approvalRequired) {
      throw StateError(
          'Approve Conclave Workspace in System Settings → General → Login Items, then start the service again.');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!_managerConnected && DateTime.now().isBefore(deadline)) {
      await _connectToManager();
      if (!_managerConnected) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (!_managerConnected) {
      throw TimeoutException(
        'Background service was registered but did not start.',
      );
    }
  }

  bool get hidden => _hidden;
  bool get quitting => _quitting;
  bool get running =>
      _managerConnected &&
      (_managerSnapshot['service'] is Map
          ? ((_managerSnapshot['service'] as Map)['processState'] == 'ready')
          : true);
  Object? get startupError => _startupError;
  bool get acceptingNewWork {
    final cloud = _managerSnapshot['cloud'];
    return cloud is Map && cloud['acceptingNewWork'] == true;
  }

  int get activeAssignmentCount {
    final assignments = _managerSnapshot['assignments'];
    return assignments is Map && assignments['activeCount'] is int
        ? assignments['activeCount'] as int
        : 0;
  }

  Future<Object?> request(
    String command, {
    Map<String, Object?> payload = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final manager = _manager;
    if (!_managerConnected || manager == null) {
      throw const SocketException('Workspace service is not connected.');
    }
    final result =
        await manager.request(command, payload: payload, timeout: timeout);
    if (result is Map && result['service'] is Map) {
      _acceptSnapshot(Map<String, Object?>.from(result));
    }
    return result;
  }

  Future<void> _connectToManager() async {
    if (_closed || _managerConnected) return;
    if (_manager != null) return;
    final runtimeDirectory =
        WorkspacePaths(config.dataDirectory).runtimeDirectory;
    final keyFile = File('${runtimeDirectory.path}/manager-ipc.key');
    try {
      final key = (await keyFile.readAsString()).trim();
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
        throw StateError('Workspace service IPC key is invalid.');
      }
      final connection = WorkspaceManagerIpcConnection(
        socketPath: '${runtimeDirectory.path}/manager.sock',
        key: key,
      );
      _manager = connection;
      _managerEvents = connection.events.listen(_handleManagerEvent);
      await connection.connect();
      if (_closed) {
        await connection.close();
        _manager = null;
        return;
      }
      _managerConnected = true;
      _startupError = null;
      _acceptSnapshot(connection.initialSnapshot);
      notifyListeners();
    } on Object catch (error) {
      _managerConnected = false;
      _startupError = error;
      notifyListeners();
    }
  }

  void _handleManagerEvent(Map<String, Object?> event) {
    switch (event['name']) {
      case 'ipc.connectionChanged':
        _managerConnected = event['connected'] == true;
        if (!_managerConnected) {
          _startupError = 'Workspace service disconnected.';
          _managerSnapshot = const {};
        }
        break;
      case 'ipc.snapshot':
        final snapshot = event['snapshot'];
        if (snapshot is Map) {
          _acceptSnapshot(Map<String, Object?>.from(snapshot));
        }
        _managerConnected = true;
        _startupError = null;
        break;
      case 'service.statusChanged':
        final snapshot = event['snapshot'];
        if (snapshot is Map) {
          _acceptSnapshot(Map<String, Object?>.from(snapshot));
        }
        break;
      case 'cloud.connectionChanged':
        _managerSnapshot = {
          ..._managerSnapshot,
          'cloud': event['cloud'] ?? _managerSnapshot['cloud'],
        };
        break;
      case 'worker.inventoryChanged':
        _managerSnapshot = {
          ..._managerSnapshot,
          'workers': event['workers'] ?? _managerSnapshot['workers'],
        };
        final workerCatalog = _managerSnapshot['workerCatalog'];
        if (workerCatalog is Map) {
          this
              .workerCatalog
              .acceptSnapshot(Map<String, Object?>.from(workerCatalog));
        }
        break;
      case 'worker.catalogChanged':
        final workerCatalog = event['workerCatalog'];
        if (workerCatalog is Map) {
          this
              .workerCatalog
              .acceptSnapshot(Map<String, Object?>.from(workerCatalog));
        }
        break;
    }
    _publishMenuStatus();
    notifyListeners();
  }

  void _acceptSnapshot(Map<String, Object?> snapshot) {
    _managerSnapshot = snapshot;
    final workerCatalogSnapshot = snapshot['workerCatalog'];
    if (workerCatalogSnapshot is Map) {
      workerCatalog
          .acceptSnapshot(Map<String, Object?>.from(workerCatalogSnapshot));
    }
    _managerConnected = true;
    _startupError = null;
    _publishMenuStatus();
  }

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
    await request('workers.checkReadiness',
        timeout: const Duration(minutes: 2),
        payload: {
          'mode': mode.name,
          if (workerTypeId != null) 'workerTypeId': workerTypeId,
        });
  }

  /// Reattach to local IPC after wake; the service owns Cloud recovery.
  Future<void> handleSystemResume() async {
    if (!_managerConnected) await _connectToManager();
  }

  Future<void> handleDesktopAction(String action) async {
    switch (action) {
      case 'openWorkspace':
        restore();
        break;
      case 'pause':
        await request('connection.pause');
        break;
      case 'resume':
        await request('connection.resume');
        break;
      case 'togglePause':
        await request(
            acceptingNewWork ? 'connection.pause' : 'connection.resume');
        break;
      case 'diagnostics':
        final result = await request('diagnostics.getDiagnostics');
        if (result is Map && result['path'] is String) {
          await openPath(result['path'] as String);
        }
        break;
      case 'logs':
        final path = WorkspacePaths(config.dataDirectory).logsFile.path;
        await openPath(path);
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
    final cloud = _managerSnapshot['cloud'];
    final assignments = _managerSnapshot['assignments'];
    final cloudMap = cloud is Map ? cloud : const <String, Object?>{};
    final assignmentMap =
        assignments is Map ? assignments : const <String, Object?>{};
    final state = startupError != null
        ? 'Attention'
        : cloudMap['connected'] == true
            ? 'Connected'
            : WorkspaceLifecyclePreferencesStore(config.dataDirectory)
                        .readSync()
                        .desiredRuntime ==
                    DesiredRuntimeState.connected
                ? 'Connecting'
                : 'Disconnected';
    unawaited(_desktopChannel.invokeMethod<void>('status', {
      'state': state,
      'transportMode': cloudMap['transport'] ?? 'offline',
      'fallbackHealth': 'service managed',
      'active': assignmentMap['activeCount'] ?? 0,
      'accepting': cloudMap['acceptingNewWork'] == true,
      'draining': false,
      'managementLocked': WorkspaceLifecyclePreferencesStore(
            config.dataDirectory,
          ).readSync().managementLockPreference ==
          ManagementLockState.locked,
      'reauthRequired': _managementAuthRequired,
      'runtimeRunning': cloudMap['connected'] == true,
      'serviceRunning': running,
    }).catchError((_) {}));
  }

  WorkspaceUiSnapshot get _ipcUiSnapshot {
    final registration =
        WorkspaceRegistrationStore(config.dataDirectory).readSync();
    final preferences =
        WorkspaceLifecyclePreferencesStore(config.dataDirectory).readSync();
    final service = _managerSnapshot['service'];
    final cloud = _managerSnapshot['cloud'];
    final workspaceState = _managerSnapshot['workspace'];
    final assignments = _managerSnapshot['assignments'];
    final serviceMap = service is Map ? service : const <String, Object?>{};
    final cloudMap = cloud is Map ? cloud : const <String, Object?>{};
    final workspaceMap =
        workspaceState is Map ? workspaceState : const <String, Object?>{};
    final assignmentsMap =
        assignments is Map ? assignments : const <String, Object?>{};
    final processState = serviceMap['processState']?.toString();
    final cloudState = running ? cloudMap['state']?.toString() : null;
    final stage = switch (cloudState) {
      'connecting' => WorkspaceConnectionStage.connecting,
      'reconnecting' => WorkspaceConnectionStage.reconnecting,
      'connected' => WorkspaceConnectionStage.ready,
      _ => WorkspaceConnectionStage.offline,
    };
    final activeCount = assignmentsMap['activeCount'] is int
        ? assignmentsMap['activeCount'] as int
        : 0;
    final connected = running && cloudMap['connected'] == true;
    final desired = preferences.desiredRuntime == DesiredRuntimeState.connected;
    final registrationPresent = registration != null;
    final runtimeId = workspaceMap['workspaceRuntimeId']?.toString() ??
        registration?.workspaceRuntimeId;
    final workspaceId =
        workspaceMap['workspaceId']?.toString() ?? registration?.workspaceId;
    final workspaceName = preferences.customWorkspaceName ??
        workspaceMap['name']?.toString() ??
        registration?.name ??
        resolveFriendlyComputerNameSync();
    final error = cloudMap['lastError']?.toString();
    final mode = !_managerConnected || processState == 'stopped'
        ? WorkspaceUiMode.offline
        : !registrationPresent
            ? WorkspaceUiMode.firstLaunch
            : stage == WorkspaceConnectionStage.connecting ||
                    stage == WorkspaceConnectionStage.reconnecting
                ? WorkspaceUiMode.starting
                : activeCount > 0
                    ? WorkspaceUiMode.active
                    : connected
                        ? WorkspaceUiMode.ready
                        : WorkspaceUiMode.offline;
    final status = !_managerConnected
        ? 'Service unavailable'
        : connected
            ? (cloudMap['acceptingNewWork'] == true ? 'Connected' : 'Paused')
            : cloudState == 'connecting'
                ? 'Connecting'
                : cloudState == 'reconnecting'
                    ? 'Reconnecting'
                    : cloudState == 'authenticationRequired'
                        ? 'Authentication required'
                        : 'Offline';
    return WorkspaceUiSnapshot(
      mode: mode,
      desiredRuntimeConnected: desired,
      title: !_managerConnected
          ? 'Workspace Service is unavailable'
          : !registrationPresent
              ? 'Register this Workspace'
              : connected
                  ? (activeCount > 0
                      ? 'Work in progress'
                      : 'Workspace is ready')
                  : 'Workspace is offline',
      detail: !_managerConnected
          ? 'Start the background service to manage this Workspace.'
          : !registrationPresent
              ? 'Sign in to register this computer with Conclave.'
              : connected
                  ? (activeCount > 0
                      ? 'The background service is running assigned work.'
                      : 'This computer is registered and ready to run assigned work.')
                  : 'The background service is running, but Cloud is disconnected.',
      issue: !_managerConnected ? _startupError?.toString() : error,
      workspaceName: workspaceName,
      workspaceId: workspaceId,
      installationId:
          serviceMap['installationId']?.toString() ?? config.installationId,
      workspaceRuntimeId: runtimeId,
      hostname: registration?.hostname ?? Platform.localHostname,
      cloudUrl: workspaceMap['cloudUrl']?.toString() ?? registration?.cloudUrl,
      workRootPath: running
          ? workspaceMap['workRoot']?.toString() ?? config.workRootPath
          : preferences.workRootPath ??
              config.workRootPath ??
              WorkRootResolver().defaultPath,
      registered: registrationPresent || workspaceId != null,
      ownerUserId: registration?.ownerUserId,
      workspaceReady: connected,
      serviceRunning: running,
      cloudConnected: connected,
      statusLabel: status,
      logsPath: WorkspacePaths(config.dataDirectory).logsFile.path,
      activeAssignments: activeCount,
      activeAssignmentIds: assignmentsMap['activeIds'] is List
          ? (assignmentsMap['activeIds'] as List).whereType<String>().toList()
          : const [],
      reconnectCount: cloudMap['reconnectCount'] is int
          ? cloudMap['reconnectCount'] as int
          : 0,
      lastInventorySyncAt: DateTime.tryParse(
        cloudMap['lastInventorySyncAt']?.toString() ?? '',
      ),
      connectionStage: stage,
      connectionError: error,
      runtimeCredentialAvailable: config.authToken?.isNotEmpty == true,
      activeTransportMode: cloudMap['transport']?.toString(),
    );
  }

  WorkspaceUiSnapshot get uiSnapshot => _ipcUiSnapshot;

  Future<void> launch() async {
    await _connectToManager();
  }

  /// Drain through authenticated IPC, then stop through the OS host boundary.
  Future<void> stopService() async {
    if (_managerConnected) {
      await request('service.prepareStop',
          timeout: const Duration(seconds: 20));
    }
    try {
      await _serviceManager.unregister();
    } on Object {
      if (_managerConnected) await request('connection.reconnect');
      rethrow;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (_managerConnected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_managerConnected) {
      throw StateError(
          'macOS has not stopped the service. Check Login Items and Diagnostics.');
    }
    await _managerEvents?.cancel();
    _managerEvents = null;
    await _manager?.close();
    _manager = null;
    _managerConnected = false;
    _startupError = null;
    final store = WorkspaceLifecyclePreferencesStore(config.dataDirectory);
    await store.write(store.readSync().copyWith(
          desiredRuntime: DesiredRuntimeState.disconnected,
          launchAtLogin: false,
        ));
    _publishMenuStatus();
    notifyListeners();
  }

  Future<void> retryConnection() async {
    try {
      if (!_managerConnected) {
        await _connectToManager();
      } else {
        await request('connection.reconnect');
      }
    } catch (error) {
      _startupError = error;
    }
    notifyListeners();
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
    _closed = true;
    _managerRetryTimer?.cancel();
    await _managerEvents?.cancel();
    await _manager?.close();
    workerCatalog.dispose();
    _manager = null;
    _managerConnected = false;
    notifyListeners();
  }

  Future<File> exportDiagnostics() async {
    final result = await request('diagnostics.getDiagnostics');
    if (result is Map && result['path'] is String) {
      return File(result['path'] as String);
    }
    throw StateError('Workspace Service did not return diagnostics.');
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
    this.serviceRunning = false,
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
  final bool serviceRunning;
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

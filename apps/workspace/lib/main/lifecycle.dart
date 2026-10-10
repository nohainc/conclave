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
    WorkspaceServiceManager? serviceManager,
    this.startupTimeout = const Duration(seconds: 30),
    this.startupRetryDelay = const Duration(milliseconds: 300),
  }) : _hostServiceManager = serviceManager ?? _serviceManager {
    if (initialManagerSnapshot != null) {
      _managerSnapshot = initialManagerSnapshot;
      _managerConnected = true;
      final service = initialManagerSnapshot['service'];
      final processState =
          service is Map ? service['processState']?.toString() : null;
      _serviceInfo = _serviceInfo.copyWith(
        process: switch (processState) {
          'ready' => WorkspaceServiceProcessStatus.running,
          'starting' ||
          'initializing' =>
            WorkspaceServiceProcessStatus.starting,
          'stopping' => WorkspaceServiceProcessStatus.stopping,
          'stopped' => WorkspaceServiceProcessStatus.stopped,
          'failed' => WorkspaceServiceProcessStatus.failed,
          _ => WorkspaceServiceProcessStatus.unknown,
        },
        ipc: processState == 'ready'
            ? WorkspaceServiceIpcStatus.ready
            : WorkspaceServiceIpcStatus.unavailable,
      );
    }
    _managerRetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_closed && !_managerConnected) unawaited(_connectToManager());
    });
  }

  final WorkspaceConfig config;
  final WorkspaceServiceManager _hostServiceManager;
  final Duration startupTimeout;
  final Duration startupRetryDelay;
  Future<void>? _managerConnectAttempt;
  Object? _lastIpcError;
  Map<String, String> _serviceDiagnostics = const {};
  WorkspaceServiceInfo _serviceInfo = const WorkspaceServiceInfo(
    registration: WorkspaceBackgroundServiceRegistration.unknown,
    supported: false,
    helperPresent: false,
    plistPresent: false,
  );
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

  static Future<WorkspaceServiceInfo> getBackgroundServiceStatus() async {
    return _serviceManager.getInfo();
  }

  static Future<WorkspaceServiceInfo> registerBackgroundService() async {
    return _serviceManager.register();
  }

  static Future<WorkspaceServiceInfo> unregisterBackgroundService() async {
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

  /// Touch the configured Work Root before starting the background service.
  ///
  /// The service is headless, so a macOS privacy prompt cannot be shown from
  /// its process. Performing the same write probe in Workspace.app gives the
  /// user a chance to grant folder access before any Worker Engine starts.
  Future<bool> ensureWorkRootAccess() async {
    final configuredPath = config.workRootResolver.configuredPath;
    try {
      final root = await config.workRootResolver.resolve();
      WorkspacePaths(config.dataDirectory).validateWorkRootSeparation(root);
      return true;
    } on Object catch (initialError) {
      if (!Platform.isMacOS) rethrow;
      final selected = await requestWorkRootAccess(initialPath: configuredPath);
      if (selected == null || selected.trim().isEmpty) return false;
      final selectedPath = Directory(selected).absolute.path;
      final configuredAbsolute = Directory(configuredPath).absolute.path;
      if (selectedPath != configuredAbsolute) {
        throw StateError(
          'Select the configured Work Root before starting the service: '
          '$configuredPath',
        );
      }
      try {
        final root = await config.workRootResolver.resolve();
        WorkspacePaths(config.dataDirectory).validateWorkRootSeparation(root);
        return true;
      } on Object catch (retryError) {
        throw StateError(
          'Conclave Workspace still cannot access the Work Root. '
          'Initial check: $initialError. Retry: $retryError',
        );
      }
    }
  }

  Future<void> ensureBackgroundService() async {
    _serviceDiagnostics = const {};
    var info = await _hostServiceManager.getInfo();
    _serviceInfo = info;
    if (!info.supported) {
      throw UnsupportedError(
        'Background service management is unavailable on this platform.',
      );
    }
    if (!info.launchSupported) {
      throw StateError(
        'This Workspace build is not signed for macOS background service execution. '
        'Build with an Apple signing identity or use the UI-only debug mode.',
      );
    }
    await _connectToManager();
    if (_managerConnected) {
      _serviceInfo = _serviceInfo.copyWith(
        process: WorkspaceServiceProcessStatus.running,
        ipc: WorkspaceServiceIpcStatus.ready,
      );
      return;
    }
    if (info.registration ==
        WorkspaceBackgroundServiceRegistration.approvalRequired) {
      throw StateError(
          'Approve Conclave Workspace in System Settings → General → Login Items, then start the service again.');
    }
    try {
      if (!info.registered ||
          info.process != WorkspaceServiceProcessStatus.running) {
        info = await _hostServiceManager.register();
        _serviceInfo = info;
      }
      if (!info.launchSupported) {
        throw StateError(
          'This Workspace build is not signed for macOS background service execution. '
          'Build with an Apple signing identity or use the UI-only debug mode.',
        );
      }
      if (info.registration ==
          WorkspaceBackgroundServiceRegistration.approvalRequired) {
        throw StateError(
            'Approve Conclave Workspace in System Settings → General → Login Items, then start the service again.');
      }
      if (!info.registered) {
        throw StateError(
            'Workspace Service could not be registered (${info.registration.name}).');
      }
      // Registration and process launch are separate host operations. The
      // explicit start call returns immediately; IPC readiness is proven in
      // the loop below.
      info = await _hostServiceManager.start();
      _serviceInfo = info.copyWith(ipc: WorkspaceServiceIpcStatus.starting);
    } catch (error) {
      _recordServiceFailure(_serviceInfo, error);
      rethrow;
    }
    final deadline = DateTime.now().add(startupTimeout);
    while (!_managerConnected && DateTime.now().isBefore(deadline)) {
      await _connectToManager();
      if (_managerConnected) {
        _serviceInfo = _serviceInfo.copyWith(
          process: WorkspaceServiceProcessStatus.running,
          ipc: WorkspaceServiceIpcStatus.ready,
        );
        return;
      }
      try {
        info = await _hostServiceManager.getInfo();
        _serviceInfo = info.copyWith(ipc: WorkspaceServiceIpcStatus.starting);
        if (info.launchFailed) {
          final error = StateError(_serviceFailureMessage(info));
          _recordServiceFailure(info, error);
          throw error;
        }
      } catch (error) {
        if (error is StateError &&
            error.toString().startsWith('Bad state: Workspace Service')) {
          rethrow;
        }
        _lastIpcError = error;
      }
      if (!_managerConnected) {
        await Future<void>.delayed(startupRetryDelay);
      }
    }
    if (!_managerConnected) {
      try {
        info = await _hostServiceManager.getInfo();
        _serviceInfo = info.copyWith(ipc: WorkspaceServiceIpcStatus.failed);
      } on Object {
        // Preserve the connection failure if host inspection also fails.
      }
      final runtime = WorkspacePaths(config.dataDirectory).runtimeDirectory;
      _serviceDiagnostics = {
        'Registration': _serviceInfo.registration.name,
        'Process': _serviceInfo.process.name,
        'launchd': _serviceInfo.launchdState,
        if (_serviceInfo.pid != null) 'PID': '${_serviceInfo.pid}',
        'IPC key': await File('${runtime.path}/manager-ipc.key').exists()
            ? 'Found'
            : 'Missing',
        'IPC socket': await FileSystemEntity.type(
                    '${runtime.path}/manager.sock',
                    followLinks: false) !=
                FileSystemEntityType.notFound
            ? 'Found'
            : 'Missing',
        'IPC connection': 'Unavailable',
        'Last IPC error': _lastIpcError?.toString() ?? 'Unknown',
        if (_serviceInfo.lastExitCode != null)
          'Service exit code': '${_serviceInfo.lastExitCode}',
        if (_serviceInfo.lastExitReason != null)
          'Service exit reason': _serviceInfo.lastExitReason!,
      };
      final error = TimeoutException(
        'Workspace Service was registered, but Workspace could not connect to it.\n'
        '${_serviceDiagnostics.entries.map((entry) => "${entry.key}: ${entry.value}").join("\n")}',
        startupTimeout,
      );
      _startupError = error;
      notifyListeners();
      throw error;
    }
  }

  WorkspaceServiceInfo get serviceInfo => _serviceInfo;

  Future<WorkspaceServiceInfo> getServiceInfo() async {
    _serviceInfo = await _hostServiceManager.getInfo();
    notifyListeners();
    return _serviceInfo;
  }

  Future<WorkspaceServiceInfo> registerService() async {
    _serviceInfo = await _hostServiceManager.register();
    notifyListeners();
    return _serviceInfo;
  }

  Future<WorkspaceServiceInfo> startService() async {
    _serviceInfo = await _hostServiceManager.start();
    notifyListeners();
    return _serviceInfo;
  }

  Future<WorkspaceServiceInfo> restartService() async {
    if (_managerConnected) {
      await request('service.prepareStop',
          timeout: const Duration(seconds: 20));
    }
    await _closeManagerConnection();
    _serviceInfo = await _hostServiceManager.restart();
    _serviceInfo = _serviceInfo.copyWith(
      process: WorkspaceServiceProcessStatus.starting,
      ipc: WorkspaceServiceIpcStatus.starting,
    );
    notifyListeners();

    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await _connectToManager();
      if (_managerConnected) {
        _serviceInfo = _serviceInfo.copyWith(
          process: WorkspaceServiceProcessStatus.running,
          ipc: WorkspaceServiceIpcStatus.ready,
        );
        notifyListeners();
        return _serviceInfo;
      }
      final info = await _hostServiceManager.getInfo();
      _serviceInfo = info.copyWith(ipc: WorkspaceServiceIpcStatus.starting);
      if (info.launchFailed) {
        final error = StateError(_serviceFailureMessage(info));
        _recordServiceFailure(info, error);
        throw error;
      }
      await Future<void>.delayed(startupRetryDelay);
    }
    _serviceInfo = _serviceInfo.copyWith(ipc: WorkspaceServiceIpcStatus.failed);
    final error = TimeoutException(
      'Workspace Service restarted, but its IPC endpoint did not become ready.',
    );
    _recordServiceFailure(_serviceInfo, error);
    throw error;
  }

  Future<WorkspaceServiceInfo> unregisterService() async {
    _serviceInfo = await _hostServiceManager.unregister();
    notifyListeners();
    return _serviceInfo;
  }

  Future<void> connectCloud() async {
    await request('connection.connect');
    notifyListeners();
  }

  Future<void> disconnectCloud() async {
    await request('connection.disconnect');
    notifyListeners();
  }

  /// Checks the installed Workspace release through the running service.
  /// This is an HTTP release lookup owned by the service; it does not alter
  /// Cloud connection state or request a reconnect.
  Future<Map<String, Object?>> checkForUpdates() async {
    final result = await request('updates.check');
    if (result is! Map) {
      throw StateError('Workspace update check returned an invalid response.');
    }
    notifyListeners();
    return Map<String, Object?>.from(result);
  }

  String _serviceFailureMessage(WorkspaceServiceInfo info) {
    final reason = info.lastExitReason;
    return reason == null
        ? 'Workspace Service failed before IPC became ready.'
        : 'Workspace Service failed before IPC became ready: $reason';
  }

  void _recordServiceFailure(WorkspaceServiceInfo info, Object error) {
    _serviceInfo = info.copyWith(ipc: WorkspaceServiceIpcStatus.failed);
    _serviceDiagnostics = {
      'Registration': info.registration.name,
      'Process': info.process.name,
      'launchd': info.launchdState,
      if (info.pid != null) 'PID': '${info.pid}',
      if (info.lastExitCode != null)
        'Service exit code': '${info.lastExitCode}',
      if (info.lastExitReason != null)
        'Service exit reason': info.lastExitReason!,
      'IPC connection': 'Unavailable',
      'Error': error.toString(),
    };
    _startupError = error;
    notifyListeners();
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

  Future<void> _connectToManager() {
    if (_closed || _managerConnected) return Future<void>.value();
    final pending = _managerConnectAttempt;
    if (pending != null) return pending;
    if (_manager != null) return Future<void>.value();
    final attempt = _openManagerConnection();
    _managerConnectAttempt = attempt;
    return attempt.whenComplete(() {
      if (identical(_managerConnectAttempt, attempt)) {
        _managerConnectAttempt = null;
      }
    });
  }

  Future<void> _openManagerConnection() async {
    final runtimeDirectory =
        WorkspacePaths(config.dataDirectory).runtimeDirectory;
    final keyFile = File('${runtimeDirectory.path}/manager-ipc.key');
    WorkspaceManagerIpcConnection? connection;
    StreamSubscription<Map<String, Object?>>? events;
    try {
      final key = (await keyFile.readAsString()).trim();
      if (_closed) return;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
        throw StateError('Workspace service IPC key is invalid.');
      }
      connection = WorkspaceManagerIpcConnection(
          socketPath: '${runtimeDirectory.path}/manager.sock', key: key);
      _manager = connection;
      events = connection.events.listen((event) {
        if (!_closed && identical(_manager, connection)) {
          _handleManagerEvent(event);
        }
      });
      _managerEvents = events;
      await connection.connect();
      if (_closed) {
        await events.cancel();
        await connection.close();
        if (identical(_manager, connection)) _manager = null;
        if (identical(_managerEvents, events)) _managerEvents = null;
        return;
      }
      _managerConnected = true;
      _startupError = null;
      _lastIpcError = null;
      _serviceDiagnostics = const {};
      _acceptSnapshot(connection.initialSnapshot);
      notifyListeners();
    } on Object catch (error) {
      // Dispose the failed client and its independent retry loop. The next
      // startup attempt must read the current capability key and socket.
      try {
        await events?.cancel();
        await connection?.close();
      } finally {
        if (identical(_manager, connection)) _manager = null;
        if (identical(_managerEvents, events)) _managerEvents = null;
        _managerConnected = false;
        _serviceInfo = _serviceInfo.copyWith(
          ipc: WorkspaceServiceIpcStatus.failed,
        );
        _lastIpcError = error;
        if (_serviceDiagnostics.isEmpty) {
          _startupError = error;
        } else {
          _serviceDiagnostics = {
            ..._serviceDiagnostics,
            'Last IPC error': error.toString(),
          };
        }
        if (!_closed) notifyListeners();
      }
    }
  }

  void _handleManagerEvent(Map<String, Object?> event) {
    switch (event['name']) {
      case 'ipc.connectionChanged':
        _managerConnected = event['connected'] == true;
        if (!_managerConnected) {
          _startupError = 'Workspace service disconnected.';
          _serviceInfo = _serviceInfo.copyWith(
            ipc: WorkspaceServiceIpcStatus.unavailable,
          );
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
    final service = snapshot['service'];
    if (service is Map) {
      final startedAt =
          DateTime.tryParse(service['startedAt']?.toString() ?? '');
      final version = service['version']?.toString();
      _serviceInfo = _serviceInfo.copyWith(
        startedAt: startedAt,
        version: version == null || version.isEmpty ? null : version,
      );
    }
    final workerCatalogSnapshot = snapshot['workerCatalog'];
    if (workerCatalogSnapshot is Map) {
      workerCatalog
          .acceptSnapshot(Map<String, Object?>.from(workerCatalogSnapshot));
    }
    _managerConnected = true;
    _serviceInfo = _serviceInfo.copyWith(
      process: WorkspaceServiceProcessStatus.running,
      ipc: WorkspaceServiceIpcStatus.ready,
    );
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

  static Future<String?> requestWorkRootAccess({String? initialPath}) async {
    try {
      final result = await _desktopChannel.invokeMethod<String>(
          'requestWorkRootAccess', initialPath);
      if (result != null && result.trim().isNotEmpty) return result.trim();
    } catch (_) {}
    return chooseDirectory(initialPath: initialPath);
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
                        .desiredCloudState ==
                    DesiredCloudConnectionState.connected
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
      'serviceRunning': uiSnapshot.serviceHealthy,
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
    final serviceProcessRunning = serviceMap['processRunning'] == true ||
        processState == 'ready' ||
        _serviceInfo.process == WorkspaceServiceProcessStatus.running;
    final serviceIpcReady = serviceMap['ipcReady'] == true ||
        _managerConnected ||
        _serviceInfo.ipc == WorkspaceServiceIpcStatus.ready;
    final serviceHealthy = serviceMap['serviceHealthy'] == true ||
        (serviceProcessRunning && serviceIpcReady);
    final cloudState = cloudMap['state']?.toString();
    final stage = !serviceProcessRunning
        ? WorkspaceConnectionStage.offline
        : switch (cloudMap['connectionStage']?.toString() ?? cloudState) {
            'validating' => WorkspaceConnectionStage.validating,
            'connecting' => WorkspaceConnectionStage.connecting,
            'authenticating' => WorkspaceConnectionStage.authenticating,
            'synchronizing' => WorkspaceConnectionStage.synchronizing,
            'switchingToWebSocket' =>
              WorkspaceConnectionStage.switchingToWebSocket,
            'reconnecting' => WorkspaceConnectionStage.reconnecting,
            'connected' || 'ready' => WorkspaceConnectionStage.ready,
            _ => WorkspaceConnectionStage.offline,
          };
    final activeCount = assignmentsMap['activeCount'] is int
        ? assignmentsMap['activeCount'] as int
        : 0;
    final connected = serviceProcessRunning && cloudMap['connected'] == true;
    final desired = (cloudMap['desiredConnectionState']?.toString() ??
            preferences.desiredCloudState.name) ==
        DesiredCloudConnectionState.connected.name;
    final authenticated = cloudMap['authenticated'] == true;
    final synchronized = cloudMap['synchronized'] == true;
    final acceptingWork = cloudMap['acceptingNewWork'] == true;
    final cloudConnecting = stage == WorkspaceConnectionStage.validating ||
        stage == WorkspaceConnectionStage.connecting ||
        stage == WorkspaceConnectionStage.authenticating ||
        stage == WorkspaceConnectionStage.synchronizing ||
        stage == WorkspaceConnectionStage.switchingToWebSocket;
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
    final mode = !_managerConnected || !serviceProcessRunning
        ? WorkspaceUiMode.offline
        : !registrationPresent
            ? WorkspaceUiMode.firstLaunch
            : cloudConnecting || stage == WorkspaceConnectionStage.reconnecting
                ? WorkspaceUiMode.starting
                : activeCount > 0
                    ? WorkspaceUiMode.active
                    : serviceHealthy
                        ? WorkspaceUiMode.ready
                        : WorkspaceUiMode.offline;
    final status = !_managerConnected
        ? 'Service unavailable'
        : connected
            ? (acceptingWork ? 'Connected' : 'Paused')
            : cloudConnecting
                ? 'Connecting'
                : cloudState == 'reconnecting'
                    ? 'Reconnecting'
                    : cloudState == 'authenticationRequired'
                        ? 'Authentication required'
                        : serviceHealthy
                            ? 'Cloud disconnected'
                            : 'Offline';
    return WorkspaceUiSnapshot(
      mode: mode,
      serviceDiagnostics: _serviceDiagnostics,
      serviceInfo: _serviceInfo,
      desiredRuntimeConnected: desired,
      title: !_managerConnected
          ? 'Workspace Service is unavailable'
          : !registrationPresent
              ? 'Register this Workspace'
              : serviceHealthy
                  ? connected
                      ? (activeCount > 0
                          ? 'Work in progress'
                          : 'Workspace is ready')
                      : 'Workspace Service is running'
                  : 'Workspace is offline',
      detail: !_managerConnected
          ? 'Start the background service to manage this Workspace.'
          : !registrationPresent
              ? 'Sign in to register this computer with Conclave.'
              : serviceHealthy
                  ? connected
                      ? (activeCount > 0
                          ? 'The background service is running assigned work.'
                          : 'This computer is registered and ready to run assigned work.')
                      : 'The background service is healthy, but Cloud is disconnected.'
                  : 'The background service is not running.',
      issue: !_managerConnected || !serviceHealthy
          ? _startupError?.toString()
          : null,
      workspaceName: workspaceName,
      workspaceId: workspaceId,
      installationId:
          serviceMap['installationId']?.toString() ?? config.installationId,
      workspaceRuntimeId: runtimeId,
      hostname: registration?.hostname ?? Platform.localHostname,
      cloudUrl: workspaceMap['cloudUrl']?.toString() ?? registration?.cloudUrl,
      workRootPath: serviceHealthy
          ? workspaceMap['workRoot']?.toString() ?? config.workRootPath
          : preferences.workRootPath ??
              config.workRootPath ??
              WorkRootResolver().defaultPath,
      registered: registrationPresent || workspaceId != null,
      ownerUserId: registration?.ownerUserId,
      workspaceReady: connected,
      serviceRunning: serviceHealthy,
      cloudConnected: connected,
      serviceProcessRunning: serviceProcessRunning,
      serviceIpcReady: serviceIpcReady,
      serviceHealthy: serviceHealthy,
      desiredCloudConnected: desired,
      cloudAuthenticated: authenticated,
      cloudSynchronized: synchronized,
      cloudAcceptingWork: acceptingWork,
      cloudConnectionStage: cloudMap['connectionStage']?.toString(),
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
    try {
      _serviceInfo = await _hostServiceManager.getInfo();
    } on Object catch (error) {
      _lastIpcError = error;
    }
    await _connectToManager();
    notifyListeners();
  }

  /// Drain through authenticated IPC, then stop through the OS host boundary.
  Future<void> stopService() async {
    if (_managerConnected) {
      await request('service.prepareStop',
          timeout: const Duration(seconds: 20));
    }
    try {
      _serviceInfo = await _hostServiceManager.stop();
    } on Object {
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
    await _closeManagerConnection();
    _serviceInfo = _serviceInfo.copyWith(
      process: WorkspaceServiceProcessStatus.stopped,
      ipc: WorkspaceServiceIpcStatus.unavailable,
      clearPid: true,
    );
    _startupError = null;
    // Stopping the local process does not change the user's Cloud intent or
    // registration. An explicit Disconnect action owns that preference.
    _publishMenuStatus();
    notifyListeners();
  }

  Future<void> _closeManagerConnection() async {
    _managerConnected = false;
    await _managerEvents?.cancel();
    _managerEvents = null;
    await _manager?.close();
    _manager = null;
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
    this.serviceProcessRunning = false,
    this.serviceIpcReady = false,
    this.serviceHealthy = false,
    this.desiredCloudConnected = false,
    this.cloudAuthenticated = false,
    this.cloudSynchronized = false,
    this.cloudAcceptingWork = false,
    this.cloudConnectionStage,
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
    this.serviceDiagnostics = const {},
    this.serviceInfo = const WorkspaceServiceInfo(
      registration: WorkspaceBackgroundServiceRegistration.unknown,
      supported: false,
      helperPresent: false,
      plistPresent: false,
    ),
  });

  String get serviceStatusDescription {
    if (serviceRunning) return 'Running';
    if (serviceInfo.process == WorkspaceServiceProcessStatus.failed) {
      return 'Failed';
    }
    if (serviceInfo.process == WorkspaceServiceProcessStatus.starting) {
      return 'Starting';
    }
    if (serviceInfo.process == WorkspaceServiceProcessStatus.stopping) {
      return 'Stopping';
    }
    if (serviceDiagnostics['launchd'] == 'running') {
      return 'Running · Management unavailable';
    }
    if (serviceDiagnostics.isNotEmpty &&
        !const {'stopped', 'not running'}
            .contains(serviceDiagnostics['launchd'])) {
      return 'Status unavailable';
    }
    return 'Stopped';
  }

  final Map<String, String> serviceDiagnostics;
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

  /// Explicit service health dimensions. The legacy fields above remain
  /// source-compatible aliases for existing management surfaces.
  final bool serviceProcessRunning;
  final bool serviceIpcReady;
  final bool serviceHealthy;
  final bool desiredCloudConnected;
  final bool cloudAuthenticated;
  final bool cloudSynchronized;
  final bool cloudAcceptingWork;
  final String? cloudConnectionStage;

  String get desiredConnectionState =>
      desiredCloudConnected ? 'connected' : 'disconnected';
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
  final WorkspaceServiceInfo serviceInfo;

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

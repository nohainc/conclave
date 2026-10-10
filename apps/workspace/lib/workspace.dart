import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';
import 'local_worker_registry.dart';
import 'workspace_configuration.dart';
import 'secure_credentials.dart';
import 'platform_runtime.dart';
import 'work_root.dart';
import 'workspace_paths.dart';
import 'worker_readiness.dart';
import 'tool_profile_catalog.dart';
import 'tool_profile_release_store.dart';
import 'worker_catalog_coordinator.dart';
import 'workspace_service_state.dart';
import 'workspace_registration_models.dart';
import 'workspace_lifecycle_store.dart';

export 'local_worker_registry.dart';
export 'release_trust_roots.dart';
export 'tool_profile_release_verifier.dart';
export 'tool_profile_catalog.dart';
export 'tool_profile_release_store.dart';
export 'worker_catalog_coordinator.dart';
export 'workspace_paths.dart';
export 'workspace_background_service.dart';
export 'space_directory.dart';

typedef WorkspaceStatusProvider = Future<Map<String, Object?>> Function();
typedef WorkspaceUpdateHandler = Future<Map<String, Object?>> Function(
  Map<String, Object?> request,
);

class WorkspaceConfig {
  const WorkspaceConfig({
    required this.dataDirectory,
    this.cloudUri,
    this.workspaceRuntimeId,
    this.installationId,
    this.workspaceId,
    this.authToken,
    this.workRootPath,
  });

  final Directory dataDirectory;
  final Uri? cloudUri;
  final String? workspaceRuntimeId;
  final String? installationId;
  final String? workspaceId;
  final String? authToken;
  final String? workRootPath;

  WorkRootResolver get workRootResolver =>
      WorkRootResolver(overridePath: workRootPath);

  factory WorkspaceConfig.fromArgs(
    List<String> args, {
    SecureCredentialStore? credentialStore,
    bool ignoreSavedRegistration = false,
  }) {
    final index = args.indexOf('--data-dir');
    final cloudIndex = args.indexOf('--cloud-url');
    final workspaceRuntimeIndex = args.indexOf('--workspace-runtime-id');
    final installationIndex = args.indexOf('--installation-id');
    final workspaceIndex = args.indexOf('--workspace-id');
    final workRootIndex = args.indexOf('--work-root');
    final path = index >= 0 && index + 1 < args.length
        ? args[index + 1]
        : Platform.environment['CONCLAVE_WORKSPACE_DATA_DIR'];
    final dataDirectory =
        path == null ? WorkspacePaths.defaultStateDirectory() : Directory(path);
    final savedRegistration =
        WorkspaceRegistrationStore(dataDirectory).readSync();
    final registration = ignoreSavedRegistration ? null : savedRegistration;
    final cloudUrl = cloudIndex >= 0 && cloudIndex + 1 < args.length
        ? args[cloudIndex + 1]
        : Platform.environment['CONCLAVE_WORKSPACE_CLOUD_URL'] ??
            savedRegistration?.cloudUrl;
    final workspaceRuntimeId =
        workspaceRuntimeIndex >= 0 && workspaceRuntimeIndex + 1 < args.length
            ? args[workspaceRuntimeIndex + 1]
            : ignoreSavedRegistration
                ? null
                : Platform.environment['CONCLAVE_WORKSPACE_RUNTIME_ID'] ??
                    registration?.workspaceRuntimeId;
    final installationId =
        installationIndex >= 0 && installationIndex + 1 < args.length
            ? args[installationIndex + 1]
            : Platform.environment['CONCLAVE_WORKSPACE_INSTALLATION_ID'] ??
                registration?.installationId ??
                InstallationIdentityStore(dataDirectory).readSync();
    final workspaceId = workspaceIndex >= 0 && workspaceIndex + 1 < args.length
        ? args[workspaceIndex + 1]
        : ignoreSavedRegistration
            ? null
            : Platform.environment['CONCLAVE_WORKSPACE_ID'] ??
                registration?.workspaceId;
    final workRootPath = workRootIndex >= 0 && workRootIndex + 1 < args.length
        ? args[workRootIndex + 1]
        : Platform.environment['CONCLAVE_WORKSPACE_WORK_ROOT'] ??
            WorkspaceLifecyclePreferencesStore(dataDirectory)
                .readSync()
                .workRootPath;
    final secureStore =
        credentialStore ?? const PlatformSecureCredentialStore();
    final storedToken = workspaceRuntimeId == null
        ? null
        : secureStore.readSync(workspaceRuntimeId);
    final configuredCloudUrl = cloudUrl ?? registration?.cloudUrl;
    final configuredCloudUri = configuredCloudUrl == null
        ? null
        : _workspaceGatewayUri(configuredCloudUrl,
            workspaceRuntimeId: workspaceRuntimeId);
    return WorkspaceConfig(
      dataDirectory: dataDirectory,
      cloudUri: configuredCloudUri,
      workspaceRuntimeId: workspaceRuntimeId,
      installationId: installationId,
      workspaceId: workspaceId,
      authToken: ignoreSavedRegistration
          ? null
          : Platform.environment['CONCLAVE_WORKSPACE_TOKEN'] ?? storedToken,
      workRootPath: workRootPath,
    );
  }

  static Directory resolveDataDirectory(List<String> args) {
    final index = args.indexOf('--data-dir');
    final path = index >= 0 && index + 1 < args.length
        ? args[index + 1]
        : Platform.environment['CONCLAVE_WORKSPACE_DATA_DIR'];
    return path == null
        ? WorkspacePaths.defaultStateDirectory()
        : Directory(path);
  }

  static Uri? _workspaceGatewayUri(String value, {String? workspaceRuntimeId}) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final socketScheme = switch (uri.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      'wss' => 'wss',
      'ws' => 'ws',
      _ => null,
    };
    if (socketScheme == null) return uri;

    final isHttpOrigin = uri.scheme == 'http' || uri.scheme == 'https';
    final existingPath = uri.path.replaceFirst(RegExp(r'/$'), '');
    final path = isHttpOrigin || uri.path.isEmpty || uri.path == '/'
        ? '$existingPath/api/workspace-gateway/connect'
        : uri.path;

    // dart:io's WebSocket.connect converts ws(s) to http(s) internally and
    // copies Uri.port. For ws(s) Uri.port may be 0 when omitted, which turns
    // the actual handshake URL into https://invalid:0/... . Materialize the
    // protocol default here so the SDK receives 443/80 instead.
    final port = uri.hasPort
        ? uri.port
        : socketScheme == 'wss'
            ? 443
            : 80;
    final safeQueryParameters = {
      for (final entry in uri.queryParameters.entries)
        if (!RegExp(
          r'(secret|token|password|api[_-]?key|authorization|cookie|credential)',
          caseSensitive: false,
        ).hasMatch(entry.key))
          entry.key: entry.value,
    };

    return Uri(
      scheme: socketScheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: port,
      path: path,
      queryParameters: {
        ...safeQueryParameters,
        if (workspaceRuntimeId != null)
          'workspaceRuntimeId': workspaceRuntimeId,
      },
    );
  }
}

class WorkspaceLogger {
  WorkspaceLogger(this._output,
      {this.redact = _identity, this.context = const {}});
  IOSink _output;
  final String Function(String) redact;
  final Map<String, Object?> context;

  static String _identity(String value) => value;

  void attach(IOSink output) => _output = output;

  void info(String message, [Map<String, Object?> details = const {}]) {
    final record = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'info',
      'severity': 'info',
      'event': message,
      'message': message,
      'serviceVersion': context['serviceVersion'],
      'workspaceId': context['workspaceId'],
      if (details.isNotEmpty) 'details': _sanitize(details),
    };
    _output.writeln(redact(jsonEncode(record)));
  }

  static Object? _sanitize(Object? value, {int depth = 0}) {
    if (depth > 5) return '[depth limited]';
    if (value is String) {
      return value.length > 512 ? '${value.substring(0, 512)}…' : value;
    }
    if (value == null || value is num || value is bool) return value;
    if (value is List) {
      return value
          .take(50)
          .map((item) => _sanitize(item, depth: depth + 1))
          .toList();
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries.take(80))
          entry.key.toString():
              RegExp(r'(secret|token|password|api[_-]?key|authorization|cookie|raw[_-]?credential|private[_-]?key)',
                          caseSensitive: false)
                      .hasMatch(entry.key.toString())
                  ? '[redacted]'
                  : _sanitize(entry.value, depth: depth + 1),
      };
    }
    return '[${value.runtimeType}]';
  }
}

class Workspace {
  Workspace({
    required this.config,
    IOSink? logOutput,
    this.cloudConnection,
    this.statusProvider,
    this.updateStatusProvider,
    this.updateHandler,
    SecureCredentialStore? credentialStore,
    this.toolProfileReleaseStore,
    this.toolProfileCatalog,
    this.workerCatalogCoordinator,
    LocalWorkerRegistry? localWorkerRegistry,
    this.workerReadinessMonitor,
    this.workerShutdownHandler,
    this.workerRecoveryHandler,
    String Function(String)? redactLog,
    this.logFileMaxBytes = 1024 * 1024,
  })  : _configuredLogOutput = logOutput,
        credentialStore =
            credentialStore ?? const PlatformSecureCredentialStore(),
        localWorkerRegistry = localWorkerRegistry ??
            (config.workspaceId == null
                ? null
                : LocalWorkerRegistry(
                    dataDirectory: config.dataDirectory,
                    workspaceId: config.workspaceId!,
                  )),
        _log = WorkspaceLogger(logOutput ?? stdout,
            redact: redactLog ?? WorkspaceLogger._identity,
            context: {
              'serviceVersion': conclaveWorkspaceAppVersion,
              if (config.workspaceId != null) 'workspaceId': config.workspaceId,
            }) {
    if (logFileMaxBytes <= 0) {
      throw ArgumentError.value(
          logFileMaxBytes, 'logFileMaxBytes', 'must be positive');
    }
  }

  final WorkspaceConfig config;
  final SecureCredentialStore credentialStore;
  final ToolProfileReleaseStore? toolProfileReleaseStore;
  final ToolProfileCatalogClient? toolProfileCatalog;
  final WorkerCatalogCoordinator? workerCatalogCoordinator;
  final LocalWorkerRegistry? localWorkerRegistry;
  final WorkerReadinessMonitor? workerReadinessMonitor;
  final Future<void> Function()? workerShutdownHandler;
  final Future<int> Function()? workerRecoveryHandler;
  final WorkspaceCloudConnection? cloudConnection;
  final WorkspaceStatusProvider? statusProvider;
  final WorkspaceStatusProvider? updateStatusProvider;
  final WorkspaceUpdateHandler? updateHandler;
  final IOSink? _configuredLogOutput;
  final int logFileMaxBytes;
  final WorkspaceLogger _log;
  IOSink? _ownedLogOutput;
  RandomAccessFile? _lock;
  Directory? _workRoot;
  bool _running = false;
  DateTime? _startedAt;
  Timer? _stateTimer;
  Timer? _logRotationTimer;
  Future<void> _stateWriteQueue = Future<void>.value();
  final List<StreamSubscription<ProcessSignal>> _signalSubscriptions = [];

  String? get installationId => config.installationId;
  bool get isRunning => _running;
  Directory? get workRoot => _workRoot;
  Future<void> start({bool connectCloud = true}) async {
    if (_running) return;
    await config.dataDirectory.create(recursive: true);
    await currentPlatformRuntime.restrictPermissions(
      config.dataDirectory.path,
      directory: true,
    );
    final lockFile = WorkspacePaths(config.dataDirectory)
        .installationLockFile(config.installationId);
    try {
      _lock = await lockFile.open(mode: FileMode.writeOnlyAppend);
      await _lock!.lock(FileLock.exclusive);
    } on FileSystemException {
      await _lock?.close();
      _lock = null;
      throw StateError('another Workspace instance already owns the lock');
    }
    try {
      await _writeServiceState(WorkspaceServiceProcessState.starting);
      await _writeServiceState(WorkspaceServiceProcessState.initializing);
      // The installation lock is held before journal recovery, so no second
      // process can classify or replay the same in-flight assignments.
      await cloudConnection?.assignmentJournal?.recoverAfterRestart();
      final reapedWorkers = await workerRecoveryHandler?.call() ?? 0;
      if (reapedWorkers > 0) {
        _log.info('Recovered orphaned Worker Engine processes', {
          'processCount': reapedWorkers,
        });
      }
      _workRoot = await config.workRootResolver.resolve();
      final paths = WorkspacePaths(config.dataDirectory);
      paths.validateWorkRootSeparation(_workRoot!);
      await paths.prepareRuntimeDirectories();
      if (_configuredLogOutput == null) {
        _ownedLogOutput = await _openLogFile();
        _log.attach(_ownedLogOutput!);
        _logRotationTimer = Timer.periodic(const Duration(seconds: 30), (_) {
          unawaited(_rotateLogIfNeeded());
        });
      }
      workerCatalogCoordinator?.start();
      await workerReadinessMonitor?.start();
      _signalSubscriptions.addAll(
        currentPlatformRuntime.watchTermination(() => unawaited(stop())),
      );
      _running = true;
      _startedAt = DateTime.now().toUtc();
      await _writeServiceState(WorkspaceServiceProcessState.ready);
      _stateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(_writeServiceState(WorkspaceServiceProcessState.ready));
      });
    } on Object catch (error) {
      _running = false;
      _stateTimer?.cancel();
      _stateTimer = null;
      _logRotationTimer?.cancel();
      _logRotationTimer = null;
      await workerReadinessMonitor?.dispose();
      workerCatalogCoordinator?.dispose();
      toolProfileCatalog?.close();
      for (final subscription in _signalSubscriptions) {
        await subscription.cancel();
      }
      _signalSubscriptions.clear();
      await _lock?.unlock();
      await _lock?.close();
      _lock = null;
      await _ownedLogOutput?.flush();
      await _ownedLogOutput?.close();
      _ownedLogOutput = null;
      if (_configuredLogOutput == null) _log.attach(stdout);
      await _writeServiceState(WorkspaceServiceProcessState.failed,
          failure: error.toString());
      rethrow;
    }
    if (connectCloud) {
      try {
        await cloudConnection?.connect();
      } on Object {
        // Keep the process and local runtime state alive. The headless service
        // entry point retries this initial Cloud connection with backoff.
        await _writeServiceState(WorkspaceServiceProcessState.ready);
        rethrow;
      }
    }
    _log.info('Workspace started', {
      'dataDirectory': config.dataDirectory.path,
      'workRoot': _workRoot!.path,
    });
  }

  Future<void> stop() async {
    if (!_running) return;
    await _writeServiceState(WorkspaceServiceProcessState.stopping);
    _running = false;
    _stateTimer?.cancel();
    _stateTimer = null;
    _logRotationTimer?.cancel();
    _logRotationTimer = null;
    await workerReadinessMonitor?.dispose();
    workerCatalogCoordinator?.dispose();
    toolProfileCatalog?.close();
    for (final subscription in _signalSubscriptions) {
      await subscription.cancel();
    }
    _signalSubscriptions.clear();
    try {
      await cloudConnection?.close();
    } finally {
      await workerShutdownHandler?.call();
    }
    await _writeServiceState(WorkspaceServiceProcessState.stopped);
    await _lock?.unlock();
    await _lock?.close();
    _lock = null;
    _log.info('Workspace stopped');
    await _ownedLogOutput?.flush();
    await _ownedLogOutput?.close();
    _ownedLogOutput = null;
    if (_configuredLogOutput == null) _log.attach(stdout);
  }

  Future<void> _writeServiceState(WorkspaceServiceProcessState processState,
      {String? failure}) {
    final connection = cloudConnection;
    final nextWrite = _stateWriteQueue.then((_) => writeWorkspaceServiceState(
          config.dataDirectory,
          WorkspaceServiceState(
            processState: processState,
            cloudState: WorkspaceServiceState.cloudStateFor(
              configured: config.cloudUri != null && config.workspaceId != null,
              authenticated: config.authToken?.isNotEmpty == true,
              stage: connection?.connectionStage,
            ),
            installationId: config.installationId,
            updatedAt: DateTime.now().toUtc(),
            startedAt: _startedAt,
            executionState: (connection?.activeAssignmentCount ?? 0) > 0
                ? WorkspaceServiceExecutionState.executing
                : WorkspaceServiceExecutionState.idle,
            activeAssignments: connection?.activeAssignmentCount ?? 0,
            failure: failure,
          ),
        ));
    _stateWriteQueue = nextWrite.catchError((Object _) {});
    return nextWrite;
  }

  Future<IOSink> _openLogFile() async {
    final logsDirectory = WorkspacePaths(config.dataDirectory).logsDirectory;
    await logsDirectory.create(recursive: true);
    await currentPlatformRuntime.restrictPermissions(logsDirectory.path,
        directory: true);
    final current = File('${logsDirectory.path}/workspace.log');
    if (await current.exists() && await current.length() >= logFileMaxBytes) {
      await _rotateLogFile(current);
    }
    final output = current.openWrite(mode: FileMode.append);
    await currentPlatformRuntime.restrictPermissions(current.path,
        directory: false);
    return output;
  }

  Future<void> _rotateLogIfNeeded() async {
    if (!_running || _configuredLogOutput != null) return;
    final current = WorkspacePaths(config.dataDirectory).logsFile;
    if (!await current.exists() || await current.length() < logFileMaxBytes) {
      return;
    }
    await _ownedLogOutput?.flush();
    await _ownedLogOutput?.close();
    _ownedLogOutput = null;
    await _rotateLogFile(current);
    _ownedLogOutput = current.openWrite(mode: FileMode.append);
    await currentPlatformRuntime.restrictPermissions(current.path,
        directory: false);
    _log.attach(_ownedLogOutput!);
  }

  Future<void> _rotateLogFile(File current) async {
    final previous = File('${current.path}.1');
    if (await previous.exists()) await previous.delete();
    await current.rename(previous.path);
    final length = await previous.length();
    if (length <= logFileMaxBytes) return;
    final handle = await previous.open();
    late final List<int> tail;
    try {
      await handle.setPosition(length - logFileMaxBytes);
      tail = await handle.read(logFileMaxBytes);
    } finally {
      await handle.close();
    }
    await previous.writeAsBytes(tail, flush: true);
  }
}

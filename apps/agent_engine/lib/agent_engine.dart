import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'cloud_connection.dart';
import 'agent_configuration.dart';
import 'local_ipc.dart';
import 'secure_credentials.dart';

typedef AgentEngineStatusProvider = Future<Map<String, Object?>> Function();
typedef AgentEngineUpdateHandler = Future<Map<String, Object?>> Function(
  Map<String, Object?> request,
);

class AgentEngineConfig {
  const AgentEngineConfig({
    required this.dataDirectory,
    this.cloudUri,
    this.agentId,
    this.workspaceId,
    this.repositoriesFile,
    this.authToken,
    this.ipcPort,
    this.ipcToken,
  });

  final Directory dataDirectory;
  final Uri? cloudUri;
  final String? agentId;
  final String? workspaceId;
  final String? repositoriesFile;
  final String? authToken;
  final int? ipcPort;
  final String? ipcToken;

  factory AgentEngineConfig.fromArgs(
    List<String> args, {
    SecureCredentialStore? credentialStore,
  }) {
    final index = args.indexOf('--data-dir');
    final cloudIndex = args.indexOf('--cloud-url');
    final agentIndex = args.indexOf('--agent-id');
    final workspaceIndex = args.indexOf('--workspace-id');
    final repositoriesIndex = args.indexOf('--repositories');
    final path = index >= 0 && index + 1 < args.length
        ? args[index + 1]
        : Platform.environment['CONCLAVE_AGENT_DATA_DIR'];
    final dataDirectory = Directory(path ??
        '${Platform.environment['HOME'] ?? Directory.current.path}/.conclave-agent');
    final registration = AgentRegistrationStore(dataDirectory).readSync();
    final cloudUrl = cloudIndex >= 0 && cloudIndex + 1 < args.length
        ? args[cloudIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_CLOUD_URL'];
    final agentId = agentIndex >= 0 && agentIndex + 1 < args.length
        ? args[agentIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_ID'] ?? registration?.agentId;
    final workspaceId = workspaceIndex >= 0 && workspaceIndex + 1 < args.length
        ? args[workspaceIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_WORKSPACE_ID'] ??
            registration?.workspaceId;
    final repositoriesFile =
        repositoriesIndex >= 0 && repositoriesIndex + 1 < args.length
            ? args[repositoriesIndex + 1]
            : Platform.environment['CONCLAVE_AGENT_REPOSITORIES'];
    final ipcPortIndex = args.indexOf('--ipc-port');
    final ipcTokenIndex = args.indexOf('--ipc-token');
    final ipcPortValue = ipcPortIndex >= 0 && ipcPortIndex + 1 < args.length
        ? args[ipcPortIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_IPC_PORT'];
    final ipcToken = ipcTokenIndex >= 0 && ipcTokenIndex + 1 < args.length
        ? args[ipcTokenIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_IPC_TOKEN'];
    final secureStore =
        credentialStore ?? const PlatformSecureCredentialStore();
    final storedToken = agentId == null ? null : secureStore.readSync(agentId);
    final configuredCloudUrl = cloudUrl ?? registration?.cloudUrl;
    final configuredCloudUri =
        configuredCloudUrl == null ? null : _cloudSocketUri(configuredCloudUrl);
    return AgentEngineConfig(
      dataDirectory: dataDirectory,
      cloudUri: configuredCloudUri,
      agentId: agentId,
      workspaceId: workspaceId,
      repositoriesFile: repositoriesFile,
      authToken: Platform.environment['CONCLAVE_AGENT_TOKEN'] ?? storedToken,
      ipcPort: ipcPortValue == null ? null : int.tryParse(ipcPortValue),
      ipcToken: ipcToken,
    );
  }

  static Uri? _cloudSocketUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.scheme == 'ws' || uri.scheme == 'wss') return uri;
    if (uri.scheme != 'http' && uri.scheme != 'https') return uri;
    return uri.replace(
      scheme: uri.scheme == 'https' ? 'wss' : 'ws',
      path:
          '${uri.path.replaceFirst(RegExp(r'/$'), '')}/api/agent-gateway/connect',
    );
  }
}

class AgentEngineLogger {
  AgentEngineLogger(this._output, {this.redact = _identity});
  IOSink _output;
  final String Function(String) redact;

  static String _identity(String value) => value;

  void attach(IOSink output) => _output = output;

  void info(String message, [Map<String, Object?> details = const {}]) {
    final record = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'info',
      'message': message,
      if (details.isNotEmpty) 'details': details,
    };
    _output.writeln(redact(jsonEncode(record)));
  }
}

class AgentEngine {
  AgentEngine({
    required this.config,
    IOSink? logOutput,
    this.cloudConnection,
    this.statusProvider,
    this.updateStatusProvider,
    this.updateHandler,
    String Function(String)? redactLog,
    this.logFileMaxBytes = 1024 * 1024,
  })  : _configuredLogOutput = logOutput,
        _log = AgentEngineLogger(logOutput ?? stdout,
            redact: redactLog ?? AgentEngineLogger._identity) {
    if (logFileMaxBytes <= 0) {
      throw ArgumentError.value(
          logFileMaxBytes, 'logFileMaxBytes', 'must be positive');
    }
  }

  final AgentEngineConfig config;
  final AgentCloudConnection? cloudConnection;
  final AgentEngineStatusProvider? statusProvider;
  final AgentEngineStatusProvider? updateStatusProvider;
  final AgentEngineUpdateHandler? updateHandler;
  final IOSink? _configuredLogOutput;
  final int logFileMaxBytes;
  final AgentEngineLogger _log;
  IOSink? _ownedLogOutput;
  File? _logFile;
  RandomAccessFile? _lock;
  LocalIpcServer? _ipc;
  bool _running = false;
  StreamSubscription<ProcessSignal>? _sigint;
  StreamSubscription<ProcessSignal>? _sigterm;

  bool get isRunning => _running;
  int? get ipcPort => _ipc?.port;

  Future<Map<String, Object?>> _handleIpcCommand(IpcCommand command) async {
    if (command.type == 'engine.logs') {
      final requested = command.payload['limit'];
      final limit = (requested is int ? requested : 100).clamp(1, 200);
      final file = _logFile;
      if (file == null || !await file.exists()) {
        return {'lines': <String>[]};
      }
      final lines = await file.readAsLines();
      return {
        'lines':
            lines.length <= limit ? lines : lines.sublist(lines.length - limit),
      };
    }
    if (command.type == 'engine.restart') {
      // Let the IPC response flush before replacing the listening socket.
      unawaited(
          Future<void>.delayed(const Duration(milliseconds: 50), () async {
        await stop();
        await start();
      }));
      return {'accepted': true};
    }
    if (command.type == 'engine.update') {
      final handler = updateHandler;
      if (handler == null) {
        throw StateError('Agent Engine updates are not configured');
      }
      return handler(command.payload);
    }
    if (command.type != 'engine.status') {
      throw StateError('unsupported engine command: ${command.type}');
    }
    final provided = await statusProvider?.call() ?? const <String, Object?>{};
    final updateStatus = await updateStatusProvider?.call();
    return {
      'online': _running,
      'status': _running ? 'running' : 'stopped',
      'workers': 0,
      'plugins': 0,
      'activeTasks': 0,
      'version': '0.1.0',
      ...provided,
      if (updateStatus != null) 'update': updateStatus,
    };
  }

  Future<void> start() async {
    if (_running) return;
    await config.dataDirectory.create(recursive: true);
    await _restrictPermissions(config.dataDirectory.path, directory: true);
    if (_configuredLogOutput == null) {
      _ownedLogOutput = await _openLogFile();
      _log.attach(_ownedLogOutput!);
    }
    final lockFile = File('${config.dataDirectory.path}/engine.lock');
    try {
      _lock = await lockFile.open(mode: FileMode.writeOnlyAppend);
      await _lock!.lock(FileLock.exclusive);
    } on FileSystemException {
      await _lock?.close();
      _lock = null;
      throw StateError('another Agent Engine instance already owns the lock');
    }
    await File('${config.dataDirectory.path}/engine-state.json').writeAsString(
      jsonEncode({
        'status': 'running',
        'startedAt': DateTime.now().toUtc().toIso8601String()
      }),
    );
    final token = config.ipcToken ?? _newIpcToken();
    _ipc = LocalIpcServer(
      token: token,
      bindPort: config.ipcPort ?? 0,
      onCommand: _handleIpcCommand,
    );
    await _ipc!.start();
    final ipcFile = File('${config.dataDirectory.path}/ipc.json');
    await ipcFile.writeAsString(
      jsonEncode({'port': _ipc!.port, 'token': token}),
      flush: true,
    );
    await _restrictPermissions(ipcFile.path);
    _running = true;
    _sigint = ProcessSignal.sigint.watch().listen((_) => unawaited(stop()));
    _sigterm = ProcessSignal.sigterm.watch().listen((_) => unawaited(stop()));
    try {
      await cloudConnection?.connect();
    } on Object {
      await stop();
      rethrow;
    }
    _log.info(
        'Agent Engine started', {'dataDirectory': config.dataDirectory.path});
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _sigint?.cancel();
    await _sigterm?.cancel();
    await cloudConnection?.close();
    await _ipc?.close();
    _ipc = null;
    final ipcFile = File('${config.dataDirectory.path}/ipc.json');
    if (await ipcFile.exists()) await ipcFile.delete();
    await File('${config.dataDirectory.path}/engine-state.json').writeAsString(
      jsonEncode({
        'status': 'stopped',
        'stoppedAt': DateTime.now().toUtc().toIso8601String()
      }),
    );
    await _lock?.unlock();
    await _lock?.close();
    _lock = null;
    _log.info('Agent Engine stopped');
    await _ownedLogOutput?.flush();
    await _ownedLogOutput?.close();
    _ownedLogOutput = null;
    if (_configuredLogOutput == null) _log.attach(stdout);
  }

  Future<IOSink> _openLogFile() async {
    final logsDirectory = Directory('${config.dataDirectory.path}/logs');
    await logsDirectory.create(recursive: true);
    await _restrictPermissions(logsDirectory.path, directory: true);
    final current = File('${logsDirectory.path}/agent-engine.log');
    if (await current.exists() && await current.length() >= logFileMaxBytes) {
      final previous = File('${logsDirectory.path}/agent-engine.log.1');
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    }
    _logFile = current;
    final output = current.openWrite(mode: FileMode.append);
    await _restrictPermissions(current.path);
    return output;
  }

  String _newIpcToken() => base64UrlEncode(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      );

  Future<void> _restrictPermissions(String path,
      {bool directory = false}) async {
    if (Platform.isWindows) return;
    final result = await Process.run(
      'chmod',
      [directory ? '700' : '600', path],
    );
    if (result.exitCode != 0) {
      throw StateError('failed to restrict permissions for $path');
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'cloud_connection.dart';
import 'local_ipc.dart';

typedef AgentEngineStatusProvider = Future<Map<String, Object?>> Function();

class AgentEngineConfig {
  const AgentEngineConfig({
    required this.dataDirectory,
    this.cloudUri,
    this.agentId,
    this.workspaceId,
    this.authToken,
    this.ipcPort,
    this.ipcToken,
  });

  final Directory dataDirectory;
  final Uri? cloudUri;
  final String? agentId;
  final String? workspaceId;
  final String? authToken;
  final int? ipcPort;
  final String? ipcToken;

  factory AgentEngineConfig.fromArgs(List<String> args) {
    final index = args.indexOf('--data-dir');
    final cloudIndex = args.indexOf('--cloud-url');
    final agentIndex = args.indexOf('--agent-id');
    final workspaceIndex = args.indexOf('--workspace-id');
    final path = index >= 0 && index + 1 < args.length
        ? args[index + 1]
        : Platform.environment['CONCLAVE_AGENT_DATA_DIR'];
    final cloudUrl = cloudIndex >= 0 && cloudIndex + 1 < args.length
        ? args[cloudIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_CLOUD_URL'];
    final agentId = agentIndex >= 0 && agentIndex + 1 < args.length
        ? args[agentIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_ID'];
    final workspaceId = workspaceIndex >= 0 && workspaceIndex + 1 < args.length
        ? args[workspaceIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_WORKSPACE_ID'];
    final ipcPortIndex = args.indexOf('--ipc-port');
    final ipcTokenIndex = args.indexOf('--ipc-token');
    final ipcPortValue = ipcPortIndex >= 0 && ipcPortIndex + 1 < args.length
        ? args[ipcPortIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_IPC_PORT'];
    final ipcToken = ipcTokenIndex >= 0 && ipcTokenIndex + 1 < args.length
        ? args[ipcTokenIndex + 1]
        : Platform.environment['CONCLAVE_AGENT_IPC_TOKEN'];
    return AgentEngineConfig(
      dataDirectory: Directory(path ??
          '${Platform.environment['HOME'] ?? Directory.current.path}/.conclave-agent'),
      cloudUri: cloudUrl == null ? null : Uri.tryParse(cloudUrl),
      agentId: agentId,
      workspaceId: workspaceId,
      authToken: Platform.environment['CONCLAVE_AGENT_TOKEN'],
      ipcPort: ipcPortValue == null ? null : int.tryParse(ipcPortValue),
      ipcToken: ipcToken,
    );
  }
}

class AgentEngineLogger {
  AgentEngineLogger(this._output);
  final IOSink _output;

  void info(String message, [Map<String, Object?> details = const {}]) {
    final record = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'info',
      'message': message,
      if (details.isNotEmpty) 'details': details,
    };
    _output.writeln(jsonEncode(record));
  }
}

class AgentEngine {
  AgentEngine({
    required this.config,
    IOSink? logOutput,
    this.cloudConnection,
    this.statusProvider,
  }) : _log = AgentEngineLogger(logOutput ?? stdout);

  final AgentEngineConfig config;
  final AgentCloudConnection? cloudConnection;
  final AgentEngineStatusProvider? statusProvider;
  final AgentEngineLogger _log;
  RandomAccessFile? _lock;
  LocalIpcServer? _ipc;
  bool _running = false;
  StreamSubscription<ProcessSignal>? _sigint;
  StreamSubscription<ProcessSignal>? _sigterm;

  bool get isRunning => _running;
  int? get ipcPort => _ipc?.port;

  Future<Map<String, Object?>> _handleIpcCommand(IpcCommand command) async {
    if (command.type != 'engine.status') {
      throw StateError('unsupported engine command: ${command.type}');
    }
    final provided = await statusProvider?.call() ?? const <String, Object?>{};
    return {
      'online': _running,
      'status': _running ? 'running' : 'stopped',
      'workers': 0,
      'plugins': 0,
      'activeTasks': 0,
      'version': '0.1.0',
      ...provided,
    };
  }

  Future<void> start() async {
    if (_running) return;
    await config.dataDirectory.create(recursive: true);
    await _restrictPermissions(config.dataDirectory.path, directory: true);
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

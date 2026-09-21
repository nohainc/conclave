import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';

class AgentEngineConfig {
  const AgentEngineConfig({
    required this.dataDirectory,
    this.cloudUri,
    this.agentId,
    this.workspaceId,
    this.authToken,
  });

  final Directory dataDirectory;
  final Uri? cloudUri;
  final String? agentId;
  final String? workspaceId;
  final String? authToken;

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
    return AgentEngineConfig(
      dataDirectory: Directory(path ??
          '${Platform.environment['HOME'] ?? Directory.current.path}/.conclave-agent'),
      cloudUri: cloudUrl == null ? null : Uri.tryParse(cloudUrl),
      agentId: agentId,
      workspaceId: workspaceId,
      authToken: Platform.environment['CONCLAVE_AGENT_TOKEN'],
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
  }) : _log = AgentEngineLogger(logOutput ?? stdout);

  final AgentEngineConfig config;
  final AgentCloudConnection? cloudConnection;
  final AgentEngineLogger _log;
  RandomAccessFile? _lock;
  bool _running = false;
  StreamSubscription<ProcessSignal>? _sigint;
  StreamSubscription<ProcessSignal>? _sigterm;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    await config.dataDirectory.create(recursive: true);
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
}

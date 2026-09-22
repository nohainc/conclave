import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';
import 'host_configuration.dart';
import 'secure_credentials.dart';
import 'platform_runtime.dart';

typedef HostStatusProvider = Future<Map<String, Object?>> Function();
typedef HostUpdateHandler = Future<Map<String, Object?>> Function(
  Map<String, Object?> request,
);

class HostConfig {
  const HostConfig({
    required this.dataDirectory,
    this.cloudUri,
    this.hostId,
    this.workspaceId,
    this.repositoriesFile,
    this.authToken,
  });

  final Directory dataDirectory;
  final Uri? cloudUri;
  final String? hostId;
  final String? workspaceId;
  final String? repositoriesFile;
  final String? authToken;

  factory HostConfig.fromArgs(
    List<String> args, {
    SecureCredentialStore? credentialStore,
  }) {
    final index = args.indexOf('--data-dir');
    final cloudIndex = args.indexOf('--cloud-url');
    final hostIndex = args.indexOf('--host-id');
    final workspaceIndex = args.indexOf('--workspace-id');
    final repositoriesIndex = args.indexOf('--repositories');
    final path = index >= 0 && index + 1 < args.length
        ? args[index + 1]
        : Platform.environment['CONCLAVE_HOST_DATA_DIR'];
    final dataDirectory = Directory(path ??
        '${currentPlatformRuntime.homeDirectory}${Platform.pathSeparator}.conclave-host');
    final registration = HostRegistrationStore(dataDirectory).readSync();
    final cloudUrl = cloudIndex >= 0 && cloudIndex + 1 < args.length
        ? args[cloudIndex + 1]
        : Platform.environment['CONCLAVE_HOST_CLOUD_URL'];
    final hostId = hostIndex >= 0 && hostIndex + 1 < args.length
        ? args[hostIndex + 1]
        : Platform.environment['CONCLAVE_HOST_ID'] ?? registration?.hostId;
    final workspaceId = workspaceIndex >= 0 && workspaceIndex + 1 < args.length
        ? args[workspaceIndex + 1]
        : Platform.environment['CONCLAVE_HOST_WORKSPACE_ID'] ??
            registration?.workspaceId;
    final repositoriesFile =
        repositoriesIndex >= 0 && repositoriesIndex + 1 < args.length
            ? args[repositoriesIndex + 1]
            : Platform.environment['CONCLAVE_HOST_REPOSITORIES'];
    final secureStore =
        credentialStore ?? const PlatformSecureCredentialStore();
    final storedToken = hostId == null ? null : secureStore.readSync(hostId);
    final configuredCloudUrl = cloudUrl ?? registration?.cloudUrl;
    final configuredCloudUri =
        configuredCloudUrl == null ? null : _cloudSocketUri(configuredCloudUrl);
    return HostConfig(
      dataDirectory: dataDirectory,
      cloudUri: configuredCloudUri,
      hostId: hostId,
      workspaceId: workspaceId,
      repositoriesFile: repositoriesFile,
      authToken: Platform.environment['CONCLAVE_HOST_TOKEN'] ?? storedToken,
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
          '${uri.path.replaceFirst(RegExp(r'/$'), '')}/api/host-gateway/connect',
    );
  }
}

class HostLogger {
  HostLogger(this._output, {this.redact = _identity});
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

class Host {
  Host({
    required this.config,
    IOSink? logOutput,
    this.cloudConnection,
    this.statusProvider,
    this.updateStatusProvider,
    this.updateHandler,
    String Function(String)? redactLog,
    this.logFileMaxBytes = 1024 * 1024,
  })  : _configuredLogOutput = logOutput,
        _log = HostLogger(logOutput ?? stdout,
            redact: redactLog ?? HostLogger._identity) {
    if (logFileMaxBytes <= 0) {
      throw ArgumentError.value(
          logFileMaxBytes, 'logFileMaxBytes', 'must be positive');
    }
  }

  final HostConfig config;
  final HostCloudConnection? cloudConnection;
  final HostStatusProvider? statusProvider;
  final HostStatusProvider? updateStatusProvider;
  final HostUpdateHandler? updateHandler;
  final IOSink? _configuredLogOutput;
  final int logFileMaxBytes;
  final HostLogger _log;
  IOSink? _ownedLogOutput;
  RandomAccessFile? _lock;
  bool _running = false;
  final List<StreamSubscription<ProcessSignal>> _signalSubscriptions = [];

  bool get isRunning => _running;
  Future<void> start() async {
    if (_running) return;
    await config.dataDirectory.create(recursive: true);
    await currentPlatformRuntime.restrictPermissions(
      config.dataDirectory.path,
      directory: true,
    );
    if (_configuredLogOutput == null) {
      _ownedLogOutput = await _openLogFile();
      _log.attach(_ownedLogOutput!);
    }
    final lockFile = File('${config.dataDirectory.path}/host.lock');
    try {
      _lock = await lockFile.open(mode: FileMode.writeOnlyAppend);
      await _lock!.lock(FileLock.exclusive);
    } on FileSystemException {
      await _lock?.close();
      _lock = null;
      throw StateError('another Host instance already owns the lock');
    }
    await File('${config.dataDirectory.path}/host-state.json').writeAsString(
      jsonEncode({
        'status': 'running',
        'startedAt': DateTime.now().toUtc().toIso8601String()
      }),
    );
    _running = true;
    _signalSubscriptions.addAll(
      currentPlatformRuntime.watchTermination(() => unawaited(stop())),
    );
    try {
      await cloudConnection?.connect();
    } on Object {
      await stop();
      rethrow;
    }
    _log.info('Host started', {'dataDirectory': config.dataDirectory.path});
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    for (final subscription in _signalSubscriptions) {
      await subscription.cancel();
    }
    _signalSubscriptions.clear();
    await cloudConnection?.close();
    await File('${config.dataDirectory.path}/host-state.json').writeAsString(
      jsonEncode({
        'status': 'stopped',
        'stoppedAt': DateTime.now().toUtc().toIso8601String()
      }),
    );
    await _lock?.unlock();
    await _lock?.close();
    _lock = null;
    _log.info('Host stopped');
    await _ownedLogOutput?.flush();
    await _ownedLogOutput?.close();
    _ownedLogOutput = null;
    if (_configuredLogOutput == null) _log.attach(stdout);
  }

  Future<IOSink> _openLogFile() async {
    final logsDirectory = Directory('${config.dataDirectory.path}/logs');
    await logsDirectory.create(recursive: true);
    await currentPlatformRuntime.restrictPermissions(logsDirectory.path,
        directory: true);
    final current = File('${logsDirectory.path}/host.log');
    if (await current.exists() && await current.length() >= logFileMaxBytes) {
      final previous = File('${logsDirectory.path}/host.log.1');
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    }
    final output = current.openWrite(mode: FileMode.append);
    await currentPlatformRuntime.restrictPermissions(current.path,
        directory: false);
    return output;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';
import 'worker_protocol.dart';
import 'process_tree.dart';
import 'worker_trust_policy.dart';

Object? _redactValue(Object? value, Iterable<String> secrets) {
  if (value is String) return redactSecrets(value, secrets);
  if (value is List) {
    return value.map((item) => _redactValue(item, secrets)).toList();
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key: _redactValue(entry.value, secrets),
    };
  }
  return value;
}

class WorkerProcessSpec {
  const WorkerProcessSpec({
    required this.workerId,
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.allowedEnvironmentVariables = const {},
    this.secretValues = const {},
  });

  final String workerId;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final Set<String> allowedEnvironmentVariables;
  final Set<String> secretValues;
}

typedef WorkerProcessLauncher = Future<Process> Function(
    WorkerProcessSpec spec);
typedef WorkerProcessResolver = FutureOr<WorkerProcessSpec?> Function(
  String workerId,
);
typedef WorkerProcessTerminator = Future<void> Function(
  Process process, {
  required bool force,
});

class WorkerProcessExecutor {
  WorkerProcessExecutor({
    WorkerProcessLauncher? launcher,
    WorkerProcessTerminator? terminator,
  })  : _launcher = launcher ?? _launch,
        _terminator = terminator ?? terminateProcessTree;

  final WorkerProcessLauncher _launcher;
  final WorkerProcessTerminator _terminator;
  int _requestSequence = 0;
  final _activeProcesses = <String, Process>{};
  final _activeResponses = <String, Completer<Map<String, Object?>>>{};
  final _cancelledOperations = <String>{};
  final _activeCancellations = <String, void Function()>{};

  static Future<Process> _launch(WorkerProcessSpec spec) {
    final executableName = spec.executable.split(Platform.pathSeparator).last;
    final arguments = executableName == 'dart' || executableName == 'dart.exe'
        ? ['--disable-analytics', ...spec.arguments]
        : spec.arguments;
    return startIsolatedProcess(
      spec.executable,
      arguments,
      workingDirectory: spec.workingDirectory,
      environment: safeWorkerEnvironment(
        spec.environment,
        allowedNames: spec.allowedEnvironmentVariables,
      ),
    );
  }

  Future<Map<String, Object?>> execute(
    WorkerProcessSpec spec,
    Map<String, Object?> params, {
    Duration timeout = const Duration(minutes: 5),
    int maxStdoutBytes = 1024 * 1024,
    int maxStderrBytes = 1024 * 1024,
    String? operationId,
  }) async {
    if (maxStdoutBytes <= 0 || maxStderrBytes <= 0) {
      throw ArgumentError('worker output limits must be positive');
    }
    final process = await _launcher(spec);
    final requestId = 'host-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_requestSequence}';
    final processId = operationId ?? requestId;
    _activeProcesses[processId] = process;
    final pending = <String, Completer<Map<String, Object?>>>{};
    final response = Completer<Map<String, Object?>>();
    _activeResponses[processId] = response;
    _activeCancellations[processId] = () {
      for (final pendingResponse in pending.values) {
        if (!pendingResponse.isCompleted) {
          pendingResponse.completeError(
            ProcessException(
              'cancelled',
              const [],
              'Worker assignment cancelled',
            ),
          );
        }
      }
    };
    var stdoutBytes = 0;
    var stderrBytes = 0;
    final stderrPreview = StringBuffer();
    void fail(String message) {
      for (final pendingResponse in pending.values) {
        if (!pendingResponse.isCompleted) {
          pendingResponse.completeError(StateError(message));
        }
      }
      unawaited(_terminator(process, force: true));
    }

    final boundedStdout = process.stdout.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          stdoutBytes += chunk.length;
          if (stdoutBytes > maxStdoutBytes) {
            fail('worker stdout exceeded $maxStdoutBytes bytes');
            sink.close();
            return;
          }
          sink.add(chunk);
        },
      ),
    );
    final stdoutSubscription = boundedStdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (response.isCompleted || line.trim().isEmpty) return;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic> && decoded['id'] == null) {
          WorkerRpcNotification.parse(decoded);
          return;
        }
        final rpc = WorkerRpcResponse.parse(decoded);
        final pendingResponse = pending[rpc.id];
        if (pendingResponse == null || pendingResponse.isCompleted) return;
        if (rpc.error != null) {
          pendingResponse.completeError(StateError(
              '${rpc.error!['message'] ?? 'worker request failed'}'));
          return;
        }
        pendingResponse.complete(rpc.result!);
      } on Object catch (error) {
        // `dart run` may emit its VM service banner on stdout before the
        // worker starts. It is launcher noise, not a worker protocol frame.
        if (line.startsWith('The Dart VM service is listening on ')) return;
        for (final pendingResponse in pending.values) {
          if (!pendingResponse.isCompleted) {
            pendingResponse.completeError(error);
          }
        }
      }
    });
    final stderrSubscription = process.stderr.listen((chunk) {
      stderrBytes += chunk.length;
      if (stderrPreview.length < 4096) {
        stderrPreview.write(utf8.decode(chunk, allowMalformed: true));
      }
      if (stderrBytes > maxStderrBytes) {
        fail('worker stderr exceeded $maxStderrBytes bytes');
      }
    });
    unawaited(process.exitCode.then((exitCode) {
      if (!_cancelledOperations.contains(processId) &&
          pending.values
              .any((pendingResponse) => !pendingResponse.isCompleted)) {
        fail('worker process exited with code $exitCode before completing');
      }
    }));
    Future<Map<String, Object?>> request(
      String method,
      Map<String, Object?> params,
    ) async {
      final id = method == 'execute' ? requestId : '$requestId-$method';
      final pendingResponse =
          method == 'execute' ? response : Completer<Map<String, Object?>>();
      pending[id] = pendingResponse;
      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }));
      await process.stdin.flush();
      return pendingResponse.future;
    }

    try {
      final execution = () async {
        final initialized = await request('initialize', {
          'workerId': spec.workerId,
          'protocolVersion': workerProtocolVersion,
        });
        final identity = WorkerIdentity.parse(initialized);
        if (identity.workerId != spec.workerId ||
            identity.protocolVersion != workerProtocolVersion) {
          throw StateError('worker handshake identity is invalid');
        }
        final health = await request('health', {});
        if (health['status'] != 'healthy') {
          throw StateError('worker health check failed');
        }
        return await request('execute', params);
      }();
      final result = await execution.timeout(
        timeout,
        onTimeout: () {
          fail('worker execution timed out after $timeout');
          throw TimeoutException(
            'worker execution timed out; stderr: ${redactSecrets(stderrPreview.toString(), spec.secretValues)}',
            timeout,
          );
        },
      );
      final redacted = _redactValue(result, spec.secretValues);
      return Map<String, Object?>.from(redacted as Map);
    } finally {
      await process.stdin.close();
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      await _terminator(process, force: false);
      _activeProcesses.remove(processId);
      _activeResponses.remove(processId);
      _cancelledOperations.remove(processId);
      _activeCancellations.remove(processId);
    }
  }

  Future<bool> cancel(String operationId) async {
    final process = _activeProcesses[operationId];
    if (process == null) return false;
    _activeProcesses.remove(operationId);
    _cancelledOperations.add(operationId);
    _activeCancellations.remove(operationId)?.call();
    await _terminator(process, force: false);
    return true;
  }
}

Map<String, String> safeWorkerEnvironment(
  Map<String, String> requested, {
  Set<String> allowedNames = const {},
}) {
  final environment = <String, String>{};
  for (final name in const [
    'PATH',
    'HOME',
    'USERPROFILE',
    'TMPDIR',
    'TMP',
    'TEMP',
    'SystemRoot',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
  ]) {
    final value = Platform.environment[name];
    if (value != null && value.isNotEmpty) environment[name] = value;
  }
  // Worker processes are non-interactive. Prevent language runtimes from
  // blocking on first-run telemetry prompts while the Host is executing.
  environment['DART_SUPPRESS_ANALYTICS'] = '1';
  for (final entry in requested.entries) {
    if (allowedNames.contains(entry.key)) environment[entry.key] = entry.value;
  }
  return environment;
}

class WorkerAssignmentHandler {
  const WorkerAssignmentHandler({
    required this.executor,
    required this.resolve,
    this.resolveRepositoryPath,
  });

  final WorkerProcessExecutor executor;
  final WorkerProcessResolver resolve;
  final Future<String?> Function(String repositoryId)? resolveRepositoryPath;

  Future<HostAssignmentResult> call(HostAssignmentContext context) async {
    final workerId = context.payload['workerId'];
    if (workerId is! String || workerId.isEmpty) {
      throw StateError('assignment workerId is required');
    }
    final spec = await resolve(workerId);
    if (spec == null) throw StateError('worker is not installed: $workerId');
    final workerPayload =
        await _repositoryScopedPayload(context.payload, context);
    final output = await executor.execute(
      spec,
      workerPayload,
      operationId: context.assignmentId,
    );
    final summary = output['summary'];
    final nestedOutput = output['output'];
    return HostAssignmentResult(
      summary: summary is String && summary.isNotEmpty
          ? summary
          : 'Worker $workerId completed assignment',
      output: nestedOutput is Map
          ? Map<String, Object?>.from(nestedOutput)
          : output,
      artifactIds: output['artifactIds'] is List
          ? (output['artifactIds'] as List).whereType<String>().toList()
          : const [],
    );
  }

  Future<bool> cancel(String assignmentId, String reason) =>
      executor.cancel(assignmentId);

  Future<Map<String, Object?>> _repositoryScopedPayload(
    Map<String, Object?> payload,
    HostAssignmentContext context,
  ) async {
    final resolver = resolveRepositoryPath;
    if (resolver == null) return _withCorrelation(payload, context);
    final input = payload['input'] is Map
        ? Map<String, Object?>.from(payload['input'] as Map)
        : <String, Object?>{};
    final request = input['request'] is Map
        ? Map<String, Object?>.from(input['request'] as Map)
        : const <String, Object?>{};
    final repository = payload['repository'] is Map
        ? Map<String, Object?>.from(payload['repository'] as Map)
        : const <String, Object?>{};
    final repositoryId = _firstString([
      payload['repositoryId'],
      repository['repositoryId'],
      input['repositoryId'],
      request['repositoryId'],
    ]);
    final suppliedPath = _firstString([
      payload['repositoryPath'],
      input['repositoryPath'],
    ]);
    if (repositoryId == null) {
      if (suppliedPath != null) {
        throw StateError('repositoryPath requires a registered repositoryId');
      }
      return _withCorrelation(payload, context);
    }
    final path = await resolver(repositoryId);
    if (path == null) {
      throw StateError(
          'repository is not registered on this Host: $repositoryId');
    }
    return _withCorrelation(
      {
        ...payload,
        'repositoryId': repositoryId,
        'repositoryPath': path,
        'input': {
          ...input,
          'repositoryId': repositoryId,
          'repositoryPath': path
        },
      },
      context,
    );
  }

  Map<String, Object?> _withCorrelation(
    Map<String, Object?> payload,
    HostAssignmentContext context,
  ) =>
      {
        ...payload,
        'conclave': {
          'workspaceId': context.workspaceId,
          'hostId': context.hostId,
          'workerId': context.workerId,
          'runId': context.runId,
          'taskId': context.taskId,
          'attemptId': context.attemptId,
          'assignmentId': context.assignmentId,
          'idempotencyKey': context.idempotencyKey,
        },
      };

  String? _firstString(Iterable<Object?> values) {
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }
}

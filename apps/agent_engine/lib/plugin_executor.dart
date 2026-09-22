import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';
import 'process_tree.dart';

class PluginProcessSpec {
  const PluginProcessSpec({
    required this.pluginId,
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.allowedEnvironmentVariables = const {},
  });

  final String pluginId;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final Set<String> allowedEnvironmentVariables;
}

typedef PluginProcessLauncher = Future<Process> Function(
    PluginProcessSpec spec);
typedef PluginProcessResolver = FutureOr<PluginProcessSpec?> Function(
  String pluginId,
);
typedef PluginProcessTerminator = Future<void> Function(
  Process process, {
  required bool force,
});

class PluginProcessExecutor {
  PluginProcessExecutor({
    PluginProcessLauncher? launcher,
    PluginProcessTerminator? terminator,
  })  : _launcher = launcher ?? _launch,
        _terminator = terminator ?? terminateProcessTree;

  final PluginProcessLauncher _launcher;
  final PluginProcessTerminator _terminator;
  int _requestSequence = 0;
  final _activeProcesses = <String, Process>{};
  final _activeResponses = <String, Completer<Map<String, Object?>>>{};
  final _cancelledOperations = <String>{};
  final _activeCancellations = <String, void Function()>{};

  static Future<Process> _launch(PluginProcessSpec spec) =>
      startIsolatedProcess(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: safePluginEnvironment(
          spec.environment,
          allowedNames: spec.allowedEnvironmentVariables,
        ),
      );

  Future<Map<String, Object?>> execute(
    PluginProcessSpec spec,
    Map<String, Object?> params, {
    Duration timeout = const Duration(minutes: 5),
    int maxStdoutBytes = 1024 * 1024,
    int maxStderrBytes = 1024 * 1024,
    String? operationId,
  }) async {
    if (maxStdoutBytes <= 0 || maxStderrBytes <= 0) {
      throw ArgumentError('plugin output limits must be positive');
    }
    final process = await _launcher(spec);
    final requestId = 'agent-${DateTime.now().microsecondsSinceEpoch}-'
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
              'Plugin assignment cancelled',
            ),
          );
        }
      }
    };
    var stdoutBytes = 0;
    var stderrBytes = 0;
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
            fail('plugin stdout exceeded $maxStdoutBytes bytes');
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
        if (decoded is! Map<String, dynamic> || decoded['id'] is! String) {
          return;
        }
        final pendingResponse = pending[decoded['id'] as String];
        if (pendingResponse == null || pendingResponse.isCompleted) return;
        if (decoded['error'] is Map) {
          pendingResponse.completeError(
              StateError('${(decoded['error'] as Map)['message']}'));
          return;
        }
        final result = decoded['result'];
        if (result is! Map) {
          pendingResponse
              .completeError(StateError('plugin returned a non-object result'));
          return;
        }
        pendingResponse.complete(Map<String, Object?>.from(result));
      } on Object catch (error) {
        response.completeError(error);
      }
    });
    final stderrSubscription = process.stderr.listen((chunk) {
      stderrBytes += chunk.length;
      if (stderrBytes > maxStderrBytes) {
        fail('plugin stderr exceeded $maxStderrBytes bytes');
      }
    });
    unawaited(process.exitCode.then((exitCode) {
      if (!_cancelledOperations.contains(processId) &&
          pending.values
              .any((pendingResponse) => !pendingResponse.isCompleted)) {
        fail('plugin process exited with code $exitCode before completing');
      }
    }));
    Future<Map<String, Object?>> request(
      String method,
      Map<String, Object?> params,
    ) {
      final id =
          method == 'start_assignment' ? requestId : '$requestId-$method';
      final pendingResponse = method == 'start_assignment'
          ? response
          : Completer<Map<String, Object?>>();
      pending[id] = pendingResponse;
      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }));
      return pendingResponse.future;
    }

    try {
      final execution = () async {
        final initialized = await request('initialize', {
          'pluginId': spec.pluginId,
          'protocolVersion': '2.0',
        });
        if (initialized['pluginId'] != spec.pluginId ||
            initialized['protocolVersion'] != '2.0') {
          throw StateError('plugin handshake identity is invalid');
        }
        final health = await request('health', {});
        if (health['status'] != 'healthy') {
          throw StateError('plugin health check failed');
        }
        return await request('start_assignment', params);
      }();
      final result = await execution.timeout(
        timeout,
        onTimeout: () {
          fail('plugin execution timed out after $timeout');
          throw TimeoutException('plugin execution timed out', timeout);
        },
      );
      return result;
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

Map<String, String> safePluginEnvironment(
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
  for (final entry in requested.entries) {
    if (allowedNames.contains(entry.key)) environment[entry.key] = entry.value;
  }
  return environment;
}

class PluginAssignmentHandler {
  const PluginAssignmentHandler({
    required this.executor,
    required this.resolve,
    this.resolveRepositoryPath,
  });

  final PluginProcessExecutor executor;
  final PluginProcessResolver resolve;
  final Future<String?> Function(String repositoryId)? resolveRepositoryPath;

  Future<AgentAssignmentResult> call(AgentAssignmentContext context) async {
    final pluginId = context.payload['pluginId'];
    if (pluginId is! String || pluginId.isEmpty) {
      throw StateError('assignment pluginId is required');
    }
    final spec = await resolve(pluginId);
    if (spec == null) throw StateError('plugin is not installed: $pluginId');
    final pluginPayload =
        await _repositoryScopedPayload(context.payload, context);
    final output = await executor.execute(
      spec,
      pluginPayload,
      operationId: context.assignmentId,
    );
    final summary = output['summary'];
    final nestedOutput = output['output'];
    return AgentAssignmentResult(
      summary: summary is String && summary.isNotEmpty
          ? summary
          : 'Plugin $pluginId completed assignment',
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
    AgentAssignmentContext context,
  ) async {
    final resolver = resolveRepositoryPath;
    if (resolver == null) return _withCorrelation(payload, context);
    final input = payload['input'] is Map
        ? Map<String, Object?>.from(payload['input'] as Map)
        : <String, Object?>{};
    final request = input['request'] is Map
        ? Map<String, Object?>.from(input['request'] as Map)
        : const <String, Object?>{};
    final repositoryId = _firstString([
      payload['repositoryId'],
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
          'repository is not registered on this Agent: $repositoryId');
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
    AgentAssignmentContext context,
  ) =>
      {
        ...payload,
        'conclave': {
          'workspaceId': context.workspaceId,
          'agentId': context.agentId,
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

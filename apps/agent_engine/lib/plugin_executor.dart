import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';

class PluginProcessSpec {
  const PluginProcessSpec({
    required this.pluginId,
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
  });

  final String pluginId;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
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
        _terminator = terminator ?? _terminateTree;

  final PluginProcessLauncher _launcher;
  final PluginProcessTerminator _terminator;
  int _requestSequence = 0;
  final _activeProcesses = <String, Process>{};
  final _activeResponses = <String, Completer<Map<String, Object?>>>{};

  static Future<Process> _launch(PluginProcessSpec spec) async {
    final environment = spec.environment.isEmpty ? null : spec.environment;
    if (Platform.isWindows) {
      return Process.start(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: environment,
        runInShell: false,
      );
    }

    // setsid makes the plugin the leader of a new process group. This lets
    // timeout/cancel terminate descendants instead of leaving orphaned tools.
    try {
      return await Process.start(
        'setsid',
        [spec.executable, ...spec.arguments],
        workingDirectory: spec.workingDirectory,
        environment: environment,
        runInShell: false,
      );
    } on ProcessException {
      // Keep development environments without setsid usable. The direct
      // child is still terminated as a safe fallback.
      return Process.start(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: environment,
        runInShell: false,
      );
    }
  }

  static Future<void> _terminateTree(
    Process process, {
    required bool force,
  }) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', [
        '/PID',
        '${process.pid}',
        '/T',
        if (force) '/F',
      ]);
      return;
    }

    // A negative PID addresses the isolated process group created by setsid.
    final signal = force ? '-KILL' : '-TERM';
    final result = await Process.run('kill', [signal, '-${process.pid}']);
    if (result.exitCode != 0) {
      process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
    }
  }

  Future<Map<String, Object?>> execute(
    PluginProcessSpec spec,
    Map<String, Object?> params, {
    Duration timeout = const Duration(minutes: 5),
    int maxStdoutBytes = 1024 * 1024,
    int maxStderrBytes = 1024 * 1024,
    String? operationId,
  }) async {
    final process = await _launcher(spec);
    final requestId = 'agent-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_requestSequence}';
    final processId = operationId ?? requestId;
    _activeProcesses[processId] = process;
    final response = Completer<Map<String, Object?>>();
    _activeResponses[processId] = response;
    var stdoutBytes = 0;
    var stderrBytes = 0;
    void fail(String message) {
      if (!response.isCompleted) response.completeError(StateError(message));
      unawaited(_terminator(process, force: true));
    }

    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (response.isCompleted || line.trim().isEmpty) return;
      stdoutBytes += utf8.encode(line).length + 1;
      if (stdoutBytes > maxStdoutBytes) {
        fail('plugin stdout exceeded $maxStdoutBytes bytes');
        return;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic> || decoded['id'] != requestId) {
          return;
        }
        if (decoded['error'] is Map) {
          response.completeError(
              StateError('${(decoded['error'] as Map)['message']}'));
          return;
        }
        final result = decoded['result'];
        if (result is! Map) {
          response
              .completeError(StateError('plugin returned a non-object result'));
          return;
        }
        response.complete(Map<String, Object?>.from(result));
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
    try {
      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': requestId,
        'method': 'start_assignment',
        'params': params,
      }));
      process.stdin.close();
      final result = await response.future.timeout(
        timeout,
        onTimeout: () {
          fail('plugin execution timed out after $timeout');
          throw TimeoutException('plugin execution timed out', timeout);
        },
      );
      return result;
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      await _terminator(process, force: false);
      _activeProcesses.remove(processId);
      _activeResponses.remove(processId);
    }
  }

  Future<bool> cancel(String operationId) async {
    final process = _activeProcesses[operationId];
    if (process == null) return false;
    _activeProcesses.remove(operationId);
    final response = _activeResponses[operationId];
    if (response != null && !response.isCompleted) {
      response.completeError(
        ProcessException('cancelled', const [], 'Plugin assignment cancelled'),
      );
    }
    await _terminator(process, force: false);
    return true;
  }
}

class PluginAssignmentHandler {
  const PluginAssignmentHandler({
    required this.executor,
    required this.resolve,
  });

  final PluginProcessExecutor executor;
  final PluginProcessResolver resolve;

  Future<AgentAssignmentResult> call(AgentAssignmentContext context) async {
    final pluginId = context.payload['pluginId'];
    if (pluginId is! String || pluginId.isEmpty) {
      throw StateError('assignment pluginId is required');
    }
    final spec = await resolve(pluginId);
    if (spec == null) throw StateError('plugin is not installed: $pluginId');
    final output = await executor.execute(
      spec,
      context.payload,
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
}

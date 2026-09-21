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

class PluginProcessExecutor {
  PluginProcessExecutor({PluginProcessLauncher? launcher})
      : _launcher = launcher ?? _launch;

  final PluginProcessLauncher _launcher;
  int _requestSequence = 0;

  static Future<Process> _launch(PluginProcessSpec spec) => Process.start(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: spec.environment.isEmpty ? null : spec.environment,
        runInShell: false,
      );

  Future<Map<String, Object?>> execute(
    PluginProcessSpec spec,
    Map<String, Object?> params, {
    Duration timeout = const Duration(minutes: 5),
    int maxStdoutBytes = 1024 * 1024,
    int maxStderrBytes = 1024 * 1024,
  }) async {
    final process = await _launcher(spec);
    final requestId = 'agent-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_requestSequence}';
    final response = Completer<Map<String, Object?>>();
    var stdoutBytes = 0;
    var stderrBytes = 0;
    void fail(String message) {
      if (!response.isCompleted) response.completeError(StateError(message));
      process.kill(ProcessSignal.sigterm);
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
      process.kill(ProcessSignal.sigterm);
    }
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
    final output = await executor.execute(spec, context.payload);
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
}

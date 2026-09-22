import 'dart:convert';
import 'dart:io';

import 'package:conclave_claude_code_plugin/claude_code_manifest.dart';
import 'package:conclave_claude_code_plugin/claude_code_worker.dart';

Future<void> main() async {
  final worker = ClaudeCodeWorker();
  final active = <String, ClaudeCodeCancellationToken>{};
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final method = request['method'];
      if (method == 'cancel_assignment' || method == 'cancelAssignment') {
        final params = request['params'] is Map
            ? Map<String, Object?>.from(request['params'] as Map)
            : const <String, Object?>{};
        final assignmentId = params['assignmentId'] ?? params['id'];
        if (assignmentId is! String || assignmentId.isEmpty) {
          throw const FormatException('assignmentId is required');
        }
        active.remove(assignmentId)?.cancel();
        _writeResponse(request['id'], {'cancelled': true});
        continue;
      }
      if (method == 'start_assignment' || method == 'startAssignment') {
        final assignmentId = request['id'];
        if (assignmentId is! String || assignmentId.isEmpty) {
          throw const FormatException('assignment id is required');
        }
        final token = ClaudeCodeCancellationToken();
        active[assignmentId] = token;
        unawaited(_executeAssignment(worker, request, token).then((result) {
          active.remove(assignmentId);
          _writeResponse(assignmentId, result);
        }, onError: (Object error, StackTrace stack) {
          active.remove(assignmentId);
          _writeError(assignmentId, error);
        }));
        continue;
      }
      final result = switch (method) {
        'initialize' => {
            'pluginId': claudeCodePluginManifest['pluginId'],
            'version': claudeCodePluginManifest['version'],
            'protocolVersion': claudeCodePluginManifest['protocolVersion'],
            'runtimeLanguage': 'dart',
            'capabilities': claudeCodePluginManifest['capabilities'],
          },
        'health' => await _health(worker),
        'get_capabilities' || 'getCapabilities' => {
            'capabilities': claudeCodePluginManifest['capabilities'],
          },
        'configure_worker' || 'configureWorker' => {'configured': true},
        'shutdown' => {'stopped': true},
        _ => throw StateError('unsupported method'),
      };
      _writeResponse(request['id'], result);
    } on Object catch (error) {
      _writeError(request['id'], error);
    }
  }
}

Future<Map<String, Object?>> _health(ClaudeCodeWorker worker) async {
  final status = await worker.availability();
  return {
    'status': status.installed && status.authenticated
        ? 'healthy'
        : 'unavailable',
    'installed': status.installed,
    'authenticated': status.authenticated,
    if (status.version != null) 'version': status.version,
  };
}

void _writeResponse(Object? id, Map<String, Object?> result) {
  stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
}

void _writeError(Object? id, Object error) {
  stdout.writeln(jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': -32000, 'message': '$error'},
  }));
}

Future<Map<String, Object?>> _executeAssignment(
  ClaudeCodeWorker worker,
  Map<String, dynamic> request,
  ClaudeCodeCancellationToken cancellation,
) async {
  final params = Map<String, Object?>.from(request['params'] as Map);
  final objective = params['objective'];
  if (objective is! String || objective.trim().isEmpty) {
    throw const FormatException('assignment objective is required');
  }
  final input = params['input'] is Map
      ? Map<String, Object?>.from(params['input'] as Map)
      : const <String, Object?>{};
  final result = await worker.executeTask(
    objective,
    input: input,
    workingDirectory: input['repositoryPath'] is String
        ? input['repositoryPath'] as String
        : null,
    cancellation: cancellation,
  );
  return {
    'status': 'completed',
    'summary': result.summary,
    'output': result.output,
    'evidence': {
      'metrics': {'events': result.events.length},
      'logs': ['Claude Code returned structured JSON output'],
    },
  };
}

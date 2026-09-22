import 'dart:convert';
import 'dart:io';
import 'package:conclave_codex_plugin/codex_worker.dart';
import 'package:conclave_codex_plugin/codex_manifest.dart';

Future<void> main() async {
  final worker = CodexWorker();
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final result = switch (request['method']) {
        'initialize' => {
            'pluginId': codexPluginManifest['pluginId'],
            'protocolVersion': codexPluginManifest['protocolVersion']
          },
        'health' => {
            'status': (await worker.availability()).installed
                ? 'healthy'
                : 'unavailable'
          },
        'start_assignment' => await _executeAssignment(worker, request),
        'shutdown' => {'stopped': true},
        _ => throw StateError('unsupported method'),
      };
      stdout.writeln(jsonEncode(
          {'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
    } on Object catch (error) {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'error': {'code': -32000, 'message': '$error'}
      }));
    }
  }
}

Future<Map<String, Object?>> _executeAssignment(
  CodexWorker worker,
  Map<String, dynamic> request,
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
  );
  return {
    'status': 'completed',
    'summary': result.summary,
    'output': result.output,
    'evidence': {
      'metrics': {'events': result.events.length},
      'logs': ['Codex returned structured JSON output'],
    },
  };
}

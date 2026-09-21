import 'dart:convert';
import 'dart:io';

import 'package:conclave_agent_engine/forge_pipeline.dart';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final result = switch (request['method']) {
        'initialize' => {
            'pluginId': 'conclave.forge',
            'protocolVersion': '2.0',
          },
        'health' => {'status': 'healthy'},
        'start_assignment' => await _runAssignment(request['params']),
        'shutdown' => {'stopped': true},
        _ => throw StateError('unsupported method'),
      };
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': result,
      }));
    } on Object catch (error) {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'error': {'code': -32000, 'message': '$error'},
      }));
    }
  }
}

Future<Map<String, Object?>> _runAssignment(Object? rawParams) async {
  if (rawParams is! Map || rawParams['input'] is! Map) {
    throw StateError('Forge assignment input is required');
  }
  final input = Map<String, Object?>.from(rawParams['input'] as Map);
  final repositoryPath = input['repositoryPath'];
  if (repositoryPath is! String || repositoryPath.isEmpty) {
    throw StateError('Forge repositoryPath is required');
  }
  final completion =
      await DartForgePipeline().execute(Directory(repositoryPath));
  final evidence = completion.evidence
      .map((item) => {
            'phase': item.phase,
            'summary': item.summary,
            'artifacts': item.artifacts,
            if (item.exitCode != null) 'exitCode': item.exitCode,
            if (item.command.isNotEmpty) 'command': item.command,
            if (item.stderr.isNotEmpty) 'stderr': item.stderr,
            if (item.revision != null) 'revision': item.revision,
            'findings': item.findings,
            if (item.verification != null) 'verification': item.verification,
          })
      .toList();
  return {
    'status': completion.completed ? 'completed' : 'failed',
    'summary': completion.completed
        ? 'Forge completed and verified the repository change'
        : 'Forge did not satisfy the repository acceptance checks',
    'output': {
      'completed': completion.completed,
      'completionReport': completion.completionReport,
      'evidence': evidence,
    },
    'artifactIds': const <String>[],
  };
}

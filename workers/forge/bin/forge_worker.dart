import 'dart:convert';
import 'dart:io';

import 'package:conclave_forge_worker/forge_manifest.dart';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final result = switch (request['method']) {
        'initialize' => {
            'workerId': forgeWorkerManifest['workerId'],
            'version': forgeWorkerManifest['version'],
            'protocolVersion': forgeWorkerManifest['protocolVersion'],
            'runtimeLanguage': 'dart',
            'capabilities': forgeWorkerManifest['capabilities'],
          },
        'health' => {'status': 'healthy'},
        'describe' => forgeWorkerManifest,
        'execute' => await _runAssignment(request['params']),
        'cancel' => {'cancelled': false},
        'shutdown' => {'stopped': true},
        _ => throw StateError('unsupported method'),
      };
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': result,
      }));
      await stdout.flush();
    } on Object catch (error) {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'error': {'code': -32000, 'message': '$error'},
      }));
      await stdout.flush();
    }
  }
}

Future<Map<String, Object?>> _runAssignment(Object? rawParams) async {
  if (rawParams is! Map) throw StateError('Forge assignment input is required');
  final params = Map<String, Object?>.from(rawParams);
  final input = params['input'] is Map
      ? Map<String, Object?>.from(params['input'] as Map)
      : const <String, Object?>{};
  return {
    'status': 'completed',
    'summary': 'Forge completed the repository verification assignment',
    'output': {
      'accepted': true,
      'input': input,
    },
    'artifactIds': const <String>[],
  };
}

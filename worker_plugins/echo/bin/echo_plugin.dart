import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    final method = request['method'];
    final params = request['params'] is Map
        ? Map<String, Object?>.from(request['params'] as Map)
        : const <String, Object?>{};
    if (method == 'start_assignment') {
      final input = params['input'] is Map
          ? Map<String, Object?>.from(params['input'] as Map)
          : const <String, Object?>{};
      final delayMs = input['delayMs'];
      if (delayMs is int && delayMs > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: delayMs.clamp(0, 10000)),
        );
      }
      if (input['fail'] == true) {
        stdout.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {
            'code': -32001,
            'message': 'Deterministic echo failure',
          },
        }));
        continue;
      }
      final artifactIds = input['artifactIds'] is List
          ? (input['artifactIds'] as List).whereType<String>().toList()
          : const <String>[];
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          'status': 'completed',
          'summary': 'Deterministic echo worker completed assignment',
          'input': params,
          'artifactIds': artifactIds,
          'evidence': {
            'kind': 'deterministic_echo',
            'delayMs': delayMs is int ? delayMs : 0,
          },
        },
      }));
      continue;
    }
    final result = switch (method) {
      'initialize' => {
        'pluginId': 'conclave.echo',
        'version': '1.0.0',
        'protocolVersion': '2.0',
        'runtimeLanguage': 'dart',
        'capabilities': ['deterministic_echo'],
      },
      'health' => {'status': 'healthy'},
      'configure_worker' => {'configured': true},
      'cancel_assignment' => {'cancelled': true},
      'shutdown' => {'stopped': true},
      _ => throw StateError('unsupported method'),
    };
    stdout.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:conclave_codex_plugin/codex_worker.dart';

Future<void> main() async {
  final worker = CodexWorker();
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final result = switch (request['method']) {
        'initialize' => {
            'pluginId': 'conclave.codex',
            'protocolVersion': '2.0'
          },
        'health' => {'status': 'healthy'},
        'start_assignment' => {
            'status': 'completed',
            'output':
                await worker.execute(request['params']['objective'] as String)
          },
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

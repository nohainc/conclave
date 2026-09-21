import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    final method = request['method'];
    final result = switch (method) {
      'initialize' => {'protocolVersion': '2.0', 'pluginId': 'conclave.echo'},
      'health' => {'status': 'healthy'},
      'configure_worker' => {'configured': true},
      'start_assignment' => {
          'status': 'completed',
          'summary': 'Deterministic echo worker completed assignment',
          'input': request['params'],
        },
      'cancel_assignment' => {'cancelled': true},
      'shutdown' => {'stopped': true},
      _ => throw StateError('unsupported method'),
    };
    stdout.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
  }
}

import 'dart:io';

import 'package:syntila_cli_worker_engine/src/model_discovery.dart';
import 'package:test/test.dart';

/// A stand-in for `copilot --headless --stdio`: reads one Content-Length
/// framed request, sends an unrelated notification, then the response.
const _server = r'''
import 'dart:convert';
import 'dart:io';
void main() async {
  final bytes = <int>[];
  await for (final chunk in stdin) {
    bytes.addAll(chunk);
    final text = latin1.decode(bytes);
    final split = text.indexOf('\r\n\r\n');
    if (split < 0) continue;
    final length = int.parse(text.substring(0, split).split(':')[1].trim());
    if (bytes.length < split + 4 + length) continue;
    final request = jsonDecode(utf8.decode(bytes.sublist(split + 4, split + 4 + length)));
    void send(Object message) {
      final body = utf8.encode(jsonEncode(message));
      stdout.add(utf8.encode('Content-Length: ${body.length}\r\n\r\n'));
      stdout.add(body);
    }
    send({'jsonrpc': '2.0', 'method': 'session.event', 'params': {}});
    send({
      'jsonrpc': '2.0',
      'id': request['id'],
      'result': {'method': request['method'], 'remaining': 'é'},
    });
    await stdout.flush();
  }
}
''';

void main() {
  test('reads a Content-Length framed JSON-RPC result', () async {
    final root = await Directory.systemTemp.createTemp('rpc-usage-');
    addTearDown(() => root.delete(recursive: true));
    final script = File('${root.path}/server.dart')..writeAsStringSync(_server);
    final result = await readAppServerResult(
      executable: Platform.resolvedExecutable,
      arguments: ['run', script.path],
      environment: Map.of(Platform.environment),
      workingDirectory: root.path,
      method: 'account.getQuota',
      framing: 'content_length',
      timeout: const Duration(seconds: 30),
    );
    expect(result, {'method': 'account.getQuota', 'remaining': 'é'});
  });
}

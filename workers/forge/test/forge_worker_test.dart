import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Forge worker exposes the Worker protocol', () async {
    final process = await Process.start(
      'dart',
      ['--disable-analytics', 'run', 'bin/forge_worker.dart'],
      workingDirectory: Directory.current.path,
    );
    final lines =
        process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'initialize-1',
      'method': 'initialize',
      'params': {},
    }));
    final response = await lines.first.timeout(const Duration(seconds: 30));
    expect(jsonDecode(response)['result']['workerId'], 'conclave.forge');
    await process.stdin.close();
    process.kill(ProcessSignal.sigterm);
  });
}

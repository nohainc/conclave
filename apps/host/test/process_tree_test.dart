import 'dart:io';

import 'package:conclave_host/process_tree.dart';
import 'package:test/test.dart';

void main() {
  test('force termination ends an isolated child process', () async {
    final process = Platform.isWindows
        ? await startIsolatedProcess(
            'cmd',
            ['/c', 'ping', '127.0.0.1', '-n', '30'],
          )
        : await startIsolatedProcess('sleep', ['30']);
    await terminateProcessTree(process, force: true);
    final exitCode = await process.exitCode.timeout(const Duration(seconds: 5));
    expect(exitCode, isNot(0));
  });
}

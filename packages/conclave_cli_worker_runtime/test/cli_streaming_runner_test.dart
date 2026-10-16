import 'dart:io';

import 'package:conclave_cli_worker_runtime/src/cli_streaming_runner.dart';
import 'package:test/test.dart';

void main() {
  test(
    'returns after the CLI exits even when a background process holds the pipes',
    () async {
      final runner = CliStreamingRunner(
        drainGrace: const Duration(milliseconds: 300),
      );
      final lines = <String>[];
      final clock = Stopwatch()..start();
      final result = await runner.run(
        '/bin/sh',
        ['-c', 'echo result; sleep 30 &'],
        environment: const {'PATH': '/usr/bin:/bin'},
        workingDirectory: Directory.systemTemp.path,
        stdinText: '',
        timeout: const Duration(seconds: 20),
        onStdoutLine: lines.add,
      );
      expect(result.exitCode, 0);
      expect(lines, ['result']);
      expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
    },
    skip: Platform.isWindows ? 'POSIX shell required' : false,
  );
}

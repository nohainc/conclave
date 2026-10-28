import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/src/cli_streaming_runner.dart';
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

  test('stops a CLI that is silent with no child process', () async {
    final runner = CliStreamingRunner(
      stallCheckInterval: const Duration(milliseconds: 100),
    );
    final clock = Stopwatch()..start();
    await expectLater(
      runner.run(
        '/bin/sh',
        ['-c', 'echo start; sleep 30'],
        environment: const {'PATH': '/usr/bin:/bin'},
        workingDirectory: Directory.systemTemp.path,
        stdinText: '',
        timeout: const Duration(seconds: 20),
        onStdoutLine: (_) {},
        stallLimit: const Duration(milliseconds: 400),
        childProcessProbe: (_) async => false,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
  }, skip: Platform.isWindows ? 'POSIX shell required' : false);

  test('does not stop a silent CLI that is running a child process', () async {
    final runner = CliStreamingRunner(
      stallCheckInterval: const Duration(milliseconds: 100),
    );
    final lines = <String>[];
    final result = await runner.run(
      '/bin/sh',
      ['-c', 'sleep 1; echo done'],
      environment: const {'PATH': '/usr/bin:/bin'},
      workingDirectory: Directory.systemTemp.path,
      stdinText: '',
      timeout: const Duration(seconds: 20),
      onStdoutLine: lines.add,
      stallLimit: const Duration(milliseconds: 300),
      childProcessProbe: (_) async => true,
    );
    expect(result.exitCode, 0);
    expect(lines, ['done']);
  }, skip: Platform.isWindows ? 'POSIX shell required' : false);

  test('output keeps resetting the stall clock', () async {
    final runner = CliStreamingRunner(
      stallCheckInterval: const Duration(milliseconds: 100),
    );
    final lines = <String>[];
    final result = await runner.run(
      '/bin/sh',
      ['-c', 'for i in 1 2 3 4; do echo tick; sleep 0.2; done'],
      environment: const {'PATH': '/usr/bin:/bin'},
      workingDirectory: Directory.systemTemp.path,
      stdinText: '',
      timeout: const Duration(seconds: 20),
      onStdoutLine: lines.add,
      stallLimit: const Duration(milliseconds: 500),
      childProcessProbe: (_) async => false,
    );
    expect(result.exitCode, 0);
    expect(lines.length, 4);
  }, skip: Platform.isWindows ? 'POSIX shell required' : false);
}

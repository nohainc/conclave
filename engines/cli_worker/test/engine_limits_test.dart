import 'dart:async';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/src/cli_streaming_runner.dart';
import 'package:test/test.dart';

void main() {
  final repository = Directory.current.parent.parent;
  final fixture =
      '${repository.path}/packages/tool-profile/test/fixtures/provider-cli/fixture_provider.dart';
  final runner = const CliStreamingRunner(
    maxStdoutBytes: 128 * 1024,
    maxStderrBytes: 1024,
  );

  test('bounds provider stdout and terminates a flooding process', () async {
    await expectLater(
      runner.run(
        Platform.resolvedExecutable,
        [fixture, 'flood'],
        environment: const {},
        workingDirectory: repository.path,
        stdinText: '',
        timeout: const Duration(seconds: 10),
        onStdoutLine: (_) {},
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'drains stderr floods while retaining only the configured limit',
    () async {
      final result = await runner.run(
        Platform.resolvedExecutable,
        [fixture, 'stderr-flood'],
        environment: const {},
        workingDirectory: repository.path,
        stdinText: '',
        timeout: const Duration(seconds: 10),
        onStdoutLine: (_) {},
      );
      expect(result.exitCode, 0);
      expect(result.stderr.length, lessThanOrEqualTo(1024));
    },
  );

  test('accepts a successful CLI that exits before consuming stdin', () async {
    final result = await runner.run(
      Platform.resolvedExecutable,
      [fixture, 'echo', 'completed from arguments'],
      environment: const {},
      workingDirectory: repository.path,
      stdinText: 'unused stdin' * (1024 * 1024),
      timeout: const Duration(seconds: 10),
      onStdoutLine: (_) {},
    );

    expect(result.exitCode, 0);
  });

  test('outer deadline terminates a hanging provider process', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      runner.run(
        Platform.resolvedExecutable,
        [fixture, 'hang'],
        environment: const {},
        workingDirectory: repository.path,
        stdinText: '',
        timeout: const Duration(milliseconds: 150),
        onStdoutLine: (_) {},
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test(
    'cancels provider execution when the consumer stops the stream',
    () async {
      await expectLater(
        runner.run(
          Platform.resolvedExecutable,
          [fixture, 'echo', 'one-line'],
          environment: const {},
          workingDirectory: repository.path,
          stdinText: '',
          timeout: const Duration(seconds: 5),
          onStdoutLine: (_) => throw StateError('consumer cancelled'),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );
}

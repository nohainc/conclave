import 'dart:async';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('channel skips both VM banners but rejects unrelated stdout', () async {
    if (Platform.isWindows) return;
    final frame = WorkerResult(
      requestId: 'banner-request',
      assignmentId: 'banner-assignment',
      output: 'ok',
    );
    for (final banner in [
      'The Dart VM service is listening on http://127.0.0.1:1234/token/',
      'The Dart DevTools debugger and profiler is available at: http://127.0.0.1:1234/token/devtools/',
      'unrelated stdout must remain a protocol error',
    ]) {
      final process = await Process.start('/bin/sh', [
        '-c',
        r'''read request; printf '%s\n' "$1" "$2"''',
        'banner-fixture',
        banner,
        frame.encode(),
      ]);
      final channel = CliEngineChannel(
        process,
        maxFrameBytes: 1024 * 1024,
        maxStderrBytes: 1024,
      );
      try {
        final reply = channel.exchange(frame, const Duration(seconds: 2));
        if (banner.startsWith('unrelated')) {
          await expectLater(reply, throwsFormatException);
        } else {
          expect((await reply as WorkerResult).output, 'ok');
        }
      } finally {
        await channel.dispose();
        await process.exitCode;
      }
    }
  });

  test(
    'environment construction includes only explicitly allowed parent keys',
    () {
      final environment =
          const CliEnvironmentBuilder(allowedParentKeys: {'PATH'}).build(
            parentEnvironment: const {'PATH': '/bin', 'API_KEY': 'secret'},
            values: const {'LANG': 'C.UTF-8'},
          );
      expect(environment, {'PATH': '/bin', 'LANG': 'C.UTF-8'});
    },
  );

  test('deadline cancellation invokes the process cleanup hook', () async {
    var cleaned = false;
    final deadline = WorkerDeadlineController(
      const Duration(seconds: 1),
      onCancel: () => cleaned = true,
    );
    final pending = deadline.run<void>(() => Completer<void>().future);
    deadline.cancel();
    await expectLater(pending, throwsA(isA<WorkerCancelledException>()));
    expect(cleaned, isTrue);
  });

  test(
    'CLI streaming startup callback is included in the execution deadline',
    () async {
      if (Platform.isWindows) return;
      await expectLater(
        const CliStreamingRunner().run(
          '/bin/sh',
          ['-c', 'sleep 30'],
          environment: {},
          workingDirectory: Directory.current.path,
          stdinText: '',
          timeout: Duration(milliseconds: 100),
          onStdoutLine: (_) {},
          onStarted: () => Future<void>.delayed(const Duration(seconds: 1)),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
}

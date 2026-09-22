import 'dart:io';

import 'package:conclave_host/worker_executor.dart';
import 'package:test/test.dart';

Future<Directory> createLoudWorker() async {
  final directory = await Directory.systemTemp.createTemp('loud-worker-');
  await File('${directory.path}/loud.dart').writeAsString('''
import 'dart:io';

Future<void> main() async {
  stdout.write(List.filled(1024 * 1024, 'x').join());
  await Future<void>.delayed(const Duration(seconds: 5));
}
''');
  return directory;
}

void main() {
  test('bounds an unterminated worker stdout line before line buffering',
      () async {
    final directory = await createLoudWorker();
    try {
      await expectLater(
        WorkerProcessExecutor().execute(
          WorkerProcessSpec(
            workerId: 'loud',
            executable: 'dart',
            arguments: ['run', '${directory.path}/loud.dart'],
          ),
          {},
          maxStdoutBytes: 1024,
        ),
        throwsA(predicate((error) =>
            error.toString().contains('worker stdout exceeded 1024 bytes'))),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

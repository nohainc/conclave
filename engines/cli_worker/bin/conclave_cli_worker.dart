import 'dart:io';

import '../lib/src/cli_worker_engine.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = EngineOptions.parse(arguments);
    await CliWorkerEngine(options: options).run();
  } on FormatException catch (error) {
    stderr.writeln('CLI Worker Engine configuration error: ${error.message}');
    exitCode = 64;
  } on Object catch (_) {
    stderr.writeln('CLI Worker Engine failed to start');
    exitCode = 70;
  }
}

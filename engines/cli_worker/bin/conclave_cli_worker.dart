import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import '../lib/src/cli_worker_engine.dart';

Future<void> main(List<String> arguments) async {
  setCurrentProcessName('conclave-agent');
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

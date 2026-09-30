import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.length > 3) {
    stderr.writeln(
      'usage: dart run tool/initialize_harness.dart <executable> <worker-type-id>',
    );
    exitCode = 64;
    return;
  }
  final executable = arguments[0];
  final workerTypeId = arguments[1];
  final expectedVersion = arguments.length == 3 ? arguments[2] : '0.1.0';
  final process = await Process.start(executable, const []);
  final request = InitializeRequest(
    requestId: 'harness-init-1',
    workerTypeId: workerTypeId,
    expectedWorkerVersion: expectedVersion,
  );
  process.stdin.writeln(request.encode());
  await process.stdin.flush();
  await process.stdin.close();

  final responseLine = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 5));
  final response = decodeWorkerFrame(responseLine);
  if (response is! InitializeResult ||
      response.requestId != request.requestId ||
      response.workerTypeId != workerTypeId ||
      response.workerVersion != expectedVersion) {
    throw StateError('Worker initialize response did not match the request');
  }
  final workerExitCode = await process.exitCode.timeout(
    const Duration(seconds: 5),
  );
  if (workerExitCode != 0) {
    throw ProcessException(
      executable,
      const [],
      'Worker failed',
      workerExitCode,
    );
  }
  stdout.writeln(
    'initialize handshake passed: $workerTypeId ${response.workerVersion}',
  );
}

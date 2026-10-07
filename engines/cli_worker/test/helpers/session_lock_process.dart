import 'dart:io';
import 'package:conclave_cli_worker_engine/src/engine_session_store.dart';

Future<void> main(List<String> args) async {
  try {
    final lease = await EngineSessionStore(Directory(args[0])).acquireExecution(
      sessionKey: args[1],
      workerTypeId: 'fixture',
      profileDefinitionId: 'profile',
      providerToolIdentity: 'tool',
    );
    stdout.writeln('acquired');
    if (args[2] == 'hold') await stdin.first;
    await lease.release();
  } on EngineSessionBusy {
    stdout.writeln('busy');
  }
}

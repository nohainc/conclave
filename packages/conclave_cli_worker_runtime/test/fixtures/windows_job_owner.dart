import 'dart:async';
import 'dart:io';
import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';

Future<void> main() async {
  initializeWindowsProcessJob();
  final child = await Process.start('ping.exe', ['-t', '127.0.0.1']);
  unawaited(child.stdout.drain<void>());
  unawaited(child.stderr.drain<void>());
  stdout.writeln(child.pid);
  Timer.periodic(const Duration(seconds: 1), (_) {});
}

import 'dart:io';

import 'package:syntila_workspace/workspace_cli.dart';
import 'syntila_workspace_service.dart' as service;

/// Unified entrypoint for Syntila Workspace:
/// - `syntila-workspace run [args...]` runs the background service daemon.
/// - Any other subcommand (or `--help`) dispatches to the CLI client.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty &&
      (args.first == 'run' || args.contains('--background-service'))) {
    final serviceArgs = args.first == 'run' ? args.sublist(1) : args;
    await service.main(serviceArgs);
    return;
  }
  exitCode = await WorkspaceCli(out: stdout, err: stderr).run(args);
}

import 'dart:io';

import 'package:conclave_workspace/workspace_cli.dart';
import 'conclave_workspace_service.dart' as service;

/// Unified entrypoint for Conclave Workspace:
/// - `conclave-workspace run [args...]` runs the background service daemon.
/// - Invoked under the name `workspace` (the service alias used by systemd,
///   containers and the packaged `workspace` command) it runs the daemon.
/// - Any other subcommand (or `--help`) dispatches to the CLI client.
Future<void> main(List<String> args) async {
  final invokedAs = Platform.executable
      .split(RegExp(r'[\\/]'))
      .last
      .replaceAll(RegExp(r'\.exe$'), '');
  if (invokedAs == 'workspace' ||
      (args.isNotEmpty &&
          (args.first == 'run' || args.contains('--background-service')))) {
    final serviceArgs =
        args.isNotEmpty && args.first == 'run' ? args.sublist(1) : args;
    await service.main(serviceArgs);
    return;
  }
  exitCode = await WorkspaceCli(out: stdout, err: stderr).run(args);
}

import 'dart:io';

import 'package:conclave_workspace/workspace.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    exitCode = 2;
    return;
  }
  final workspace = Workspace(
    config: WorkspaceConfig(
      dataDirectory: Directory(args[0]),
      workRootPath: args[1],
      installationId: args[2],
    ),
  );
  try {
    await workspace.start();
    await workspace.stop();
    exitCode = 1;
  } on StateError catch (error) {
    exitCode =
        error.message.toString().contains('another Workspace instance') ? 0 : 3;
  }
}

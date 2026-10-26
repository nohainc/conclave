import 'dart:io';

import 'package:conclave_workspace/workspace_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await WorkspaceCli(out: stdout, err: stderr).run(args);
}

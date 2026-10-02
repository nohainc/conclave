import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_runtime.dart';

Future<void> main(List<String> args) async {
  final config = WorkspaceConfig.fromArgs(args);
  final engine = await buildWorkspaceRuntime(config, restartArgs: args);
  await engine.start();
  if (args.contains('--once')) await engine.stop();
}

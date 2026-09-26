import 'package:conclave_host/host.dart';
import 'package:conclave_host/workspace_runtime.dart';

Future<void> main(List<String> args) async {
  final config = HostConfig.fromArgs(args);
  final engine = await buildWorkspaceRuntime(config, restartArgs: args);
  await engine.start();
  if (args.contains('--once')) await engine.stop();
}

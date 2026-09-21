import 'package:conclave_agent_engine/agent_engine.dart';

Future<void> main(List<String> args) async {
  final engine = AgentEngine(config: AgentEngineConfig.fromArgs(args));
  await engine.start();
  if (args.contains('--once')) await engine.stop();
}

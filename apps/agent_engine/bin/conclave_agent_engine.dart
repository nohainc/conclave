import 'package:conclave_agent_engine/agent_engine.dart';
import 'package:conclave_agent_engine/cloud_connection.dart';

Future<void> main(List<String> args) async {
  final config = AgentEngineConfig.fromArgs(args);
  final connection = config.cloudUri != null &&
          config.agentId != null &&
          config.workspaceId != null
      ? AgentCloudConnection(
          uri: config.cloudUri!,
          agentId: config.agentId!,
          workspaceId: config.workspaceId!,
          factory: (uri) => connectIoAgentCloudSocket(
            uri,
            authToken: config.authToken,
          ),
        )
      : null;
  final engine = AgentEngine(config: config, cloudConnection: connection);
  await engine.start();
  if (args.contains('--once')) await engine.stop();
}

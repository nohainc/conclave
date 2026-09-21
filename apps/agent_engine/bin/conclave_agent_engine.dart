import 'dart:io';

import 'package:conclave_agent_engine/agent_engine.dart';
import 'package:conclave_agent_engine/assignment_journal.dart';
import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:conclave_agent_engine/plugin_executor.dart';
import 'package:conclave_agent_engine/plugin_manager.dart';

Future<void> main(List<String> args) async {
  final config = AgentEngineConfig.fromArgs(args);
  final pluginManager = PluginManager(
    Directory('${config.dataDirectory.path}/plugins'),
  );
  final pluginHandler = pluginManager.assignmentHandler(
    PluginProcessExecutor(),
  );
  final connection = config.cloudUri != null &&
          config.agentId != null &&
          config.workspaceId != null
      ? AgentCloudConnection(
          uri: config.cloudUri!,
          agentId: config.agentId!,
          workspaceId: config.workspaceId!,
          assignmentHandler: pluginHandler.call,
          assignmentJournal: AssignmentJournal(
            File('${config.dataDirectory.path}/assignments.jsonl'),
          ),
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

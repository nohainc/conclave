import 'dart:io';

import 'package:conclave_agent_engine/agent_engine.dart';
import 'package:conclave_agent_engine/assignment_journal.dart';
import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:conclave_agent_engine/plugin_executor.dart';
import 'package:conclave_agent_engine/plugin_manager.dart';
import 'package:conclave_agent_engine/trust_policy.dart';

Set<PluginPermission> _configuredPermissions() {
  final configured = Platform.environment['CONCLAVE_PLUGIN_PERMISSIONS'];
  if (configured == null) return {};
  return configured
      .split(',')
      .map((permission) => permission.trim())
      .map((permission) => PluginPermission.values
          .where((candidate) => candidate.name == permission))
      .expand((matches) => matches)
      .toSet();
}

Future<void> main(List<String> args) async {
  final config = AgentEngineConfig.fromArgs(args);
  final publisher =
      Platform.environment['CONCLAVE_PLUGIN_TRUST_PUBLISHER'] ?? 'conclave';
  final trustSecret = Platform.environment['CONCLAVE_PLUGIN_TRUST_SECRET'];
  final pluginManager = PluginManager(
    Directory('${config.dataDirectory.path}/plugins'),
    trustPolicy: PluginTrustPolicy(
      trustedSecrets: trustSecret == null ? {} : {publisher: trustSecret},
    ),
    allowedPermissions: _configuredPermissions(),
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
          assignmentCancellationHandler: pluginHandler.cancel,
          assignmentJournal: AssignmentJournal(
            File('${config.dataDirectory.path}/assignments.jsonl'),
          ),
          factory: (uri) => connectIoAgentCloudSocket(
            uri,
            authToken: config.authToken,
          ),
        )
      : null;
  final engine = AgentEngine(
    config: config,
    cloudConnection: connection,
    statusProvider: () async {
      final plugins = await pluginManager.inventory();
      return {
        'plugins': plugins.length,
        'pluginIds': plugins.map((plugin) => plugin.pluginId).toList(),
      };
    },
  );
  await engine.start();
  if (args.contains('--once')) await engine.stop();
}

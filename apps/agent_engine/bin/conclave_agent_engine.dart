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

Future<List<int>> _downloadPlugin(
  Uri cloudUri,
  String? authToken,
  String pluginId,
  String version,
  String packageR2Key,
) async {
  final scheme = cloudUri.scheme == 'wss' ? 'https' : 'http';
  final uri = cloudUri.replace(
    scheme: scheme,
    pathSegments: [
      'api',
      'plugins',
      pluginId,
      'versions',
      version,
      'download',
    ],
    queryParameters: {'packageR2Key': packageR2Key},
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (authToken != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $authToken');
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(
        'plugin download failed with HTTP ${response.statusCode}',
      );
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
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
          syncHandler: (payload) async {
            final raw = payload['desiredPlugins'];
            if (raw is! List) return;
            final desired = raw
                .whereType<Map>()
                .map((item) => Map<String, Object?>.from(item));
            await pluginManager.reconcile(
              desired,
              download: (pluginId, version, packageR2Key) => _downloadPlugin(
                config.cloudUri!,
                config.authToken,
                pluginId,
                version,
                packageR2Key,
              ),
            );
          },
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
        'activeTasks': connection?.activeAssignmentCount ?? 0,
        'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
        'cloudConnected': connection?.isConnected ?? false,
      };
    },
  );
  await engine.start();
  if (args.contains('--once')) await engine.stop();
}

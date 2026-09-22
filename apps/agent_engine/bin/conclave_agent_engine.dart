import 'dart:io';

import 'package:conclave_agent_engine/agent_engine.dart';
import 'package:conclave_agent_engine/assignment_journal.dart';
import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:conclave_agent_engine/plugin_executor.dart';
import 'package:conclave_agent_engine/plugin_manager.dart';
import 'package:conclave_agent_engine/repository_registry.dart';
import 'package:conclave_agent_engine/self_update.dart';
import 'package:conclave_agent_engine/trust_policy.dart';
import 'package:conclave_agent_engine/worker_configuration.dart';

Set<PluginPermission> _configuredPermissions() {
  return parseConfiguredPluginPermissions(
      Platform.environment['CONCLAVE_PLUGIN_PERMISSIONS']);
}

Future<List<int>> downloadPluginPackage(Uri cloudUri, String? authToken,
    String pluginId, String version, String packageR2Key,
    {int maxPackageBytes = 512 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 30)}) async {
  if (maxPackageBytes <= 0) {
    throw ArgumentError.value(
        maxPackageBytes, 'maxPackageBytes', 'must be positive');
  }
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
    client.connectionTimeout = timeout;
    final request = await client.getUrl(uri).timeout(timeout);
    if (authToken != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $authToken');
    }
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(
        'plugin download failed with HTTP ${response.statusCode}',
      );
    }
    if (response.contentLength > maxPackageBytes) {
      throw StateError(
          'plugin package exceeds the $maxPackageBytes byte package limit');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxPackageBytes) {
        throw StateError(
            'plugin package exceeds the $maxPackageBytes byte package limit');
      }
      bytes.addAll(chunk);
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
    secretEnvironment: {
      for (final name in const [
        'OPENAI_API_KEY',
        'ANTHROPIC_API_KEY',
        'CONCLAVE_CONNECTOR_TOKEN',
      ])
        if (Platform.environment[name] != null) name: Platform.environment[name]!,
    },
  );
  final workerStore = WorkerConfigurationStore(
    Directory('${config.dataDirectory.path}/workers'),
    workspaceId: config.workspaceId ?? '',
    agentId: config.agentId ?? '',
  );
  final activeWorkerIds = (await workerStore.read())
      .where((worker) => worker['enabled'] == true)
      .map((worker) => worker['workerId'])
      .whereType<String>()
      .toList();
  final repositoryRegistry = await LocalRepositoryRegistry.load(File(
    config.repositoriesFile ?? '${config.dataDirectory.path}/repositories.json',
  ));
  final pluginHandler = pluginManager.assignmentHandler(
    PluginProcessExecutor(),
    resolveRepositoryPath: repositoryRegistry.resolve,
  );
  String? updateAvailable;
  var lastUpdateCheck = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> refreshUpdateAvailability() async {
    if (config.cloudUri == null ||
        DateTime.now().difference(lastUpdateCheck) <
            const Duration(minutes: 5)) {
      return;
    }
    lastUpdateCheck = DateTime.now();
    try {
      final release = await const AgentReleaseClient().latest(
        cloudUri: config.cloudUri!,
        channel: 'stable',
        currentVersion: '0.1.0',
        operatingSystem: Platform.operatingSystem,
        authToken: config.authToken,
      );
      updateAvailable = release?.version;
    } on Object {
      // Status remains useful while Cloud is offline; the next interval
      // retries the check.
    }
  }

  late final AgentCloudConnection? connection;
  connection = config.cloudUri != null &&
          config.agentId != null &&
          config.workspaceId != null
      ? AgentCloudConnection(
          uri: config.cloudUri!,
          agentId: config.agentId!,
          workspaceId: config.workspaceId!,
          activeWorkerIds: activeWorkerIds,
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
            try {
              await pluginManager.reconcile(
                desired,
                download: (pluginId, version, packageR2Key) =>
                    downloadPluginPackage(
                  config.cloudUri!,
                  config.authToken,
                  pluginId,
                  version,
                  packageR2Key,
                ),
              );
              final rawWorkers = payload['desiredWorkers'];
              if (rawWorkers is List) {
                final desiredWorkers = rawWorkers
                    .whereType<Map>()
                    .map((item) => Map<String, Object?>.from(item))
                    .toList();
                final ids = await workerStore.reconcile(desiredWorkers);
                activeWorkerIds
                  ..clear()
                  ..addAll(ids);
                for (final worker in desiredWorkers) {
                  final workerId = worker['workerId'];
                  if (workerId is! String) continue;
                  final enabled = worker['enabled'] == true;
                  connection?.reportWorkerStatus(
                    workerId: workerId,
                    status: enabled ? 'available' : 'disabled',
                    activeAssignments: 0,
                  );
                }
              }
              final inventory = await pluginManager.inventory();
              connection?.reportPluginStatuses(
                inventory
                    .map((plugin) => {
                          'pluginId': plugin.pluginId,
                          'version': plugin.version,
                          'status': plugin.active ? 'active' : 'installed',
                          'installedAt':
                              DateTime.now().toUtc().toIso8601String(),
                        })
                    .toList(),
              );
            } catch (error) {
              for (final plugin in desired) {
                final pluginId = plugin['pluginId'];
                final version = plugin['version'];
                if (pluginId is! String || version is! String) continue;
                connection?.reportPluginStatuses([
                  {
                    'pluginId': pluginId,
                    'version': version,
                    'status': 'error',
                    'error': '$error',
                    'installedAt': DateTime.now().toUtc().toIso8601String(),
                  },
                ]);
              }
              rethrow;
            }
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
      await refreshUpdateAvailability();
      final plugins = await pluginManager.inventory();
      return {
        'workers': activeWorkerIds.length,
        'plugins': plugins.length,
        'pluginIds': plugins.map((plugin) => plugin.pluginId).toList(),
        'activeTasks': connection?.activeAssignmentCount ?? 0,
        'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
        'cloudConnected': connection?.isConnected ?? false,
        if (updateAvailable != null) 'updateAvailable': updateAvailable,
      };
    },
  );
  await engine.start();
  if (args.contains('--once')) await engine.stop();
}

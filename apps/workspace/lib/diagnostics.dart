import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'cloud_connection.dart';
import 'workspace.dart';
import 'platform_runtime.dart';
import 'workspace_registration.dart';
import 'cli_worker_engine_supervisor.dart';
import 'tool_profile_resolver.dart';

const _diagnosticSecretPattern =
    r'(secret|token|password|api[_-]?key|authorization|cookie|raw[_-]?credential|private[_-]?key)';

Object? sanitizeWorkspaceDiagnostics(Object? value, {int depth = 0}) {
  if (depth > 5) {
    return '[depth limited]';
  }
  if (value is String) {
    return value.length > 512 ? '${value.substring(0, 512)}…' : value;
  }
  if (value == null || value is num || value is bool) return value;
  if (value is List) {
    return value
        .take(50)
        .map((item) => sanitizeWorkspaceDiagnostics(item, depth: depth + 1))
        .toList();
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries.take(80))
        entry.key.toString():
            RegExp(_diagnosticSecretPattern, caseSensitive: false)
                    .hasMatch(entry.key.toString())
                ? '[redacted]'
                : sanitizeWorkspaceDiagnostics(entry.value, depth: depth + 1),
    };
  }
  return '[${value.runtimeType}]';
}

Future<Map<String, Object?>> buildWorkspaceDiagnostics({
  required WorkspaceConfig config,
  WorkspaceCloudConnection? connection,
  AssignmentJournal? journal,
  LocalWorkerRegistry? workerRegistry,
  ToolProfileReleaseStore? toolProfileReleaseStore,
  ToolProfileCatalogClient? toolProfileCatalog,
  String? lastUpdateCheckStatus,
  DateTime? lastUpdateCheckAt,
  String? updateStatus,
  String? workRootPath,
  int logLineLimit = 200,
}) async {
  final logFile = WorkspacePaths(config.dataDirectory).logsFile;
  final lines =
      await logFile.exists() ? await logFile.readAsLines() : <String>[];
  final recentLogs = lines.length <= logLineLimit
      ? lines
      : lines.sublist(lines.length - logLineLimit);
  final assignments = <Map<String, Object?>>[];
  final workers = <Map<String, Object?>>[];
  for (final worker
      in await workerRegistry?.list(includeRemoved: true) ?? const []) {
    Map<String, Object?>? toolProfile;
    final catalog = toolProfileCatalog;
    final profileDefinitionId = catalog == null
        ? null
        : (await catalog.loadCatalog())
            .where((entry) => entry.workerTypeId == worker.workerTypeId)
            .firstOrNull
            ?.profileDefinitionId;
    if (profileDefinitionId != null && toolProfileReleaseStore != null) {
      try {
        final resolver = ToolProfileResolver(toolProfileReleaseStore);
        var resolution = worker.toolVersion == null
            ? await resolver.resolveBootstrapProfile(
                logicalWorkerTypeId: worker.workerTypeId,
                profileDefinitionId: profileDefinitionId,
                engineVersion: cliWorkerEngineVersion,
              )
            : await resolver.resolve(
                logicalWorkerTypeId: worker.workerTypeId,
                profileDefinitionId: profileDefinitionId,
                engineVersion: cliWorkerEngineVersion,
                providerCliVersion: worker.toolVersion!,
              );
        if (!resolution.isAvailable && worker.toolVersion != null) {
          resolution = await resolver.resolveBootstrapProfile(
            logicalWorkerTypeId: worker.workerTypeId,
            profileDefinitionId: profileDefinitionId,
            engineVersion: cliWorkerEngineVersion,
          );
        }
        toolProfile = {
          'profileDefinitionId': profileDefinitionId,
          'profileResolutionSource': resolution.source.name,
          'profileResolutionAvailable': resolution.isAvailable,
          if (resolution.release != null)
            'profileReleaseVersion': resolution.release!.releaseVersion,
        };
      } on Object {
        toolProfile = {
          'profileDefinitionId': profileDefinitionId,
          'profileResolutionSource': 'unavailable',
          'profileResolutionAvailable': false,
        };
      }
    }
    workers.add({
      'workerId': worker.id,
      'workerTypeId': worker.workerTypeId,
      'activationState': worker.activationState.name,
      'status': worker.status.name,
      'readinessState': worker.readinessState.wireValue,
      'lastPassiveProbeAt': worker.lastPassiveProbeAt,
      'readinessIssueCode': worker.readinessIssueCode,
      'providerToolVersion': worker.toolVersion,
      'providerToolName': worker.toolName,
      'engineVersion': cliWorkerEngineVersion,
      'providerToolPath': worker.toolPath,
      if (toolProfile != null) 'toolProfile': toolProfile,
      'profileDefinitionId': profileDefinitionId,
      'profileReleaseVersion': toolProfile?['profileReleaseVersion'],
      'lastLiveTest': {
        'at': worker.lastLiveTestAt,
        'passed': worker.lastLiveTestPassed,
        'issueCode': worker.lastLiveTestIssueCode,
        'details': worker.lastLiveTestDetails,
      },
    });
  }
  if (journal != null) {
    final records = await journal.reconcile();
    for (final record in records.values) {
      assignments.add({
        'assignmentId': record.assignmentId,
        'status': record.status.name,
        'updatedAt': record.updatedAt.toUtc().toIso8601String(),
        if (record.workspaceId != null) 'workspaceId': record.workspaceId,
        if (record.workspaceRuntimeId != null)
          'workspaceRuntimeId': record.workspaceRuntimeId,
        if (record.workerId != null) 'workerId': record.workerId,
        if (record.runId != null) 'runId': record.runId,
        if (record.taskId != null) 'taskId': record.taskId,
        if (record.attemptId != null) 'attemptId': record.attemptId,
      });
    }
  }
  return {
    'format': 'conclave-workspace-diagnostics-v1',
    'appVersion': conclaveWorkspaceAppVersion,
    'workspaceVersion': conclaveWorkspaceAppVersion,
    'cliWorkerEngineVersion': cliWorkerEngineVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'workspace': {
      'workspaceRuntimeId': config.workspaceRuntimeId,
      'workspaceId': config.workspaceId,
      'cloudConnected': connection?.isConnected ?? false,
      'connection': {
        'stage': connection?.connectionStage.name ?? 'offline',
        'activeTransport': connection?.activeTransportMode ?? 'offline',
        'fallbackHealth': connection?.fallbackHealthStatus ?? 'not configured',
        'lastWebSocketFailure': connection?.lastWebSocketFailure,
        'lastWebSocketHttpStatusCode': connection?.lastWebSocketHttpStatusCode,
        'lastWebSocketFailureAt':
            connection?.lastWebSocketFailureAt?.toUtc().toIso8601String(),
        'cloudOrigin':
            connection == null ? null : _cloudOrigin(connection.uri).toString(),
        'webSocketEndpoint': connection == null
            ? null
            : _safeWebSocketEndpoint(connection.uri).toString(),
        'runtimeCredential': config.authToken == null
            ? 'unavailable'
            : 'available_locally_value_withheld',
        'dnsTls': connection?.lastDnsTlsStatus ?? 'not checked',
        'webSocketUpgrade': connection?.lastHttpStatusCode != null
            ? 'failed_http_${connection!.lastHttpStatusCode}'
            : connection?.lastWebSocketUpgradeAt != null
                ? 'succeeded'
                : 'not completed',
        'webSocketUpgradedAt':
            connection?.lastWebSocketUpgradeAt?.toIso8601String(),
        'protocolHello': connection?.protocolHelloStatus ?? 'not started',
        'helloAcknowledgedAt':
            connection?.lastHelloAcknowledgedAt?.toIso8601String(),
        'lastAttemptAt': connection?.lastConnectionAttemptAt?.toIso8601String(),
        'lastReadyAt': connection?.lastReadyAt?.toIso8601String(),
        'lastHttpStatusCode': connection?.lastHttpStatusCode,
        'lastError': connection?.lastConnectionError,
      },
      'reconnectCount': connection?.reconnectCount ?? 0,
      'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
      'activeAssignmentCount': connection?.activeAssignmentCount ?? 0,
      'lastInventorySyncAt': connection?.lastInventorySyncAt?.toIso8601String(),
      'acceptingNewWork': connection?.acceptingNewWork ?? false,
      'draining': connection?.isDraining ?? false,
    },
    'workRoot': workRootPath ?? config.workRootResolver.configuredPath,
    'update': {
      'status': updateStatus ?? 'unknown',
      'lastCheckStatus': lastUpdateCheckStatus ?? 'unknown',
      'lastCheckAt': lastUpdateCheckAt?.toUtc().toIso8601String(),
    },
    'workers': workers,
    'assignments': assignments,
    'logs': recentLogs.map((line) {
      try {
        return sanitizeWorkspaceDiagnostics(jsonDecode(line));
      } on FormatException {
        return sanitizeWorkspaceDiagnostics(line);
      }
    }).toList(),
  };
}

Uri _cloudOrigin(Uri uri) {
  final scheme = switch (uri.scheme) {
    'wss' => 'https',
    'ws' => 'http',
    _ => uri.scheme,
  };
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

Uri _safeWebSocketEndpoint(Uri uri) => Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
      queryParameters: {
        if (uri.queryParameters['workspaceRuntimeId'] != null)
          'workspaceRuntimeId': uri.queryParameters['workspaceRuntimeId']!,
      },
    );

Future<File> writeWorkspaceDiagnostics({
  required WorkspaceConfig config,
  WorkspaceCloudConnection? connection,
  AssignmentJournal? journal,
  LocalWorkerRegistry? workerRegistry,
  ToolProfileReleaseStore? toolProfileReleaseStore,
  ToolProfileCatalogClient? toolProfileCatalog,
  String? lastUpdateCheckStatus,
  DateTime? lastUpdateCheckAt,
  String? updateStatus,
  String? workRootPath,
}) async {
  final diagnostics = await buildWorkspaceDiagnostics(
    config: config,
    connection: connection,
    journal: journal,
    workerRegistry: workerRegistry,
    toolProfileReleaseStore: toolProfileReleaseStore,
    toolProfileCatalog: toolProfileCatalog,
    lastUpdateCheckStatus: lastUpdateCheckStatus,
    lastUpdateCheckAt: lastUpdateCheckAt,
    updateStatus: updateStatus,
    workRootPath: workRootPath,
  );
  final file = File(
      '${config.dataDirectory.path}/diagnostics-${DateTime.now().toUtc().millisecondsSinceEpoch}.json');
  await file.writeAsString(jsonEncode(diagnostics), flush: true);
  await currentPlatformRuntime.restrictPermissions(file.path, directory: false);
  return file;
}

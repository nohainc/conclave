import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'cloud_connection.dart';
import 'workspace.dart';
import 'platform_runtime.dart';
import 'workspace_registration.dart';
import 'cli_worker_engine_supervisor.dart';
import 'tool_profile_resolver.dart';
import 'worker_diagnostic_store.dart';

const _diagnosticSecretPattern =
    r'(secret|token|password|api[_-]?key|authorization|cookie|raw[_-]?credential|private[_-]?key)';

const _diagnosticLogFields = {
  'schemaVersion',
  'timestamp',
  'level',
  'severity',
  'event',
  'eventId',
  'requestId',
  'assignmentId',
  'workspaceId',
  'workspaceRuntimeId',
  'workerId',
  'workerTypeId',
  'runId',
  'taskId',
  'attemptId',
  'component',
  'operation',
  'stage',
  'errorCode',
  'retryable',
  'workerVersion',
  'engineVersion',
  'providerToolName',
  'providerToolVersion',
  'profileDefinitionId',
  'profileReleaseVersion',
  'profileResolutionSource',
  'probeStage',
  'failureLayer',
  'durationMs',
  'processExitCode',
};

Object? _safeDiagnosticLog(Object? value) {
  if (value is! Map) {
    return {'event': 'workspace.log.unstructured'};
  }
  final output = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key.toString();
    if (RegExp(_diagnosticSecretPattern, caseSensitive: false).hasMatch(key)) {
      output[key] = '[redacted]';
    } else if (_diagnosticLogFields.contains(key) &&
        (entry.value is String || entry.value is num || entry.value is bool)) {
      output[key] = sanitizeWorkspaceDiagnostics(entry.value);
    }
  }
  final context = value['context'];
  if (context is Map) {
    final safeContext = <String, Object?>{};
    for (final entry in context.entries) {
      final key = entry.key.toString();
      if (RegExp(_diagnosticSecretPattern, caseSensitive: false)
          .hasMatch(key)) {
        safeContext[key] = '[redacted]';
      } else if (entry.value is String ||
          entry.value is num ||
          entry.value is bool) {
        final sanitized = sanitizeWorkspaceDiagnostics({key: entry.value})
            as Map<String, Object?>;
        if (sanitized.containsKey(key)) safeContext[key] = sanitized[key];
      }
    }
    if (safeContext.isNotEmpty) output['context'] = safeContext;
  }
  final details = value['details'];
  if (details is Map) {
    final safeDetails = <String, Object?>{};
    for (final entry in details.entries) {
      final key = entry.key.toString();
      if (RegExp(_diagnosticSecretPattern, caseSensitive: false)
          .hasMatch(key)) {
        safeDetails[key] = '[redacted]';
      } else if (_diagnosticLogFields.contains(key) &&
          (entry.value is String ||
              entry.value is num ||
              entry.value is bool)) {
        safeDetails[key] = sanitizeWorkspaceDiagnostics(entry.value);
      }
    }
    if (safeDetails.isNotEmpty) output['details'] = safeDetails;
  }
  return output;
}

/// Samples the service process only when diagnostics are requested. CPU is
/// intentionally nullable on platforms without `ps`; no background sampler
/// or timer is kept alive for the management UI.
Future<Map<String, Object?>> sampleWorkspaceProcessMetrics() async {
  double? cpuPercent;
  if (!Platform.isWindows) {
    try {
      final result = await Process.run(
        'ps',
        ['-o', '%cpu=', '-p', '$pid'],
        runInShell: false,
      );
      if (result.exitCode == 0) {
        cpuPercent = double.tryParse(result.stdout.toString().trim());
      }
    } on ProcessException {
      // CPU measurement is best-effort; keep memory and PID available.
    }
  }
  return {
    'processId': pid,
    'residentMemoryBytes': ProcessInfo.currentRss,
    'cpuPercent': cpuPercent,
    'sampledAt': DateTime.now().toUtc().toIso8601String(),
  };
}

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
  WorkerProfileStorePort? toolProfileReleaseStore,
  ToolProfileCatalogClient? toolProfileCatalog,
  String? lastUpdateCheckStatus,
  DateTime? lastUpdateCheckAt,
  String? updateStatus,
  String? workRootPath,
  WorkerDiagnosticStore Function(String workerTypeId)? workerDiagnosticStore,
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
        final resolution = await resolver.resolveForWorker(
          logicalWorkerTypeId: worker.workerTypeId,
          profileDefinitionId: profileDefinitionId,
          engineVersion: cliWorkerEngineVersion,
        );
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
  final workerDiagnostics = <Map<String, Object?>>[];
  final diagnosticTimeline = <Map<String, Object?>>[];
  var missingTerminalEventCount = 0;
  var forwardingFailureCount = 0;
  var localDiagnosticsAvailable = workerDiagnosticStore != null;
  if (workerDiagnosticStore != null) {
    for (final worker in workers) {
      try {
        final store = workerDiagnosticStore(worker['workerTypeId'] as String);
        final records = await store.readSafeRecords(maxRecords: 50);
        for (final record in records) {
          diagnosticTimeline.add({
            'kind': 'worker_diagnostic',
            ...record,
          });
          final event = record['event']?.toString() ?? '';
          if (_diagnosticEventMatches(event, 'missing_terminal_event')) {
            missingTerminalEventCount++;
          }
          if (_diagnosticEventMatches(event, 'forwarding_failed')) {
            forwardingFailureCount++;
          }
        }
        workerDiagnostics.add({
          'workerTypeId': worker['workerTypeId'],
          'records': records,
        });
      } on Object {
        localDiagnosticsAvailable = false;
      }
    }
  }
  final now = DateTime.now().toUtc();
  const staleRunningThreshold = Duration(minutes: 5);
  var staleRunningCount = 0;
  var maxStaleRunningDurationMs = 0;
  if (journal != null) {
    final records = await journal.reconcile();
    for (final record in records.values) {
      final staleDuration = now.difference(record.updatedAt.toUtc());
      if (record.status == AssignmentStatus.running &&
          staleDuration >= staleRunningThreshold) {
        staleRunningCount++;
        if (staleDuration.inMilliseconds > maxStaleRunningDurationMs) {
          maxStaleRunningDurationMs = staleDuration.inMilliseconds;
        }
      }
      assignments.add({
        'assignmentId': record.assignmentId,
        'status': record.status.name,
        'updatedAt': record.updatedAt.toUtc().toIso8601String(),
        if (record.executionId != null) 'executionId': record.executionId,
        if (record.processExitCode != null)
          'processExitCode': record.processExitCode,
        if (record.errorCode != null) 'errorCode': record.errorCode,
        if (record.workspaceId != null) 'workspaceId': record.workspaceId,
        if (record.workspaceRuntimeId != null)
          'workspaceRuntimeId': record.workspaceRuntimeId,
        if (record.workerId != null) 'workerId': record.workerId,
        if (record.runId != null) 'runId': record.runId,
        if (record.taskId != null) 'taskId': record.taskId,
        if (record.attemptId != null) 'attemptId': record.attemptId,
      });
      diagnosticTimeline.add({
        'kind': 'assignment_state',
        'event': 'assignment.state',
        'timestamp': record.updatedAt.toUtc().toIso8601String(),
        'assignmentId': record.assignmentId,
        'status': record.status.name,
        if (record.executionId != null) 'executionId': record.executionId,
        if (record.processExitCode != null)
          'processExitCode': record.processExitCode,
        if (record.errorCode != null) 'errorCode': record.errorCode,
      });
    }
  }
  diagnosticTimeline.sort((left, right) {
    final leftTime = DateTime.tryParse(left['timestamp']?.toString() ?? '');
    final rightTime = DateTime.tryParse(right['timestamp']?.toString() ?? '');
    if (leftTime == null && rightTime == null) return 0;
    if (leftTime == null) return -1;
    if (rightTime == null) return 1;
    return leftTime.compareTo(rightTime);
  });
  if (diagnosticTimeline.length > 200) {
    diagnosticTimeline.removeRange(0, diagnosticTimeline.length - 200);
  }
  return {
    'format': 'syntila-workspace-diagnostics-v1',
    'appVersion': syntilaWorkspaceAppVersion,
    'workspaceVersion': syntilaWorkspaceAppVersion,
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
      // Transport, load and p50/p95/p99 per assignment stage interval. Only
      // numeric durations and bounded labels are exported.
      'latency': connection?.latencySummary(),
      'lastInventorySyncAt': connection?.lastInventorySyncAt?.toIso8601String(),
      'acceptingNewWork': connection?.acceptingNewWork ?? false,
      'draining': connection?.isDraining ?? false,
    },
    // A diagnostic export reports configuration state, never a user-local
    // filesystem path. The path remains available to the local UI only.
    'workRoot': {
      'configured': workRootPath != null || config.workRootPath != null,
    },
    'diagnosticCompleteness': {
      'cloudEvidence': connection?.isConnected ?? false,
      'workspaceEvidence': true,
      'workerEvidence': localDiagnosticsAvailable,
      'localWorkerStoreConfigured': workerDiagnosticStore != null,
    },
    'update': {
      'status': updateStatus ?? 'unknown',
      'lastCheckStatus': lastUpdateCheckStatus ?? 'unknown',
      'lastCheckAt': lastUpdateCheckAt?.toUtc().toIso8601String(),
    },
    'workers': workers,
    'assignments': assignments,
    'activityObservability': {
      'missingTerminalEventCount': missingTerminalEventCount,
      'forwardingFailureCount': forwardingFailureCount,
      'staleRunningCount': staleRunningCount,
      'staleRunningThresholdMs': staleRunningThreshold.inMilliseconds,
      'maxStaleRunningDurationMs': maxStaleRunningDurationMs,
      'timelineEventCount': diagnosticTimeline.length,
    },
    'diagnosticTimeline': diagnosticTimeline,
    'workerDiagnosticEvents': workerDiagnostics,
    'logs': recentLogs.map((line) {
      try {
        return _safeDiagnosticLog(jsonDecode(line));
      } on FormatException {
        return _safeDiagnosticLog(null);
      }
    }).toList(),
  };
}

bool _diagnosticEventMatches(String event, String suffix) =>
    event == suffix || event == 'worker.$suffix' || event.endsWith('.$suffix');

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
  WorkerProfileStorePort? toolProfileReleaseStore,
  ToolProfileCatalogClient? toolProfileCatalog,
  String? lastUpdateCheckStatus,
  DateTime? lastUpdateCheckAt,
  String? updateStatus,
  String? workRootPath,
  WorkerDiagnosticStore Function(String workerTypeId)? workerDiagnosticStore,
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
    workerDiagnosticStore: workerDiagnosticStore,
  );
  final file = File(
      '${config.dataDirectory.path}/diagnostics-${DateTime.now().toUtc().millisecondsSinceEpoch}.json');
  await file.writeAsString(jsonEncode(diagnostics), flush: true);
  await currentPlatformRuntime.restrictPermissions(file.path, directory: false);
  return file;
}

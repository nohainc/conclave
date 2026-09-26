import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'cloud_connection.dart';
import 'host.dart';
import 'platform_runtime.dart';
import 'workspace_enrollment.dart';
import 'v7_adapter_package_store.dart';
import 'local_worker_setup.dart';
import 'adapter_prerequisite.dart';

const _diagnosticSecretPattern =
    r'(secret|token|password|api[_-]?key|authorization|cookie|raw[_-]?credential|private[_-]?key)';

Object? sanitizeHostDiagnostics(Object? value, {int depth = 0}) {
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
        .map((item) => sanitizeHostDiagnostics(item, depth: depth + 1))
        .toList();
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries.take(80))
        entry.key.toString():
            RegExp(_diagnosticSecretPattern, caseSensitive: false)
                    .hasMatch(entry.key.toString())
                ? '[redacted]'
                : sanitizeHostDiagnostics(entry.value, depth: depth + 1),
    };
  }
  return '[${value.runtimeType}]';
}

Future<Map<String, Object?>> buildHostDiagnostics({
  required HostConfig config,
  HostCloudConnection? connection,
  AssignmentJournal? journal,
  LocalConfiguredWorkerRegistry? workerRegistry,
  V7AdapterPackageStore? adapterPackageStore,
  String? lastUpdateCheckStatus,
  DateTime? lastUpdateCheckAt,
  String? updateStatus,
  String? workRootPath,
  int logLineLimit = 200,
}) async {
  final logFile = File('${config.dataDirectory.path}/logs/host.log');
  final lines =
      await logFile.exists() ? await logFile.readAsLines() : <String>[];
  final recentLogs = lines.length <= logLineLimit
      ? lines
      : lines.sublist(lines.length - logLineLimit);
  final assignments = <Map<String, Object?>>[];
  final workers = <Map<String, Object?>>[];
  for (final worker
      in await workerRegistry?.list(includeRemoved: true) ?? const []) {
    Map<String, Object?>? adapter;
    try {
      adapter = await adapterPackageStore?.activeManifestSummary(worker);
    } on Object {
      // Keep diagnostics safe when the package is invalid or revoked.
    }
    final matchingOptions = LocalWorkerTypeOption.supported
        .where((item) => item.id == worker.workerTypeId);
    final option = matchingOptions.isEmpty ? null : matchingOptions.first;
    final prerequisites = <Map<String, Object?>>[];
    final declared = [
      if (option?.executablePrerequisite != null)
        option!.executablePrerequisite!,
      ...?option?.additionalPrerequisites,
    ];
    for (final prerequisite in declared) {
      try {
        final result = await probeAdapterExecutable(prerequisite);
        prerequisites.add({
          'executable': prerequisite.executable,
          'satisfied': result.satisfied,
          'version': result.detectedVersion,
        });
      } on Object {
        prerequisites.add({
          'executable': prerequisite.executable,
          'satisfied': false,
        });
      }
    }
    workers.add({
      'workerId': worker.id,
      'workerTypeId': worker.workerTypeId,
      'status': worker.status.name,
      'credentialStatus': worker.credentialStatus.name,
      'adapterVersion': adapter?['adapterVersion'],
      'prerequisites': prerequisites,
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
        if (record.hostId != null) 'hostId': record.hostId,
        if (record.workerId != null) 'workerId': record.workerId,
        if (record.runId != null) 'runId': record.runId,
        if (record.taskId != null) 'taskId': record.taskId,
        if (record.attemptId != null) 'attemptId': record.attemptId,
      });
    }
  }
  return {
    'format': 'conclave-host-diagnostics-v1',
    'appVersion': conclaveWorkspaceAppVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'host': {
      'hostId': config.hostId,
      'workspaceId': config.workspaceId,
      'cloudConnected': connection?.isConnected ?? false,
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
        return sanitizeHostDiagnostics(jsonDecode(line));
      } on FormatException {
        return sanitizeHostDiagnostics(line);
      }
    }).toList(),
  };
}

Future<File> writeHostDiagnostics({
  required HostConfig config,
  HostCloudConnection? connection,
  AssignmentJournal? journal,
  LocalConfiguredWorkerRegistry? workerRegistry,
  V7AdapterPackageStore? adapterPackageStore,
  String? lastUpdateCheckStatus,
  DateTime? lastUpdateCheckAt,
  String? updateStatus,
  String? workRootPath,
}) async {
  final diagnostics = await buildHostDiagnostics(
    config: config,
    connection: connection,
    journal: journal,
    workerRegistry: workerRegistry,
    adapterPackageStore: adapterPackageStore,
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

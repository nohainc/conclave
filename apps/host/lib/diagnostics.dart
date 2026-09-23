import 'dart:convert';
import 'dart:io';

import 'assignment_journal.dart';
import 'cloud_connection.dart';
import 'host.dart';
import 'platform_runtime.dart';

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
  int logLineLimit = 200,
}) async {
  final logFile = File('${config.dataDirectory.path}/logs/host.log');
  final lines =
      await logFile.exists() ? await logFile.readAsLines() : <String>[];
  final recentLogs = lines.length <= logLineLimit
      ? lines
      : lines.sublist(lines.length - logLineLimit);
  final assignments = <Map<String, Object?>>[];
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
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'host': {
      'hostId': config.hostId,
      'workspaceId': config.workspaceId,
      'cloudConnected': connection?.isConnected ?? false,
      'reconnectCount': connection?.reconnectCount ?? 0,
      'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
    },
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
}) async {
  final diagnostics = await buildHostDiagnostics(
    config: config,
    connection: connection,
    journal: journal,
  );
  final file = File(
      '${config.dataDirectory.path}/diagnostics-${DateTime.now().toUtc().millisecondsSinceEpoch}.json');
  await file.writeAsString(jsonEncode(diagnostics), flush: true);
  await currentPlatformRuntime.restrictPermissions(file.path, directory: false);
  return file;
}

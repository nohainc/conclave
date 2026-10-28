import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/assignment_journal.dart';
import 'package:syntila_workspace/diagnostics.dart';
import 'package:syntila_workspace/workspace.dart';
import 'package:syntila_workspace/cloud_connection.dart';
import 'package:test/test.dart';

void main() {
  test('process metrics are sampled on demand', () async {
    final metrics = await sampleWorkspaceProcessMetrics();
    expect(metrics['processId'], pid);
    expect(metrics['residentMemoryBytes'], isA<int>());
    expect(metrics['residentMemoryBytes'], greaterThan(0));
    expect(metrics['cpuPercent'], anyOf(isA<double>(), isNull));
    expect(DateTime.tryParse(metrics['sampledAt']! as String), isNotNull);
  });

  test('diagnostics redact secrets and preserve assignment correlation',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('syntila-diagnostics-');
    File('${directory.path}/logs/workspace.log')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'level': 'error',
        'message': 'worker failed',
        'details': {
          'assignmentId': 'assignment-1',
          'apiKey': 'secret-value',
          'providerToolPath': '/Users/private/.agy/bin/agy',
        },
      }));
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.failed,
      updatedAt: DateTime.utc(2026, 9, 23),
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
    ));

    final export = await buildWorkspaceDiagnostics(
      config: WorkspaceConfig(
          dataDirectory: directory, workspaceRuntimeId: 'workspace-1'),
      journal: journal,
    );
    final exported = jsonEncode(export);
    expect(exported, contains('assignment-1'));
    expect(exported, contains('run-1'));
    expect(exported, contains('appVersion'));
    expect(exported, contains('workspaceVersion'));
    expect(exported, contains('cliWorkerEngineVersion'));
    expect(exported, contains('activeAssignmentCount'));
    expect(exported, contains('workRoot'));
    expect(exported, contains('diagnosticCompleteness'));
    expect(exported, contains('workerDiagnosticEvents'));
    expect((export['workRoot'] as Map)['configured'], isFalse);
    expect(exported, isNot(contains('secret-value')));
    expect(exported, isNot(contains('/Users/private/.agy/bin/agy')));
    expect(exported, contains('[redacted]'));
    await directory.delete(recursive: true);
  });

  test('connection diagnostics include exact safe failure stages', () async {
    final directory =
        await Directory.systemTemp.createTemp('syntila-connection-diag-');
    const runtimeSecret = 'workspace-runtime-secret-never-export';
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
        'wss://syntila.app/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1&authToken=must-not-leak',
      ),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => throw const WebSocketException(
        'upgrade rejected',
        HttpStatus.badRequest,
      ),
    );
    await expectLater(connection.connect(), throwsA(isA<WebSocketException>()));

    final diagnostics = await buildWorkspaceDiagnostics(
      config: WorkspaceConfig(
        dataDirectory: directory,
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        cloudUri: connection.uri,
        authToken: runtimeSecret,
      ),
      connection: connection,
    );
    final text = jsonEncode(diagnostics);
    final workspace = diagnostics['workspace'] as Map<String, Object?>;
    final connectionInfo = workspace['connection'] as Map<String, Object?>;

    expect(connectionInfo['stage'], 'offline');
    expect(connectionInfo['lastHttpStatusCode'], 400);
    expect(connectionInfo['dnsTls'], 'passed');
    expect(connectionInfo['webSocketUpgrade'], 'failed_http_400');
    expect(connectionInfo['protocolHello'], 'not started');
    expect(connectionInfo['runtimeCredential'],
        'available_locally_value_withheld');
    expect(connectionInfo['cloudOrigin'], 'https://syntila.app');
    expect(connectionInfo['webSocketEndpoint'],
        'wss://syntila.app/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1');
    expect(text, isNot(contains(runtimeSecret)));
    expect(text, isNot(contains('must-not-leak')));
    expect(text, isNot(contains('must-not-leak')));
    await directory.delete(recursive: true);
  });

  test('activity observability reports stale running assignments and timeline',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('syntila-observability-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-running',
      executionId: 'execution-running',
      status: AssignmentStatus.running,
      updatedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 8)),
      processExitCode: null,
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-failed',
      executionId: 'execution-failed',
      status: AssignmentStatus.failed,
      updatedAt: DateTime.now().toUtc(),
      processExitCode: 7,
      errorCode: 'provider_failure',
    ));

    final export = await buildWorkspaceDiagnostics(
      config: WorkspaceConfig(dataDirectory: directory),
      journal: journal,
    );
    final observability =
        export['activityObservability'] as Map<String, Object?>;
    final timeline = export['diagnosticTimeline'] as List<Object?>;
    expect(observability['staleRunningCount'], 1);
    expect(observability['maxStaleRunningDurationMs'], greaterThan(0));
    expect(observability['missingTerminalEventCount'], 0);
    expect(observability['forwardingFailureCount'], 0);
    expect(observability['timelineEventCount'], 2);
    expect(timeline, hasLength(2));
    expect((timeline.last as Map)['processExitCode'], 7);
    await directory.delete(recursive: true);
  });
}

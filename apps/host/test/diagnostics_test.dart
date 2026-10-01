import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/diagnostics.dart';
import 'package:conclave_host/host.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:test/test.dart';

void main() {
  test('diagnostics redact secrets and preserve assignment correlation',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-diagnostics-');
    File('${directory.path}/logs/host.log')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'level': 'error',
        'message': 'worker failed',
        'details': {'assignmentId': 'assignment-1', 'apiKey': 'secret-value'},
      }));
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.failed,
      updatedAt: DateTime.utc(2026, 9, 23),
      workspaceId: 'workspace-1',
      hostId: 'host-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
    ));

    final export = await buildHostDiagnostics(
      config: HostConfig(dataDirectory: directory, hostId: 'host-1'),
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
    expect(exported, isNot(contains('secret-value')));
    expect(exported, contains('[redacted]'));
    await directory.delete(recursive: true);
  });

  test('connection diagnostics include exact safe failure stages', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-connection-diag-');
    const runtimeSecret = 'workspace-runtime-secret-never-export';
    final connection = HostCloudConnection(
      uri: Uri.parse(
        'wss://app.conclaveax.com/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1&authToken=must-not-leak',
      ),
      hostId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => throw const WebSocketException(
        'upgrade rejected',
        HttpStatus.badRequest,
      ),
    );
    await expectLater(connection.connect(), throwsA(isA<WebSocketException>()));

    final diagnostics = await buildHostDiagnostics(
      config: HostConfig(
        dataDirectory: directory,
        hostId: 'runtime-1',
        workspaceId: 'workspace-1',
        cloudUri: connection.uri,
        authToken: runtimeSecret,
      ),
      connection: connection,
    );
    final text = jsonEncode(diagnostics);
    final host = diagnostics['host'] as Map<String, Object?>;
    final connectionInfo = host['connection'] as Map<String, Object?>;

    expect(connectionInfo['stage'], 'offline');
    expect(connectionInfo['lastHttpStatusCode'], 400);
    expect(connectionInfo['dnsTls'], 'passed');
    expect(connectionInfo['webSocketUpgrade'], 'failed_http_400');
    expect(connectionInfo['protocolHello'], 'not started');
    expect(connectionInfo['runtimeCredential'],
        'available_locally_value_withheld');
    expect(connectionInfo['cloudOrigin'], 'https://app.conclaveax.com');
    expect(connectionInfo['webSocketEndpoint'],
        'wss://app.conclaveax.com/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1');
    expect(text, isNot(contains(runtimeSecret)));
    expect(text, isNot(contains('must-not-leak')));
    expect(text, isNot(contains('must-not-leak')));
    await directory.delete(recursive: true);
  });
}

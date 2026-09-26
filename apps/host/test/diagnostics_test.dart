import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/diagnostics.dart';
import 'package:conclave_host/host.dart';
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
    expect(exported, contains('activeAssignmentCount'));
    expect(exported, contains('workRoot'));
    expect(exported, isNot(contains('secret-value')));
    expect(exported, contains('[redacted]'));
    await directory.delete(recursive: true);
  });
}

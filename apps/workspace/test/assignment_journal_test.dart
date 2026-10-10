import 'dart:io';

import 'package:conclave_workspace/assignment_journal.dart';
import 'package:test/test.dart';

void main() {
  test('reconciles the latest idempotent assignment state', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      result: {'ok': true},
    ));

    final state = await journal.reconcile();
    expect(state['assignment-1']!.status, AssignmentStatus.completed);
    expect(state['assignment-1']!.result?['ok'], true);
    await directory.delete(recursive: true);
  });

  test('ignores a truncated final record after a process crash', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final file = File('${directory.path}/assignments.jsonl');
    final journal = AssignmentJournal(file);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await file.writeAsString('{"assignmentId":"partial"',
        mode: FileMode.append);
    final state = await journal.reconcile();
    expect(state['assignment-1']!.status, AssignmentStatus.completed);
    await directory.delete(recursive: true);
  });

  test('rejects corruption in a complete non-final record', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final file = File('${directory.path}/assignments.jsonl');
    await file.writeAsString(
      '{"assignmentId":"assignment-1","status":"running","updatedAt":"2026-01-01T00:00:00Z"}\n'
      '{"assignmentId":"assignment-2","status":"running"}\n',
    );
    await expectLater(
      AssignmentJournal(file).reconcile(),
      throwsFormatException,
    );
    await directory.delete(recursive: true);
  });

  test('uses the later record when timestamps are equal', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final timestamp = DateTime.utc(2026, 1, 1);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.received,
      updatedAt: timestamp,
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.accepted,
      updatedAt: timestamp,
    ));
    expect((await journal.reconcile())['assignment-1']!.status,
        AssignmentStatus.accepted);
    await directory.delete(recursive: true);
  });

  test('uses timestamps rather than append order during replay', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 2),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    expect((await journal.reconcile())['assignment-1']!.status,
        AssignmentStatus.completed);
    await directory.delete(recursive: true);
  });

  test('rejects a transition from a terminal state back to running', () async {
    final directory = await Directory.systemTemp.createTemp('journal-');
    final file = File('${directory.path}/assignments.jsonl');
    final journal = AssignmentJournal(file);
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
    ));
    await expectLater(journal.reconcile(), throwsFormatException);
    await directory.delete(recursive: true);
  });

  test('marks started work outcome-unknown after a service restart', () async {
    final directory =
        await Directory.systemTemp.createTemp('journal-recovery-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-running',
      status: AssignmentStatus.running,
      updatedAt: DateTime.utc(2026, 1, 1),
      workerId: 'worker-1',
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-received',
      status: AssignmentStatus.received,
      updatedAt: DateTime.utc(2026, 1, 1),
    ));

    final recovered = await journal.recoverAfterRestart();
    expect(
        recovered['assignment-running']!.status, AssignmentStatus.interrupted);
    expect(recovered['assignment-running']!.result?['recoveryState'],
        'outcome_unknown');
    expect(recovered['assignment-received']!.result?['recoveryState'],
        'not_started');
    final recoveredAgain = await journal.recoverAfterRestart();
    expect(
        recoveredAgain.values
            .where((record) => record.status == AssignmentStatus.interrupted)
            .length,
        2);
    await directory.delete(recursive: true);
  });
}

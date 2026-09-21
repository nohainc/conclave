import 'dart:io';

import 'package:conclave_agent_engine/assignment_journal.dart';
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
}

import 'dart:io';

import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/main.dart';

void main() {
  test('Host launches, minimizes/restores, and quits cleanly', () async {
    final directory = await Directory.systemTemp.createTemp('conclave-host-');
    final lifecycle = HostLifecycleController(
      Host(config: HostConfig(dataDirectory: directory)),
    );

    await lifecycle.launch();
    expect(lifecycle.running, isTrue);
    lifecycle.minimize();
    expect(lifecycle.hidden, isTrue);
    lifecycle.restore();
    expect(lifecycle.hidden, isFalse);
    await lifecycle.quit();
    expect(lifecycle.quitting, isTrue);
    expect(lifecycle.running, isFalse);
  });

  test('assignment journal recovers interrupted work after restart', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-host-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final now = DateTime.now().toUtc();
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.running,
      updatedAt: now,
      hostId: 'host-1',
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.interrupted,
      updatedAt: now.add(const Duration(seconds: 1)),
      hostId: 'host-1',
    ));

    final recovered = await AssignmentJournal(journal.file).reconcile();
    expect(recovered['assignment-1']?.status, AssignmentStatus.interrupted);
  });
}

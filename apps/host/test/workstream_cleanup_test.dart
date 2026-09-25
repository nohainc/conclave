import 'dart:io';

import 'package:conclave_host/workstream_cleanup.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_marker.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory workstream;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-cleanup-');
    workstream = await WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    ).ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    await File('${workstream.path}${Platform.pathSeparator}notes.txt')
        .writeAsString('unpublished work');
  });

  tearDown(() => root.delete(recursive: true));

  WorkstreamCleanupService service({bool active = false}) =>
      WorkstreamCleanupService(
        workRoot: root,
        hasActiveAssignment: (_) async => active,
      );

  test('scans marker-backed directories and reports disk usage', () async {
    final result = await service().scan(
      classify: (_) async => 'workspace_revoked',
    );

    expect(result.issues, isEmpty);
    expect(result.candidates, hasLength(1));
    expect(result.candidates.single.marker.projectId, 'project-1');
    expect(result.candidates.single.classification, 'workspace_revoked');
    expect(result.candidates.single.sizeBytes, greaterThan(0));
    expect(result.candidates.single.confirmationText,
        'DELETE project-1/workstream-1');
  });

  test('does not treat an unmarked directory as deletable data', () async {
    final unknown = Directory(
      '${root.path}${Platform.pathSeparator}project-unknown${Platform.pathSeparator}workstream-unknown',
    );
    await unknown.create(recursive: true);
    await File('${unknown.path}${Platform.pathSeparator}important.txt')
        .writeAsString('do not adopt');

    final result = await service().scan();
    expect(result.candidates, hasLength(1));
    expect(result.issues, isEmpty);
    expect(await unknown.exists(), isTrue);
  });

  test('requires exact explicit confirmation before deletion', () async {
    final result = await service().scan();
    final candidate = result.candidates.single;

    await expectLater(
      service().delete(candidate, confirmation: 'delete it'),
      throwsA(isA<WorkstreamCleanupViolation>()),
    );
    expect(await workstream.exists(), isTrue);

    await service().delete(
      candidate,
      confirmation: candidate.confirmationText,
    );
    expect(await workstream.exists(), isFalse);
  });

  test('retains data while an assignment is active', () async {
    final candidate = (await service().scan()).candidates.single;
    await expectLater(
      service(active: true).delete(
        candidate,
        confirmation: candidate.confirmationText,
      ),
      throwsA(isA<WorkstreamCleanupViolation>()),
    );
    expect(await workstream.exists(), isTrue);
  });

  test('does not delete while a mutation is active and holds its lock',
      () async {
    final candidate = (await service().scan()).candidates.single;
    final lockFile = File(
      '${workstream.path}${Platform.pathSeparator}.conclave-workstream.lock',
    );
    final handle = await lockFile.open(mode: FileMode.append);
    await handle.lock(FileLock.exclusive);
    try {
      await expectLater(
        service(active: true).delete(
          candidate,
          confirmation: candidate.confirmationText,
        ),
        throwsA(isA<WorkstreamCleanupViolation>()),
      );
      expect(await workstream.exists(), isTrue);
    } finally {
      await handle.unlock();
      await handle.close();
    }
  });

  test('reports corrupt marker as a cleanup issue and never deletes it',
      () async {
    await File(
      '${workstream.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}',
    ).writeAsString('{not-json');

    final result = await service().scan();
    expect(result.candidates, isEmpty);
    expect(result.issues, hasLength(1));
    expect(await workstream.exists(), isTrue);
  });
}

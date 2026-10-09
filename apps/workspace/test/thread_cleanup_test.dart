import 'dart:io';

import 'package:conclave_workspace/thread_cleanup.dart';
import 'package:conclave_workspace/thread_directory.dart';
import 'package:conclave_workspace/thread_marker.dart';
import 'package:conclave_workspace/thread_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory thread;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-cleanup-');
    thread = await ThreadDirectoryLifecycle(
      pathResolver: ThreadPathResolver(root),
    ).ensureForExecution(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    await File('${thread.path}${Platform.pathSeparator}notes.txt')
        .writeAsString('unpublished work');
  });

  tearDown(() => root.delete(recursive: true));

  ThreadCleanupService service({bool active = false}) => ThreadCleanupService(
        workRoot: root,
        hasActiveAssignment: (_) async => active,
      );

  test('scans marker-backed directories and reports disk usage', () async {
    final result = await service().scan(
      classify: (_) async => 'workspace_revoked',
    );

    expect(result.issues, isEmpty);
    expect(result.candidates, hasLength(1));
    expect(result.candidates.single.marker.spaceId, 'space-1');
    expect(result.candidates.single.classification, 'workspace_revoked');
    expect(result.candidates.single.sizeBytes, greaterThan(0));
    expect(
        result.candidates.single.confirmationText, 'DELETE space-1/thread-1');
  });

  test('does not treat an unmarked directory as deletable data', () async {
    final unknown = Directory(
      '${root.path}${Platform.pathSeparator}space-unknown${Platform.pathSeparator}thread-unknown',
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
      throwsA(isA<ThreadCleanupViolation>()),
    );
    expect(await thread.exists(), isTrue);

    await service().delete(
      candidate,
      confirmation: candidate.confirmationText,
    );
    expect(await thread.exists(), isFalse);
  });

  test('retains data while an assignment is active', () async {
    final candidate = (await service().scan()).candidates.single;
    await expectLater(
      service(active: true).delete(
        candidate,
        confirmation: candidate.confirmationText,
      ),
      throwsA(isA<ThreadCleanupViolation>()),
    );
    expect(await thread.exists(), isTrue);
  });

  test('does not delete while a mutation is active and holds its lock',
      () async {
    final candidate = (await service().scan()).candidates.single;
    final lockFile = File(
      '${root.path}${Platform.pathSeparator}.conclave-mutation-locks'
      '${Platform.pathSeparator}space-1${Platform.pathSeparator}'
      'thread-1.lock',
    );
    await lockFile.parent.create(recursive: true);
    final handle = await lockFile.open(mode: FileMode.append);
    await handle.lock(FileLock.exclusive);
    try {
      await expectLater(
        service(active: true).delete(
          candidate,
          confirmation: candidate.confirmationText,
        ),
        throwsA(isA<ThreadCleanupViolation>()),
      );
      expect(await thread.exists(), isTrue);
    } finally {
      await handle.unlock();
      await handle.close();
    }
  });

  test('reports corrupt marker as a cleanup issue and never deletes it',
      () async {
    await File(
      '${thread.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}',
    ).writeAsString('{not-json');

    final result = await service().scan();
    expect(result.candidates, isEmpty);
    expect(result.issues, hasLength(1));
    expect(await thread.exists(), isTrue);
  });

  test('never deletes a Thread directory under a shared Space directory',
      () async {
    await File(
      '${thread.parent.path}${Platform.pathSeparator}.conclave-space.json',
    ).writeAsString('{"spaceId":"space-1"}');
    final candidate = (await service().scan()).candidates.single;

    await expectLater(
      service().delete(candidate, confirmation: candidate.confirmationText),
      throwsA(isA<ThreadCleanupViolation>()),
    );
    expect(await thread.exists(), isTrue);
  });
}

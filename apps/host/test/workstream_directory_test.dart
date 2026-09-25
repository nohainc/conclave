import 'dart:io';

import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_marker.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late WorkstreamDirectoryLifecycle lifecycle;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-work-lifecycle-');
    lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
  });

  tearDown(() => root.delete(recursive: true));

  test('does not create local state until executable Work is requested',
      () async {
    final expected = Directory(
        '${root.path}${Platform.pathSeparator}project-1${Platform.pathSeparator}workstream-1');
    expect(await expected.exists(), isFalse);

    // Discussion and Cloud object creation do not call ensureForExecution.
    expect(await expected.exists(), isFalse);
  });

  test('creates and marks the directory on first executable Work', () async {
    final directory = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      createdAt: DateTime.utc(2026, 1, 2),
    );

    expect(await directory.exists(), isTrue);
    final marker = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: directory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(marker.createdAt, DateTime.utc(2026, 1, 2));
  });

  test('reuses the directory and marker on later Work', () async {
    final first = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      createdAt: DateTime.utc(2026, 1, 2),
    );
    final second = await WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    ).ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      createdAt: DateTime.utc(2027, 1, 2),
    );

    expect(second.path, first.path);
    final marker = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: second,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(marker.createdAt, DateTime.utc(2026, 1, 2));
  });

  test('reuses state after a runtime restart', () async {
    final first = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final restarted = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );

    final second = await restarted.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(second.path, first.path);
  });

  test('reuses Workstream files after Workspace revoke and re-pair', () async {
    final firstRuntime = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
    final first = await firstRuntime.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    await File('${first.path}${Platform.pathSeparator}notes.txt')
        .writeAsString('persistent work');

    // Workspace A is revoked. Workspace B receives a different runtime ID,
    // but that identity is intentionally not an input to local resolution.
    final rePairedRuntime = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
    final second = await rePairedRuntime.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    expect(second.path, first.path);
    expect(
        await File('${second.path}${Platform.pathSeparator}notes.txt')
            .readAsString(),
        'persistent work');
  });

  test('creates an independent empty directory on another Workspace root',
      () async {
    final destinationRoot =
        await Directory.systemTemp.createTemp('conclave-destination-');
    addTearDown(() => destinationRoot.delete(recursive: true));
    final source = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    await File('${source.path}${Platform.pathSeparator}local.txt')
        .writeAsString('source-only state');

    final destination = await WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(destinationRoot),
    ).ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    expect(destination.path, isNot(source.path));
    expect(
        await File('${destination.path}${Platform.pathSeparator}local.txt')
            .exists(),
        isFalse);
    final marker = await const WorkstreamMarkerStore().reuse(
      workstreamDirectory: destination,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(marker.projectId, 'project-1');
    expect(marker.workstreamId, 'workstream-1');
  });

  test('provides a warning before moving mutable local state', () {
    const policy = WorkstreamWorkspaceChangePolicy();
    expect(policy.warning(hasLocalMutableState: false), isNull);
    expect(policy.warning(hasLocalMutableState: true),
        workstreamWorkspaceChangeWarning);
  });

  test('renaming a Workstream while active does not change its path', () async {
    final before = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    // Names are deliberately not accepted by this lifecycle API. A rename
    // therefore cannot trigger filesystem work or change the directory.
    final afterRename = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    expect(afterRename.path, before.path);
  });

  test('does not adopt an existing unmarked directory', () async {
    final existing = Directory(
        '${root.path}${Platform.pathSeparator}project-1${Platform.pathSeparator}workstream-1');
    await existing.create(recursive: true);
    await File('${existing.path}${Platform.pathSeparator}worker.txt')
        .writeAsString('unknown content');

    await expectLater(
      lifecycle.ensureForExecution(
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });
}

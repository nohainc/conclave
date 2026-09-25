import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/workstream_marker.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  const store = WorkstreamMarkerStore();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conclave-marker-');
  });

  tearDown(() => directory.delete(recursive: true));

  test('creates an atomic marker and safely reuses it', () async {
    final created = await store.create(
      workstreamDirectory: directory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    expect(created.schemaVersion, 1);
    expect(created.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    final file = File(
        '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}');
    expect(jsonDecode(await file.readAsString()), {
      'schemaVersion': 1,
      'projectId': 'project-1',
      'workstreamId': 'workstream-1',
      'createdAt': '2026-01-02T03:04:05.000Z',
    });

    final reused = await store.reuse(
      workstreamDirectory: directory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    expect(reused.projectId, 'project-1');
    expect(reused.workstreamId, 'workstream-1');
  });

  test('rejects a mismatched Project ID', () async {
    await store.create(
      workstreamDirectory: directory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    await expectLater(
      store.reuse(
        workstreamDirectory: directory,
        projectId: 'project-2',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });

  test('rejects a mismatched Workstream ID', () async {
    await store.create(
      workstreamDirectory: directory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    await expectLater(
      store.reuse(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-2',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });

  test('rejects corrupt marker JSON', () async {
    await File(
            '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}')
        .writeAsString('{not-json');

    await expectLater(
      store.reuse(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });

  test('rejects a missing marker instead of adopting unknown data', () async {
    await File('${directory.path}${Platform.pathSeparator}unknown.txt')
        .writeAsString('do not adopt');

    await expectLater(
      store.reuse(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });

  test('rejects interrupted marker creation residue', () async {
    await File(
            '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}.123.tmp')
        .writeAsString('{');

    await expectLater(
      store.create(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });

  test('never adopts or overwrites an existing marker', () async {
    await store.create(
      workstreamDirectory: directory,
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    await expectLater(
      store.create(
        workstreamDirectory: directory,
        projectId: 'project-1',
        workstreamId: 'workstream-1',
      ),
      throwsA(isA<WorkstreamMarkerViolation>()),
    );
  });
}

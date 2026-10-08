import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/thread_marker.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  const store = ThreadMarkerStore();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conclave-marker-');
  });

  tearDown(() => directory.delete(recursive: true));

  test('creates an atomic marker and safely reuses it', () async {
    final created = await store.create(
      threadDirectory: directory,
      spaceId: 'space-1',
      threadId: 'thread-1',
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

    expect(created.schemaVersion, 1);
    expect(created.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    final file = File(
        '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}');
    expect(jsonDecode(await file.readAsString()), {
      'schemaVersion': 1,
      'spaceId': 'space-1',
      'threadId': 'thread-1',
      'createdAt': '2026-01-02T03:04:05.000Z',
    });

    final reused = await store.reuse(
      threadDirectory: directory,
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    expect(reused.spaceId, 'space-1');
    expect(reused.threadId, 'thread-1');
  });

  test('rejects a mismatched Space ID', () async {
    await store.create(
      threadDirectory: directory,
      spaceId: 'space-1',
      threadId: 'thread-1',
    );

    await expectLater(
      store.reuse(
        threadDirectory: directory,
        spaceId: 'space-2',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
  });

  test('rejects a mismatched Thread ID', () async {
    await store.create(
      threadDirectory: directory,
      spaceId: 'space-1',
      threadId: 'thread-1',
    );

    await expectLater(
      store.reuse(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-2',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
  });

  test('rejects corrupt marker JSON', () async {
    await File(
            '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}')
        .writeAsString('{not-json');

    await expectLater(
      store.reuse(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
  });

  test('rejects a missing marker instead of adopting unknown data', () async {
    await File('${directory.path}${Platform.pathSeparator}unknown.txt')
        .writeAsString('do not adopt');

    await expectLater(
      store.reuse(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
  });

  test('rejects interrupted marker creation residue', () async {
    await File(
            '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}.123.tmp')
        .writeAsString('{');

    await expectLater(
      store.create(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
  });

  test('never adopts or overwrites an existing marker', () async {
    await store.create(
      threadDirectory: directory,
      spaceId: 'space-1',
      threadId: 'thread-1',
    );

    await expectLater(
      store.create(
        threadDirectory: directory,
        spaceId: 'space-1',
        threadId: 'thread-1',
      ),
      throwsA(isA<ThreadMarkerViolation>()),
    );
  });
}

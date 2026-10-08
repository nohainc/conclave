import 'dart:io';

import 'package:conclave_workspace/thread_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ThreadPathResolver resolver;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-work-path-');
    resolver = ThreadPathResolver(root);
  });

  tearDown(() => root.delete(recursive: true));

  test('resolves only Space ID and Thread ID deterministically', () async {
    final first = await resolver.resolve(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final second = await ThreadPathResolver(root).resolve(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );

    expect(first.path, second.path);
    final canonicalRoot = await root.resolveSymbolicLinks();
    expect(first.path,
        '$canonicalRoot${Platform.pathSeparator}space-1${Platform.pathSeparator}thread-1');
  });

  test('renames and Workspace re-enrollment have zero path effect', () async {
    final before = await resolver.resolve(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final afterRename = await resolver.resolve(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );
    final afterReenrollment = await ThreadPathResolver(root).resolve(
      spaceId: 'space-1',
      threadId: 'thread-1',
    );

    expect(afterRename.path, before.path);
    expect(afterReenrollment.path, before.path);
  });

  test('separates Spaces with the same Thread ID', () async {
    final one = await resolver.resolve(
      spaceId: 'space-1',
      threadId: 'shared-name-like-id',
    );
    final two = await resolver.resolve(
      spaceId: 'space-2',
      threadId: 'shared-name-like-id',
    );

    expect(one.path, isNot(two.path));
    expect(
        one.path,
        endsWith(
            '${Platform.pathSeparator}space-1${Platform.pathSeparator}shared-name-like-id'));
    expect(
        two.path,
        endsWith(
            '${Platform.pathSeparator}space-2${Platform.pathSeparator}shared-name-like-id'));
  });

  test('rejects traversal, separators, dot components, and Unicode IDs',
      () async {
    for (final spaceId in [
      '../outside',
      r'space\outside',
      '.',
      '..',
      'space name',
      '项目'
    ]) {
      await expectLater(
        resolver.resolve(spaceId: spaceId, threadId: 'stream-1'),
        throwsA(isA<ThreadPathViolation>()),
      );
    }
    await expectLater(
      resolver.resolve(spaceId: 'space-1', threadId: '../outside'),
      throwsA(isA<ThreadPathViolation>()),
    );
  });

  test('rejects an existing symlink that escapes the Work Root', () async {
    final outside = await Directory.systemTemp.createTemp('conclave-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await Link('${root.path}${Platform.pathSeparator}space-1')
        .create(outside.path);

    await expectLater(
      resolver.resolve(spaceId: 'space-1', threadId: 'stream-1'),
      throwsA(isA<ThreadPathViolation>()),
    );
  });

  test('does not create paths during resolution', () async {
    final result = await resolver.resolve(
      spaceId: 'space-1',
      threadId: 'stream-1',
    );
    expect(await result.exists(), isFalse);
  });
}

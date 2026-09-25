import 'dart:io';

import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late WorkstreamPathResolver resolver;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-work-path-');
    resolver = WorkstreamPathResolver(root);
  });

  tearDown(() => root.delete(recursive: true));

  test('resolves only Project ID and Workstream ID deterministically',
      () async {
    final first = await resolver.resolve(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final second = await WorkstreamPathResolver(root).resolve(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    expect(first.path, second.path);
    final canonicalRoot = await root.resolveSymbolicLinks();
    expect(first.path,
        '$canonicalRoot${Platform.pathSeparator}project-1${Platform.pathSeparator}workstream-1');
  });

  test('renames and Workspace re-enrollment have zero path effect', () async {
    final before = await resolver.resolve(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final afterRename = await resolver.resolve(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
    final afterReenrollment = await WorkstreamPathResolver(root).resolve(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );

    expect(afterRename.path, before.path);
    expect(afterReenrollment.path, before.path);
  });

  test('separates Projects with the same Workstream ID', () async {
    final one = await resolver.resolve(
      projectId: 'project-1',
      workstreamId: 'shared-name-like-id',
    );
    final two = await resolver.resolve(
      projectId: 'project-2',
      workstreamId: 'shared-name-like-id',
    );

    expect(one.path, isNot(two.path));
    expect(
        one.path,
        endsWith(
            '${Platform.pathSeparator}project-1${Platform.pathSeparator}shared-name-like-id'));
    expect(
        two.path,
        endsWith(
            '${Platform.pathSeparator}project-2${Platform.pathSeparator}shared-name-like-id'));
  });

  test('rejects traversal, separators, dot components, and Unicode IDs',
      () async {
    for (final projectId in [
      '../outside',
      r'project\outside',
      '.',
      '..',
      'project name',
      '项目'
    ]) {
      await expectLater(
        resolver.resolve(projectId: projectId, workstreamId: 'stream-1'),
        throwsA(isA<WorkstreamPathViolation>()),
      );
    }
    await expectLater(
      resolver.resolve(projectId: 'project-1', workstreamId: '../outside'),
      throwsA(isA<WorkstreamPathViolation>()),
    );
  });

  test('rejects an existing symlink that escapes the Work Root', () async {
    final outside = await Directory.systemTemp.createTemp('conclave-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await Link('${root.path}${Platform.pathSeparator}project-1')
        .create(outside.path);

    await expectLater(
      resolver.resolve(projectId: 'project-1', workstreamId: 'stream-1'),
      throwsA(isA<WorkstreamPathViolation>()),
    );
  });

  test('does not create paths during resolution', () async {
    final result = await resolver.resolve(
      projectId: 'project-1',
      workstreamId: 'stream-1',
    );
    expect(await result.exists(), isFalse);
  });
}

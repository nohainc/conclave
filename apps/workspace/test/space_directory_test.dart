import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_workspace/space_directory.dart';

void main() {
  test('keeps a stable directory when the Space is renamed', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final resolver = SpaceDirectoryResolver(
      workRoot: Directory('${root.path}/work'),
      registryDirectory: Directory('${root.path}/state'),
    );

    final first = await resolver.resolve(
      spaceId: 'space-a',
      spaceName: 'Conclave AX',
    );
    final second = await resolver.resolve(
      spaceId: 'space-a',
      spaceName: 'Renamed Space',
    );

    expect(second.path, first.path);
    expect(File('${first.path}/.conclave-space.json').existsSync(), isTrue);
  });

  test('suffixes duplicate names and adopts a marked manual move', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );

    final first = await resolver.resolve(spaceId: 'space-a', spaceName: 'Plan');
    final second =
        await resolver.resolve(spaceId: 'space-b', spaceName: 'Plan');
    expect(first.path, isNot(second.path));
    expect(second.path, endsWith('Plan (2)'));

    final moved = Directory('${work.path}/Moved Plan');
    await Directory(first.path).rename(moved.path);
    final restored =
        await resolver.resolve(spaceId: 'space-a', spaceName: 'Plan');
    expect(restored.path, moved.path);

    final registry = jsonDecode(
      await File('${root.path}/state/space-directories.json').readAsString(),
    ) as Map;
    expect(
        (registry['spaces'] as Map)['space-a']['relativePath'], 'Moved Plan');
  });

  test('does not adopt an unmarked existing directory', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    await Directory('${work.path}/Space').create(recursive: true);
    await File('${work.path}/Space/user.txt').writeAsString('keep');
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );

    final resolved =
        await resolver.resolve(spaceId: 'space-a', spaceName: 'Space');
    expect(resolved.path, endsWith('Space (2)'));
    expect(File('${work.path}/Space/user.txt').readAsStringSync(), 'keep');
  });

  test('adopts the legacy Space ID directory after Work Root migration',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    await Directory('${work.path}/space-a/thread-a').create(recursive: true);
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );

    final resolved = await resolver.resolve(
      spaceId: 'space-a',
      spaceName: 'Conclave AX',
    );
    expect(resolved.path, endsWith('space-a'));
    expect(Directory('${resolved.path}/thread-a').existsSync(), isTrue);
  });

  test('keeps Space fencing metadata in application state', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    final state = Directory('${root.path}/state');
    final lifecycle = SpaceDirectoryLifecycle(
      SpaceDirectoryResolver(
        workRoot: work,
        registryDirectory: state,
      ),
    );
    await SpaceMutationCoordinator(
      lifecycle: lifecycle,
      applicationStateDirectory: state,
    ).withMutation<void>(
      spaceId: 'space-a',
      spaceName: 'Conclave AX',
      leaseId: 'lease-a',
      fencingToken: 1,
      action: (_) async {},
    );

    expect(
        File('${state.path}/space-fences/space-a.json').existsSync(), isTrue);
    expect(
        File('${work.path}/Conclave AX/.conclave-space-fence.json')
            .existsSync(),
        isFalse);
  });
}

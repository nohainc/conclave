import 'dart:async';
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

  test('adopts a marked manual move', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );

    final first = await resolver.resolve(spaceId: 'space-a', spaceName: 'Plan');
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

  test('asks before reusing a folder marked for another Space', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );
    final first = await resolver.resolve(spaceId: 'space-a', spaceName: 'Plan');
    await File('${first.path}/user.txt').writeAsString('keep');

    await expectLater(
      resolver.resolve(spaceId: 'space-b', spaceName: 'Plan'),
      throwsA(isA<SpaceFolderExistsException>()),
    );
    expect(Directory('${work.path}/Plan (2)').existsSync(), isFalse);

    final second = await resolver.resolve(
        spaceId: 'space-b', spaceName: 'Plan', adoptExistingFolder: true);
    expect(second.path, first.path);
    expect(File('${first.path}/user.txt').readAsStringSync(), 'keep');
    expect(
        jsonDecode(File('${first.path}/.conclave-space.json')
            .readAsStringSync())['spaceId'],
        'space-b');
  });

  test('asks before using an unmarked non-empty directory', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    await Directory('${work.path}/Space').create(recursive: true);
    await File('${work.path}/Space/user.txt').writeAsString('keep');
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );

    await expectLater(
      resolver.resolve(spaceId: 'space-a', spaceName: 'Space'),
      throwsA(isA<SpaceFolderExistsException>()),
    );
    expect(Directory('${work.path}/Space (2)').existsSync(), isFalse);
    expect(
        File('${work.path}/Space/.conclave-space.json').existsSync(), isFalse);

    final adopted = await resolver.resolve(
      spaceId: 'space-a',
      spaceName: 'Space',
      adoptExistingFolder: true,
    );
    expect(adopted.path, endsWith('Space'));
    expect(File('${work.path}/Space/user.txt').readAsStringSync(), 'keep');
    // Once adopted, later requests need no confirmation.
    final again =
        await resolver.resolve(spaceId: 'space-a', spaceName: 'Space');
    expect(again.path, adopted.path);
  });

  test('claims an empty unmarked directory without asking', () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    await Directory('${work.path}/Space').create(recursive: true);
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );
    final resolved =
        await resolver.resolve(spaceId: 'space-a', spaceName: 'Space');
    expect(resolved.path, endsWith('Space'));
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
      threadId: 'thread-a',
      spaceName: 'Conclave AX',
      leaseId: 'lease-a',
      fencingToken: 1,
      action: (_) async {},
    );

    expect(
        File('${state.path}/space-fences/space-a/thread-a.json').existsSync(),
        isTrue);
    expect(
        File('${work.path}/Conclave AX/.conclave-space-fence.json')
            .existsSync(),
        isFalse);
  });

  test('forgets registry entries of removed Spaces without touching folders',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );
    final kept = await resolver.resolve(spaceId: 'space-a', spaceName: 'Keep');
    final gone = await resolver.resolve(spaceId: 'space-b', spaceName: 'Gone');
    await File('${gone.path}/user.txt').writeAsString('mine');

    expect(await resolver.forgetSpacesExcept({'space-a'}), 1);

    final registry = jsonDecode(
      await File('${root.path}/state/space-directories.json').readAsString(),
    ) as Map;
    expect((registry['spaces'] as Map).keys, ['space-a']);
    expect(Directory(kept.path).existsSync(), isTrue);
    expect(File('${gone.path}/user.txt').readAsStringSync(), 'mine');
    expect(await resolver.forgetSpacesExcept({'space-a'}), 0);
  });

  test('runs different Threads of one Space in parallel, one Thread serially',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final state = Directory('${root.path}/state');
    final coordinator = SpaceMutationCoordinator(
      lifecycle: SpaceDirectoryLifecycle(SpaceDirectoryResolver(
        workRoot: Directory('${root.path}/work'),
        registryDirectory: state,
      )),
      applicationStateDirectory: state,
    );
    final release = Completer<void>();
    var running = 0;
    var peak = 0;
    Future<void> run(String thread, int token) =>
        coordinator.withMutation<void>(
          spaceId: 'space-a',
          threadId: thread,
          spaceName: 'Plan',
          leaseId: 'lease-$thread',
          fencingToken: token,
          action: (_) async {
            running++;
            if (running > peak) peak = running;
            await release.future;
            running--;
          },
        );

    final a = run('thread-a', 1);
    final b = run('thread-b', 1);
    final c = run('thread-c', 1);
    final aAgain = run('thread-a', 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(running, 3);
    release.complete();
    await Future.wait([a, b, c, aAgain]);
    expect(peak, 3);
  });

  test('reset clears Thread fences so a restarted lease counter is accepted',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final state = Directory('${root.path}/state');
    final coordinator = SpaceMutationCoordinator(
      lifecycle: SpaceDirectoryLifecycle(SpaceDirectoryResolver(
        workRoot: Directory('${root.path}/work'),
        registryDirectory: state,
      )),
      applicationStateDirectory: state,
    );
    Future<void> run(int token, String lease) => coordinator.withMutation<void>(
          spaceId: 'space-a',
          threadId: 'thread-a',
          spaceName: 'Plan',
          leaseId: lease,
          fencingToken: token,
          action: (_) async {},
        );

    await run(5, 'lease-old');
    await expectLater(
        run(1, 'lease-new'), throwsA(isA<SpaceMutationViolation>()));

    await coordinator.reset();
    await run(1, 'lease-new');
    expect(Directory('${root.path}/work/Plan').existsSync(), isTrue);
  });

  test('asks before taking a registered folder claimed by another Space',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-space-');
    addTearDown(() => root.delete(recursive: true));
    final work = Directory('${root.path}/work');
    final resolver = SpaceDirectoryResolver(
      workRoot: work,
      registryDirectory: Directory('${root.path}/state'),
    );
    final folder =
        await resolver.resolve(spaceId: 'space-a', spaceName: 'Plan');
    File('${folder.path}/notes.txt').writeAsStringSync('keep');
    // Another environment sharing the work root claims the folder.
    File('${folder.path}/.conclave-space.json').writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'spaceId': 'space-b'}),
    );

    await expectLater(
      resolver.resolve(spaceId: 'space-a', spaceName: 'Plan'),
      throwsA(
        isA<SpaceFolderExistsException>()
            .having((e) => e.ownedByAnotherSpace, 'ownedByAnotherSpace', true),
      ),
    );
    expect(File('${folder.path}/notes.txt').readAsStringSync(), 'keep');

    final adopted = await resolver.resolve(
      spaceId: 'space-a',
      spaceName: 'Plan',
      adoptExistingFolder: true,
    );
    expect(adopted.path, folder.path);
    expect(File('${folder.path}/notes.txt').readAsStringSync(), 'keep');
    final marker = jsonDecode(
      File('${folder.path}/.conclave-space.json').readAsStringSync(),
    ) as Map;
    expect(marker['spaceId'], 'space-a');
  });
}

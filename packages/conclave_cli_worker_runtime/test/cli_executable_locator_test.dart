import 'dart:io';

import 'package:conclave_cli_worker_runtime/src/cli_executable_locator.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  const locator = CliExecutableLocator();

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('conclave-cli-locator-');
  });

  tearDown(() async => temporary.delete(recursive: true));

  Future<String> addExecutable(String directory, String name) async {
    final root = Directory(directory);
    await root.create(recursive: true);
    final executableName =
        Platform.isWindows && !name.toLowerCase().endsWith('.exe')
        ? '$name.exe'
        : name;
    final path = '${root.path}${Platform.pathSeparator}$executableName';
    if (Platform.isWindows) {
      await File(Platform.resolvedExecutable).copy(path);
    } else {
      await Link(path).create(Platform.resolvedExecutable);
    }
    return path;
  }

  test('finds Profile-declared agy location with a sparse GUI PATH', () async {
    final home = '${temporary.path}${Platform.pathSeparator}home';
    final location =
        '$home${Platform.pathSeparator}.gemini'
        '${Platform.pathSeparator}antigravity-cli${Platform.pathSeparator}bin';
    final expected = await addExecutable(location, 'agy');

    final found = await locator.locate(
      'agy',
      environment: {'HOME': home, 'PATH': ''},
      standardPaths: [location],
    );

    expect(found, File(expected).absolute.path);
  });

  test(
    'finds Codex from an Engine baseline path without Conclave variables',
    () async {
      final home = '${temporary.path}${Platform.pathSeparator}home';
      final location =
          '$home${Platform.pathSeparator}.volta'
          '${Platform.pathSeparator}bin';
      final expected = await addExecutable(location, 'codex');

      final found = await locator.locate(
        'codex',
        environment: {'HOME': home, 'PATH': '/gui/restricted/path'},
      );

      expect(found, File(expected).absolute.path);
    },
  );

  test(
    'persists a verified executable path and revalidates it on reuse',
    () async {
      final first = '${temporary.path}${Platform.pathSeparator}first';
      final second = '${temporary.path}${Platform.pathSeparator}second';
      final firstExpected = await addExecutable(first, 'codex');
      await addExecutable(second, 'codex');
      final cache = File('${temporary.path}${Platform.pathSeparator}path.json');

      final initiallyFound = await locator.locate(
        'codex',
        environment: const {'PATH': ''},
        standardPaths: [first, second],
        cacheFile: cache,
        cacheIdentity: 'chatgpt-codex:codex',
      );
      final cachedFound = await locator.locate(
        'codex',
        environment: const {'PATH': ''},
        standardPaths: [first, second],
        cacheFile: cache,
        cacheIdentity: 'chatgpt-codex:codex',
      );

      expect(initiallyFound, File(firstExpected).absolute.path);
      expect(cachedFound, File(firstExpected).absolute.path);
      if (await FileSystemEntity.type(firstExpected, followLinks: false) ==
          FileSystemEntityType.link) {
        await Link(firstExpected).delete();
      } else {
        await File(firstExpected).delete();
      }
      final afterRemoval = await locator.locate(
        'codex',
        environment: const {'PATH': ''},
        standardPaths: [first, second],
        cacheFile: cache,
        cacheIdentity: 'chatgpt-codex:codex',
      );
      expect(
        afterRemoval,
        endsWith(
          '${Platform.pathSeparator}second'
          '${Platform.pathSeparator}codex',
        ),
      );
    },
  );

  test(
    'rejects path-bearing executable names and ignores hostile PATH entries',
    () async {
      final workingDirectory = await Directory.current.createTemp(
        'locator-cwd-',
      );
      addTearDown(() async => workingDirectory.delete(recursive: true));
      await addExecutable(workingDirectory.path, 'codex');
      final previousDirectory = Directory.current;
      Directory.current = workingDirectory;
      try {
        expect(
          await locator.locate(
            '../codex',
            environment: {'PATH': workingDirectory.path},
          ),
          isNull,
        );
        expect(
          await locator.locate('codex', environment: const {'PATH': '.'}),
          isNull,
        );
      } finally {
        Directory.current = previousDirectory;
      }
    },
  );

  test(
    'a tampered cached path cannot add an unapproved search directory',
    () async {
      final outside = '${temporary.path}${Platform.pathSeparator}outside';
      final approved = '${temporary.path}${Platform.pathSeparator}approved';
      final executable = await addExecutable(outside, 'phase11-no-global-cli');
      await Directory(approved).create();
      final cache = File('${temporary.path}${Platform.pathSeparator}path.json');
      await cache.writeAsString(
        '{"schemaVersion":1,"identity":"chatgpt-codex:phase11-no-global-cli",'
        '"path":"$executable"}',
      );

      expect(
        await locator.locate(
          'phase11-no-global-cli',
          environment: const {'PATH': ''},
          standardPaths: [approved],
          cacheFile: cache,
          cacheIdentity: 'chatgpt-codex:phase11-no-global-cli',
        ),
        isNull,
      );
    },
  );
}

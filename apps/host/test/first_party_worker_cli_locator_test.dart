import 'dart:io';

import 'package:conclave_host/first_party_worker_adapter_descriptor.dart';
import 'package:conclave_host/first_party_worker_cli_locator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-cli-locator-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Directory> install(String relativePath) async {
    final directory = Directory('${root.path}/$relativePath');
    await directory.create(recursive: true);
    for (final descriptor in FirstPartyWorkerAdapterDescriptor.all) {
      final executable = descriptor.executableCandidates.single;
      final file = File('${directory.path}/$executable');
      await file.writeAsString('#!/bin/sh\necho "$executable 1.2.3"\n');
      final result = await Process.run('chmod', ['755', file.path]);
      expect(result.exitCode, 0);
    }
    return directory;
  }

  Future<void> verifyContext({
    required String name,
    required String path,
    required String home,
    required List<String>? knownDirectories,
    required Directory installDirectory,
  }) async {
    for (final descriptor in FirstPartyWorkerAdapterDescriptor.all) {
      final result = await FirstPartyWorkerCliExecutableLocator(
        environment: {'PATH': path, 'HOME': home},
        knownDirectories: knownDirectories,
      ).locate(descriptor);
      expect(result, isNotNull,
          reason: '$name could not find ${descriptor.productName}');
      expect(result!.path,
          '${installDirectory.path}/${descriptor.executableCandidates.single}');
      expect(result.path.startsWith('/'), isTrue);
      expect(result.versionProbe.satisfied, isTrue);
      expect(result.versionProbe.detectedVersion, '1.2.3');
    }
  }

  test('Terminal launch resolves both CLIs from its inherited PATH', () async {
    if (Platform.isWindows) return;
    final terminal = await install('terminal/bin');
    await verifyContext(
      name: 'Terminal launch',
      path: terminal.path,
      home: '${root.path}/home',
      knownDirectories: const [],
      installDirectory: terminal,
    );
  });

  test('Finder launch resolves both CLIs from known install locations',
      () async {
    if (Platform.isWindows) return;
    final finder = await install('finder/install');
    await verifyContext(
      name: 'Finder launch',
      path: '/usr/bin:/bin',
      home: '${root.path}/home',
      knownDirectories: [finder.path],
      installDirectory: finder,
    );
  });

  test('login-item launch finds both CLIs with a minimal PATH', () async {
    if (Platform.isWindows) return;
    final home = Directory('${root.path}/login-home');
    final userBin = await install('login-home/.local/bin');
    await verifyContext(
      name: 'login-item launch',
      path: '/usr/bin:/bin',
      home: home.path,
      knownDirectories: null,
      installDirectory: userBin,
    );
  });

  test('a validated cached path takes priority over PATH', () async {
    if (Platform.isWindows) return;
    final cached = await install('cached/bin');
    final onPath = await install('path/bin');
    final descriptor = FirstPartyWorkerAdapterDescriptor.all.first;
    final result = await FirstPartyWorkerCliExecutableLocator(
      environment: {'PATH': onPath.path, 'HOME': root.path},
      knownDirectories: const [],
    ).locate(
      descriptor,
      cachedPath: '${cached.path}/${descriptor.executableCandidates.single}',
    );
    expect(result!.path,
        '${cached.path}/${descriptor.executableCandidates.single}');
  });
}

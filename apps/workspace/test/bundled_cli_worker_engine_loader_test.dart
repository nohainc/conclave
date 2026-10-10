import 'dart:io';

import 'package:conclave_workspace/bundled_cli_worker_engine_loader.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:test/test.dart';

void main() {
  test('materializes bundled Engine under a version and content digest',
      () async {
    final root = await Directory.systemTemp.createTemp('engine-bundle-test-');
    addTearDown(() => root.delete(recursive: true));
    final List<int> bytes = [1, 2, 3, 4, 5];

    final executable = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      assetLoader: (_) async => bytes,
    );

    expect(executable, isNotNull);
    expect(await executable!.readAsBytes(), bytes);
    expect(executable.path, contains('$cliWorkerEngineVersion-'));
    expect(executable.path, startsWith(root.path));
    expect(executable.uri.pathSegments.last,
        Platform.isWindows ? 'conclave-agent.exe' : 'conclave-agent');
  });

  test('repairs altered cached Engine bytes from the bundled release',
      () async {
    final root = await Directory.systemTemp.createTemp('engine-repair-test-');
    addTearDown(() => root.delete(recursive: true));
    final List<int> bytes = [11, 22, 33, 44];
    Future<List<int>?> assetLoader(String _) async => bytes;

    final first = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      assetLoader: assetLoader,
    );
    expect(first, isNotNull);
    await first!.writeAsBytes([99]);

    final repaired = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      assetLoader: assetLoader,
    );

    expect(repaired?.path, first.path);
    expect(await repaired!.readAsBytes(), bytes);
  });

  test('fails closed when the Workspace release has no Engine asset', () async {
    final root = await Directory.systemTemp.createTemp('engine-missing-test-');
    addTearDown(() => root.delete(recursive: true));

    final executable = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      assetLoader: (_) async => null,
    );

    expect(executable, isNull);
    expect(await root.list(recursive: true).toList(), isEmpty);
  });
}

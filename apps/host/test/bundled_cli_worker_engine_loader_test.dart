import 'dart:io';
import 'dart:typed_data';

import 'package:conclave_host/bundled_cli_worker_engine_loader.dart';
import 'package:conclave_host/cli_worker_engine_supervisor.dart';
import 'package:flutter/services.dart';
import 'package:test/test.dart';

void main() {
  test('materializes bundled Engine under a version and content digest',
      () async {
    final root = await Directory.systemTemp.createTemp('engine-bundle-test-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

    final executable = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      bundle: _BytesAssetBundle(bytes),
    );

    expect(executable, isNotNull);
    expect(await executable!.readAsBytes(), bytes);
    expect(executable.path, contains('$cliWorkerEngineVersion-'));
    expect(executable.path, startsWith(root.path));
  });

  test('repairs altered cached Engine bytes from the bundled release',
      () async {
    final root = await Directory.systemTemp.createTemp('engine-repair-test-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = Uint8List.fromList([11, 22, 33, 44]);
    final bundle = _BytesAssetBundle(bytes);

    final first = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      bundle: bundle,
    );
    expect(first, isNotNull);
    await first!.writeAsBytes([99]);

    final repaired = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      bundle: bundle,
    );

    expect(repaired?.path, first.path);
    expect(await repaired!.readAsBytes(), bytes);
  });

  test('fails closed when the Workspace release has no Engine asset', () async {
    final root = await Directory.systemTemp.createTemp('engine-missing-test-');
    addTearDown(() => root.delete(recursive: true));

    final executable = await loadBundledCliWorkerEngine(
      enginesDirectory: root,
      bundle: _MissingAssetBundle(),
    );

    expect(executable, isNull);
    expect(await root.list(recursive: true).toList(), isEmpty);
  });
}

final class _BytesAssetBundle extends CachingAssetBundle {
  _BytesAssetBundle(this.bytes);

  final Uint8List bytes;

  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(bytes);
}

final class _MissingAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw StateError('missing');
}

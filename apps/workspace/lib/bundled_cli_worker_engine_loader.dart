import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'cli_worker_engine_supervisor.dart' show cliWorkerEngineVersion;
import 'platform_runtime.dart';

/// Materializes the app-bundled generic Engine as an isolated local program.
Future<File?> loadBundledCliWorkerEngine({
  required Directory enginesDirectory,
  AssetBundle? bundle,
  PlatformRuntime? platform,
}) async {
  final runtime = platform ?? currentPlatformRuntime;
  final assetName = Platform.isWindows
      ? 'assets/engines/conclave_cli_worker_engine.exe'
      : 'assets/engines/conclave_cli_worker_engine';
  final assets = bundle ?? rootBundle;
  try {
    final data = await assets.load(assetName);
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (bytes.isEmpty || bytes.length > 128 * 1024 * 1024) return null;
    final digest = sha256.convert(bytes).toString();
    final versionDirectory = Directory(
      '${enginesDirectory.path}${Platform.pathSeparator}cli_worker'
      '${Platform.pathSeparator}$cliWorkerEngineVersion-$digest',
    );
    await versionDirectory.create(recursive: true);
    await runtime.restrictPermissions(versionDirectory.path, directory: true);
    final executable = File(
      '${versionDirectory.path}${Platform.pathSeparator}'
      '${Platform.isWindows ? 'conclave_cli_worker_engine.exe' : 'conclave_cli_worker_engine'}',
    );
    var cacheMatchesBundle = false;
    if (await executable.exists()) {
      final existingDigest = await sha256.bind(executable.openRead()).first;
      cacheMatchesBundle = existingDigest.toString() == digest;
    }
    if (!cacheMatchesBundle) {
      await executable.writeAsBytes(bytes, flush: true);
    }
    await runtime.restrictPermissions(executable.path, directory: false);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['700', executable.path]);
      if (chmod.exitCode != 0) return null;
    }
    return executable;
  } on Object {
    return null;
  }
}

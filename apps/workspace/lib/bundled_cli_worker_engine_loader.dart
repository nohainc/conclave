import 'dart:io';

import 'package:crypto/crypto.dart';

import 'cli_worker_engine_supervisor.dart' show cliWorkerEngineVersion;
import 'platform_runtime.dart';

typedef WorkspaceEngineAssetLoader = Future<List<int>?> Function(String name);

/// Materializes the app-bundled generic Engine as an isolated local program.
Future<File?> loadBundledCliWorkerEngine({
  required Directory enginesDirectory,
  WorkspaceEngineAssetLoader? assetLoader,
  PlatformRuntime? platform,
}) async {
  final runtime = platform ?? currentPlatformRuntime;
  final engineName = Platform.isWindows
      ? 'assets/engines/conclave_cli_worker_engine.exe'
      : 'assets/engines/conclave_cli_worker_engine';
  try {
    final bytes = await (assetLoader ?? _loadDefaultEngineAsset)(engineName);
    if (bytes == null) return null;
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
      '${Platform.isWindows ? 'conclave-agent.exe' : 'conclave-agent'}',
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

Future<List<int>?> _loadDefaultEngineAsset(String assetName) async {
  final bundle = _defaultBundleDirectory();
  if (bundle == null) return null;
  final source = File(
    '${bundle.path}${Platform.pathSeparator}'
    '${assetName.replaceAll('/', Platform.pathSeparator)}',
  );
  if (!await source.exists()) return null;
  return source.readAsBytes();
}

Directory? _defaultBundleDirectory() {
  final configured = Platform.environment['CONCLAVE_WORKSPACE_BUNDLE_DIR'];
  if (configured != null && configured.trim().isNotEmpty) {
    return Directory(configured);
  }
  final executable = File(Platform.resolvedExecutable).absolute;
  final candidates = <Directory>[
    Directory.current,
    executable.parent,
    executable.parent.parent,
    Directory(
      '${executable.parent.parent.path}${Platform.pathSeparator}'
      'Frameworks${Platform.pathSeparator}App.framework${Platform.pathSeparator}'
      'Resources${Platform.pathSeparator}flutter_assets',
    ),
  ];
  for (final directory in candidates) {
    if (File(
      '${directory.path}${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}engines${Platform.pathSeparator}'
      'conclave_cli_worker_engine${Platform.isWindows ? '.exe' : ''}',
    ).existsSync()) {
      return directory;
    }
  }
  return null;
}

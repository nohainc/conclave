import 'dart:async';
import 'dart:io';

import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/workspace_paths.dart';
import 'package:test/test.dart';

class _FakeMacRuntime implements PlatformRuntime {
  _FakeMacRuntime(this.homeDirectory);

  @override
  final String homeDirectory;

  @override
  String get operatingSystem => 'macos';

  @override
  bool get isWindows => false;

  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {}

  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [];

  @override
  Future<Process> startIsolatedProcess(
          String executable, List<String> arguments,
          {String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true}) async =>
      throw UnimplementedError();

  @override
  Future<void> terminateProcessTree(Process process,
          {required bool force}) async =>
      throw UnimplementedError();
}

void main() {
  test('macOS defaults group Workspace state, work, adapters, updates and logs',
      () async {
    final home = await Directory.systemTemp.createTemp('workspace-paths-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final state = WorkspacePaths.defaultStateDirectory(platform: runtime);
    final paths = WorkspacePaths(state, platform: runtime);

    expect(state.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/State');
    expect(paths.adaptersDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/Adapters');
    expect(paths.profilesDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/Profiles');
    expect(paths.updatesDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/Updates');
    expect(paths.logsFile.path,
        '${home.path}/Library/Logs/Conclave Workspace/host.log');
  });

  test('legacy macOS state and default Work Root migrate without data loss',
      () async {
    final home = await Directory.systemTemp.createTemp('workspace-migrate-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final oldState = WorkspacePaths.legacyMacStateDirectory(platform: runtime);
    final oldConfig = File('${oldState.path}/host-config.json');
    await oldConfig.create(recursive: true);
    oldConfig.writeAsStringSync('{"workspaceId":"workspace-1"}');
    await File('${oldState.path}/installation-id')
        .writeAsString('install-stable');
    final adapterManifest =
        File('${oldState.path}/v7-adapters/pkg/adapter.json');
    await adapterManifest.create(recursive: true);
    adapterManifest.writeAsStringSync('{"version":"1.0.0"}');
    final stagedRelease = File('${oldState.path}/updates/staged/release.zip');
    await stagedRelease.create(recursive: true);
    stagedRelease.writeAsStringSync('release');
    final oldLog = File('${oldState.path}/logs/host.log');
    await oldLog.create(recursive: true);
    oldLog.writeAsStringSync('previous log');
    final oldWork =
        Directory('${home.path}/Library/Application Support/Conclave/Work');
    final oldWorkFile = File('${oldWork.path}/workstream/state.txt');
    await oldWorkFile.create(recursive: true);
    oldWorkFile.writeAsStringSync('preserve work');

    await WorkspacePaths.migrateLegacyMacLayout(platform: runtime);

    final paths = WorkspacePaths(
      WorkspacePaths.defaultStateDirectory(platform: runtime),
      platform: runtime,
    );
    expect(
        File('${paths.stateDirectory.path}/host-config.json')
            .readAsStringSync(),
        contains('workspace-1'));
    expect(
        File('${paths.stateDirectory.path}/installation-id').readAsStringSync(),
        'install-stable');
    expect(
        File('${paths.adaptersDirectory.path}/pkg/adapter.json')
            .readAsStringSync(),
        contains('1.0.0'));
    expect(
        File('${paths.updatesDirectory.path}/staged/release.zip')
            .readAsStringSync(),
        'release');
    expect(paths.logsFile.readAsStringSync(), 'previous log');
    expect(
        File('${paths.applicationSupportDirectory.path}/Work/workstream/state.txt')
            .readAsStringSync(),
        'preserve work');
    expect(
        File('${paths.stateDirectory.path}/.legacy-layout-migrated-v1')
            .existsSync(),
        isTrue);
    // Migration is idempotent and doesn't replace newer state.
    await File('${paths.stateDirectory.path}/installation-id')
        .writeAsString('newer-install-id');
    await WorkspacePaths.migrateLegacyMacLayout(platform: runtime);
    expect(
        File('${paths.stateDirectory.path}/installation-id').readAsStringSync(),
        'newer-install-id');
  });

  test('local directories are created and write checked before Cloud startup',
      () async {
    final home = await Directory.systemTemp.createTemp('workspace-preflight-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final paths = WorkspacePaths(
      WorkspacePaths.defaultStateDirectory(platform: runtime),
      platform: runtime,
    );

    await paths.prepareRuntimeDirectories();

    for (final directory in [
      paths.applicationSupportDirectory,
      paths.stateDirectory,
      paths.adaptersDirectory,
      paths.profilesDirectory,
      paths.updatesDirectory,
      paths.logsDirectory,
    ]) {
      expect(await directory.exists(), isTrue);
      expect(
          directory
              .listSync()
              .where((entry) => entry.path.contains('.write-check-')),
          isEmpty);
    }
  });
}

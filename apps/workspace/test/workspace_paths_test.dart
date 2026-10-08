import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/platform_runtime.dart';
import 'package:conclave_workspace/workspace_paths.dart';
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
  test('macOS defaults group Workspace state, work, updates and logs',
      () async {
    final home = await Directory.systemTemp.createTemp('workspace-paths-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final state = WorkspacePaths.defaultStateDirectory(platform: runtime);
    final paths = WorkspacePaths(state, platform: runtime);

    expect(state.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/State');
    expect(paths.profilesDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/Profiles');
    expect(paths.updatesDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/Updates');
    expect(paths.logsFile.path,
        '${home.path}/Library/Logs/Conclave Workspace/workspace.log');
  });

  test('existing macOS Work Root is preserved at the Workspace location',
      () async {
    final home = await Directory.systemTemp.createTemp('workspace-work-root-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final oldWork =
        Directory('${home.path}/Library/Application Support/Conclave/Work');
    final oldWorkFile = File('${oldWork.path}/thread/state.txt');
    await oldWorkFile.create(recursive: true);
    oldWorkFile.writeAsStringSync('preserve work');

    await WorkspacePaths.preserveMacWorkRoot(platform: runtime);

    final target = File(
      '${home.path}/Library/Application Support/Conclave/Workspace/Work/thread/state.txt',
    );
    expect(target.readAsStringSync(), 'preserve work');
    expect(oldWork.existsSync(), isFalse);
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

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
  test('macOS defaults keep application data under the family root', () async {
    final home = await Directory.systemTemp.createTemp('workspace-paths-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final state = WorkspacePaths.defaultStateDirectory(platform: runtime);
    final paths = WorkspacePaths(state, platform: runtime);

    expect(state.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/State');
    expect(paths.applicationDataRoot.path,
        '${home.path}/Library/Application Support/Conclave');
    expect(paths.applicationSupportDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace');
    expect(paths.profilesDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/Profiles');
    expect(paths.updatesDirectory.path,
        '${home.path}/Library/Application Support/Conclave/Workspace/Updates');
    expect(paths.logsFile.path,
        '${home.path}/Library/Logs/Conclave Workspace/workspace.log');
    expect(
        () => paths.validateWorkRootSeparation(
              Directory('${home.path}/Documents/Conclave'),
            ),
        returnsNormally);
  });

  test('rejects an Application Data Root nested in the Work Root', () async {
    final home = await Directory.systemTemp.createTemp('workspace-separation-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final paths = WorkspacePaths(
      Directory('${home.path}/Documents/Conclave/.runtime'),
      platform: runtime,
    );

    expect(
      () => paths.validateWorkRootSeparation(
        Directory('${home.path}/Documents/Conclave'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('legacy macOS Work Root moves to the user Documents root', () async {
    final home = await Directory.systemTemp.createTemp('workspace-work-root-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final oldWork = Directory(
        '${home.path}/Library/Application Support/Conclave/Workspace/Work');
    final oldWorkFile = File('${oldWork.path}/thread/state.txt');
    await oldWorkFile.create(recursive: true);
    oldWorkFile.writeAsStringSync('preserve work');

    await WorkspacePaths.preserveMacWorkRoot(platform: runtime);

    final target = File(
      '${home.path}/Documents/Conclave/thread/state.txt',
    );
    expect(target.readAsStringSync(), 'preserve work');
    expect(oldWork.existsSync(), isFalse);
  });

  test('custom Work Root prevents legacy default migration', () async {
    final home =
        await Directory.systemTemp.createTemp('workspace-custom-root-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final oldWork = Directory(
        '${home.path}/Library/Application Support/Conclave/Workspace/Work');
    await File('${oldWork.path}/existing.txt').create(recursive: true);
    await WorkspacePaths.preserveMacWorkRoot(
      platform: runtime,
      configuredWorkRoot: '${home.path}/Custom Work',
    );

    expect(oldWork.existsSync(), isTrue);
    expect(Directory('${home.path}/Documents/Conclave').existsSync(), isFalse);
  });

  test('migration conflict preserves both Work Roots', () async {
    final home = await Directory.systemTemp.createTemp('workspace-conflict-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final oldWork = Directory(
        '${home.path}/Library/Application Support/Conclave/Workspace/Work');
    final target = Directory('${home.path}/Documents/Conclave');
    await File('${oldWork.path}/old.txt').create(recursive: true);
    await File('${target.path}/new.txt').create(recursive: true);

    await WorkspacePaths.preserveMacWorkRoot(platform: runtime);

    expect(File('${oldWork.path}/old.txt').existsSync(), isTrue);
    expect(File('${target.path}/new.txt').existsSync(), isTrue);
  });

  test('a malformed legacy path is preserved for recovery', () async {
    final home = await Directory.systemTemp.createTemp('workspace-recovery-');
    addTearDown(() => home.delete(recursive: true));
    final runtime = _FakeMacRuntime(home.path);
    final oldWork = File(
        '${home.path}/Library/Application Support/Conclave/Workspace/Work');
    await oldWork.create(recursive: true);

    await WorkspacePaths.preserveMacWorkRoot(platform: runtime);

    expect(oldWork.existsSync(), isTrue);
    expect(Directory('${home.path}/Documents/Conclave').existsSync(), isFalse);
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

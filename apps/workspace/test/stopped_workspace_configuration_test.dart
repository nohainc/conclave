import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/stopped_workspace_configuration.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory state;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('stopped-work-root-');
    state = Directory('${root.path}/state');
  });
  tearDown(() => root.delete(recursive: true));

  test(
      'saves locally before startup, validates access and preserves user files',
      () async {
    final old = Directory('${root.path}/old');
    await old.create();
    final userFile = File('${old.path}/project.txt');
    await userFile.writeAsString('keep');
    final store = WorkspaceLifecyclePreferencesStore(state);
    await store.write(store.readSync().copyWith(workRootPath: old.path));
    final selected = await StoppedWorkspaceConfiguration(state)
        .setWorkRoot('${root.path}/new');
    expect(await Directory(selected).exists(), isTrue);
    expect(store.readSync().workRootPath, selected);
    expect(WorkspaceConfig.fromArgs(['--data-dir', state.path]).workRootPath,
        selected);
    expect(await userFile.readAsString(), 'keep');
  });

  test('invalid/internal paths leave the previous selection unchanged',
      () async {
    final editor = StoppedWorkspaceConfiguration(state);
    final selected = await editor.setWorkRoot('${root.path}/work');
    await expectLater(editor.setWorkRoot(' '), throwsA(isA<Exception>()));
    await expectLater(editor.setWorkRoot('${state.path}/internal'),
        throwsA(isA<StateError>()));
    final file = File('${root.path}/file');
    await file.writeAsString('data');
    await expectLater(editor.setWorkRoot(file.path), throwsA(isA<Exception>()));
    expect(WorkspaceLifecyclePreferencesStore(state).readSync().workRootPath,
        selected);
  });

  test('an independently running owner prevents configuration changes',
      () async {
    if (Platform.isWindows) return;
    await state.create();
    final lock =
        WorkspacePaths(state).installationLockFile('installation-test');
    final owner = await Process.start('python3', [
      '-u',
      '-c',
      'import fcntl,sys\nf=open(sys.argv[1],"a")\n'
          'fcntl.lockf(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\n'
          'sys.stdin.read()\n',
      lock.path,
    ]);
    addTearDown(() async {
      await owner.stdin.close();
      await owner.exitCode;
    });
    expect(
        await owner.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'locked');
    await expectLater(
        StoppedWorkspaceConfiguration(state,
                installationId: 'installation-test')
            .setWorkRoot('${root.path}/work'),
        throwsA(isA<StateError>()));
    expect(WorkspaceLifecyclePreferencesStore(state).readSync().workRootPath,
        isNull);
  });
}

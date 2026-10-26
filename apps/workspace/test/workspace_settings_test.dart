import 'dart:io';

import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_settings.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace-settings-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  WorkspaceSettings settings({int slots = 6}) => WorkspaceSettings(
    serviceEnabled: true,
    cloudUrl: 'https://app.conclaveax.com',
    connectOnStart: true,
    workspaceName: 'GMKtec',
    parallelSlots: slots,
    folders: {
      'root': root.path,
      'conclave': '${root.path}/conclave',
      'state': '${root.path}/state',
      'work': '${root.path}/work',
      'models': '${root.path}/models',
    },
  );

  test('round-trips strict Nano Markup configuration atomically', () async {
    final store = WorkspaceSettingsStore(Directory('${root.path}/state'));
    await store.write(settings());

    final source = await store.file.readAsString();
    expect(source, startsWith('..\n'));
    expect(source, contains('parallel_slots 6'));
    expect(source, contains('models ${root.path}/models'));
    final loaded = store.readSync()!;
    expect(loaded.workspaceName, 'GMKtec');
    expect(loaded.parallelSlots, 6);
    expect(loaded.folders['work'], '${root.path}/work');
    if (!Platform.isWindows) {
      expect(store.file.statSync().mode & 0x1ff, 0x180);
    }
  });

  test('rejects invalid scalar types, paths and unknown behavior keys', () {
    final valid = settings().toNanoValue();
    expect(
      () => WorkspaceSettings.fromNanoValue({
        ...valid,
        'execution': {'parallel_slots': '11'},
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceSettings.fromNanoValue({
        ...valid,
        'folders': {
          ...(valid['folders']! as Map<String, Object>),
          'work': 'relative/work',
        },
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceSettings.fromNanoValue({
        ...valid,
        'service': {'enabled': 'true', 'mystery': 'value'},
      }),
      throwsFormatException,
    );
  });

  test(
    'resolver consumes workspace.nano once as service configuration',
    () async {
      final state = Directory('${root.path}/state');
      await WorkspaceSettingsStore(state).write(settings(slots: 7));

      final config = WorkspaceConfig.fromArgs(['--data-dir', state.path]);
      expect(config.serviceEnabled, isTrue);
      expect(config.connectOnStart, isTrue);
      expect(config.parallelSlots, 7);
      expect(config.workRootPath, '${root.path}/work');
      expect(config.folders['models'], '${root.path}/models');
      expect(config.cloudUri!.scheme, 'wss');
    },
  );

  test(
    'initialization creates platform defaults without legacy state',
    () async {
      final state = Directory('${root.path}/state');
      final store = WorkspaceSettingsStore(state);
      final generated = await store.ensureDefaults();

      expect(generated.cloudUrl, 'https://app.conclaveax.com');
      expect(generated.workspaceName, 'Workspace');
      expect(generated.connectOnStart, isFalse);
      expect(
        generated.folders.keys,
        containsAll(['root', 'conclave', 'state', 'work']),
      );
      expect(store.file.existsSync(), isTrue);
    },
  );
}

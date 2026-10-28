import 'dart:io';

import 'package:syntila_workspace/linux_credentials.dart';
import 'package:syntila_workspace/linux_service_manager.dart';
import 'package:syntila_workspace/secure_credentials.dart';
import 'package:syntila_workspace/sleep_inhibitor.dart';
import 'package:syntila_workspace/workspace_lifecycle_store.dart';
import 'package:syntila_workspace/workspace_paths.dart';
import 'package:test/test.dart';

void main() {
  final posix = !Platform.isWindows;
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('syntila-linux-'));
  tearDown(() => root.deleteSync(recursive: true));

  group('XDG state root', () {
    test('uses XDG_STATE_HOME and ignores relative values', () {
      expect(
        WorkspacePaths.linuxXdgStateDirectory(
          homeDirectory: '/home/u',
          xdgStateHome: '/var/state',
        ).path,
        '/var/state/syntila/workspace',
      );
      expect(
        WorkspacePaths.linuxXdgStateDirectory(
          homeDirectory: '/home/u',
          xdgStateHome: 'relative',
        ).path,
        '/home/u/.local/state/syntila/workspace',
      );
    });

    test('an existing legacy root keeps its authority in place', () {
      final legacy = Directory('${root.path}/.syntila');
      final target = Directory('${root.path}/state/syntila/workspace');
      expect(
        WorkspacePaths.resolveLinuxStateDirectory(
          legacy: legacy,
          target: target,
        ).path,
        target.path,
      );
      legacy.createSync();
      expect(
        WorkspacePaths.resolveLinuxStateDirectory(
          legacy: legacy,
          target: target,
        ).path,
        legacy.path,
      );
      expect(target.existsSync(), isFalse);
    });
  });

  group('credential store', () {
    test(
      'selection requires a real Secret Service as well as a session bus',
      () {
        final state = Directory('${root.path}/state');
        expect(
          LinuxCredentialStoreSelector(
            state,
            environment: const {},
          ).preferred(),
          LinuxCredentialStoreKind.file,
        );
        expect(
          LinuxCredentialStoreSelector(
            state,
            secretServiceAvailable: () => true,
            environment: const {
              'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
            },
          ).preferred(),
          LinuxCredentialStoreKind.secretService,
        );
        expect(
          LinuxCredentialStoreSelector(
            state,
            secretServiceAvailable: () => false,
            environment: const {'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/bus'},
          ).preferred(),
          LinuxCredentialStoreKind.file,
        );
        expect(
          LinuxCredentialStoreSelector(
            state,
            environment: const {
              'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
              'SYNTILA_WORKSPACE_SECRET_STORE': 'file',
            },
          ).preferred(),
          LinuxCredentialStoreKind.file,
        );
      },
    );

    test('the first write records the store for later readers', () {
      final state = Directory('${root.path}/state');
      final headless = LinuxCredentialStoreSelector(
        state,
        environment: const {},
      );
      expect(headless.selectForWrite(), LinuxCredentialStoreKind.file);
      final desktop = LinuxCredentialStoreSelector(
        state,
        environment: const {'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/bus'},
      );
      expect(desktop.effective(), LinuxCredentialStoreKind.file);
      expect(desktop.selectForWrite(), LinuxCredentialStoreKind.file);
    });

    test('file store is user-only and refuses broader permissions', () {
      final store = LinuxFileCredentials(Directory('${root.path}/Credentials'));
      store.write('svc', 'runtime-a', 'secret-a');
      expect(store.read('svc', 'runtime-a'), 'secret-a');
      expect(store.read('svc', 'runtime-b'), isNull);
      final file = store.directory.listSync().single as File;
      expect(file.statSync().mode & 0x1ff, 0x180); // 0600
      expect(store.directory.statSync().mode & 0x1ff, 0x1c0); // 0700
      Process.runSync('chmod', ['644', file.path]);
      expect(() => store.read('svc', 'runtime-a'), throwsStateError);
      store.delete('svc', 'runtime-a');
      expect(store.read('svc', 'runtime-a'), isNull);
    }, skip: !posix);

    test('platform store uses the recorded file store on Linux', () async {
      final store = PlatformSecureCredentialStore(
        service: 'com.syntila.workspace.test',
        platform: 'linux',
        credentialDirectory: Directory('${root.path}/state/Credentials'),
      );
      if (LinuxCredentialStoreSelector(
            Directory('${root.path}/state'),
          ).preferred() !=
          LinuxCredentialStoreKind.file) {
        File('${root.path}/state/credential-store')
          ..createSync(recursive: true)
          ..writeAsStringSync('file');
      }
      await store.write('runtime-linux-test', 'token');
      await store.verifyWritable();
      expect(store.credentialDirectory!.listSync(), hasLength(1));
      expect(store.readSync('runtime-linux-test'), 'token');
      await store.delete('runtime-linux-test');
      expect(store.readSync('runtime-linux-test'), isNull);
    }, skip: !posix);
  });

  group('systemd user unit', () {
    late List<List<String>> calls;
    late Map<String, String> show;
    late LinuxWorkspaceServiceManager manager;

    setUp(() {
      calls = [];
      show = {'ActiveState': 'inactive', 'UnitFileState': 'disabled'};
      final executable = File('${root.path}/app dir/workspace')
        ..createSync(recursive: true);
      manager = LinuxWorkspaceServiceManager(
        dataDirectory: Directory('${root.path}/state 100%'),
        executable: executable,
        unitDirectory: Directory('${root.path}/systemd/user'),
        systemctl: (args) async {
          calls.add(args);
          if (args.first == 'enable') show['UnitFileState'] = 'enabled';
          if (args.first == 'disable') show['UnitFileState'] = 'disabled';
          if (args.first == 'start' || args.first == 'restart') {
            show['ActiveState'] = 'active';
            show['MainPID'] = '4242';
          }
          if (args.first == 'stop') {
            show['ActiveState'] = 'inactive';
            show['MainPID'] = '0';
          }
          final stdout = args.first == 'show'
              ? show.entries.map((e) => '${e.key}=${e.value}').join('\n')
              : '';
          return ProcessResult(1, 0, stdout, '');
        },
      );
    });

    File unitFile() =>
        manager.unitDirectory.listSync().whereType<File>().single;

    test('quotes ExecStart words and escapes systemd specifiers', () {
      expect(
        LinuxWorkspaceServiceManager.quoteExecArgument(r'a "b" 5% $x\'),
        r'"a \"b\" 5%% $$x\\"',
      );
      expect(
        () => LinuxWorkspaceServiceManager.quoteExecArgument('a\nb'),
        throwsArgumentError,
      );
    });

    test('path directives escape percent without ExecStart quotes', () {
      final special = LinuxWorkspaceServiceManager(
        executable: File('${root.path}/app 100%/workspace'),
      );
      expect(special.workingDirectory(), '${root.path}/app 100%%');
      expect(
        special.unitContents(),
        contains('WorkingDirectory=${root.path}/app 100%%\n'),
      );
    });

    test('register, stop and unregister keep installation state', () async {
      final registered = await manager.register();
      expect(registered.registered, isTrue);
      final unit = unitFile();
      expect(unit.path, matches(RegExp(r'workspace-.+\.service$')));
      final contents = unit.readAsStringSync();
      expect(contents, contains('ExecStart=${manager.execStart()}'));
      expect(
        contents,
        contains('WorkingDirectory=${manager.executable.parent.absolute.path}'),
      );
      expect(contents, isNot(contains('WorkingDirectory="')));
      expect(contents, contains('state 100%%'));
      expect(contents, contains('KillMode=mixed'));
      expect(contents, contains('WantedBy=default.target'));

      final started = await manager.start();
      expect(started.processRunning, isTrue);
      expect(started.pid, 4242);

      // Stop Service must leave the registration intact.
      final stopped = await manager.stop();
      expect(stopped.processRunning, isFalse);
      expect(stopped.registered, isTrue);
      expect(unit.existsSync(), isTrue);

      await manager.unregister();
      expect(unit.existsSync(), isFalse);
      expect(manager.dataDirectory.existsSync(), isTrue);
      expect(
        calls.map((c) => c.first),
        containsAllInOrder(['daemon-reload', 'enable', 'start', 'stop']),
      );
      expect(
        calls.map((c) => c.first),
        containsAllInOrder(['disable', 'daemon-reload']),
      );
    });

    test('refuses to take over a unit that points elsewhere', () async {
      await manager.register();
      final unit = unitFile();
      unit.writeAsStringSync(
        unit.readAsStringSync().replaceFirst('/workspace', '/other-service'),
      );
      await expectLater(manager.register(), throwsStateError);
      await expectLater(manager.start(), throwsStateError);
      expect(unit.readAsStringSync(), contains('other-service'));
    });

    test('start requires registration', () async {
      await expectLater(manager.start(), throwsStateError);
    });
  });

  test('sleep inhibitor holds a logind lock on Linux', () async {
    final dir = Directory('${root.path}/prefs')..createSync();
    final store = WorkspaceLifecyclePreferencesStore(dir);
    List<String>? arguments;
    final inhibitor = SleepInhibitor(
      store,
      platformIsMacOS: false,
      platformIsLinux: true,
      pollInterval: const Duration(milliseconds: 50),
      start: (args) {
        arguments = args;
        return Process.start('sleep', ['30']);
      },
    );
    await inhibitor.begin();
    expect(inhibitor.isHeld, isTrue);
    expect(arguments, containsAll(['--what=sleep:idle', '--mode=block']));
    await inhibitor.close();
    expect(inhibitor.isHeld, isFalse);
  }, skip: !posix);
}

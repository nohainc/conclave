import 'dart:io';
import 'package:conclave_workspace/workspace_cli.dart';
import 'package:conclave_workspace/linux_service_manager.dart';
import 'package:test/test.dart';

void main() {
  Future<(int, String, String, List<String>)> run(List<String> args) async {
    final out = StringBuffer(), err = StringBuffer(), calls = <String>[];
    final code = await WorkspaceCli(
      out: out,
      err: err,
      request: (command, payload) async {
        calls.add('$command $payload');
        return {'ok': true};
      },
    ).run(args);
    return (code, out.toString(), err.toString(), calls);
  }

  test('maps commands to IPC requests', () async {
    expect((await run(['login'])).$4, ['auth.start {}']);
    expect((await run(['login', 'status'])).$4, ['auth.status {}']);
    expect((await run(['login', 'cancel'])).$4, ['auth.cancel {}']);
    expect((await run(['updates'])).$4, ['updates.status {}']);
    expect((await run(['status'])).$4, ['service.getStatus {}']);
    expect((await run(['workers', 'test', 'w1'])).$4,
        ['workers.testWorker {workerId: w1}']);
    expect((await run(['--json', 'assignments', 'cancel', 'a1'])).$4,
        ['execution.cancelAssignment {assignmentId: a1}']);
  });

  test('password login sends credentials only over IPC, never prints them',
      () async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await WorkspaceCli(
        out: out,
        err: err,
        readCredentials: () =>
            (email: 'user@example.test', password: 'private-password'),
        request: (command, payload) async {
          if (command == 'auth.start') {
            expect(payload,
                {'email': 'user@example.test', 'password': 'private-password'});
            return {'phase': 'pending'};
          }
          expect(command, 'auth.status');
          return {'phase': 'complete'};
        }).run(['login', '--password']);
    expect(code, 0);
    expect('$out$err', isNot(contains('private-password')));
    expect('$out$err', isNot(contains('user@example.test')));
  });

  test('service install uses the Linux host adapter and never calls Cloud',
      () async {
    final root = await Directory.systemTemp.createTemp('cli-host-');
    addTearDown(() => root.delete(recursive: true));
    final executable = File('${root.path}/conclave-service')
      ..writeAsStringSync('fixture');
    final systemctl = <List<String>>[];
    final code = await WorkspaceCli(
      out: StringBuffer(),
      err: StringBuffer(),
      request: (_, __) async => fail('install must not call IPC'),
      hostManager: (state) => LinuxWorkspaceServiceManager(
          dataDirectory: state,
          executable: executable,
          unitDirectory: Directory('${root.path}/units'),
          systemctl: (args) async {
            systemctl.add(args);
            return ProcessResult(
                0, 0, 'UnitFileState=enabled\nActiveState=inactive', '');
          }),
    ).run(['--data-dir', '${root.path}/state', 'service', 'install']);
    expect(code, 0);
    expect(systemctl[0], ['daemon-reload']);
    expect(systemctl[1].first, 'enable');
    expect(Directory('${root.path}/units').listSync(), hasLength(1));
  });

  test('headless setup reaches online with zero Workers', () async {
    final root = await Directory.systemTemp.createTemp('cli-setup-');
    addTearDown(() => root.delete(recursive: true));
    final executable = File('${root.path}/conclave-service')
      ..writeAsStringSync('fixture');
    final commands = <String>[];
    var registered = false;
    var connected = false;
    final out = StringBuffer(), err = StringBuffer();
    final code = await WorkspaceCli(
        out: out,
        err: err,
        readCredentials: () =>
            (email: 'user@example.test', password: 'private-password'),
        hostManager: (state) => LinuxWorkspaceServiceManager(
            dataDirectory: state,
            executable: executable,
            unitDirectory: Directory('${root.path}/units'),
            systemctl: (args) async => ProcessResult(0, 0,
                'UnitFileState=enabled\nActiveState=active\nMainPID=1', '')),
        request: (command, payload) async {
          commands.add(command);
          switch (command) {
            case 'service.getHealth':
              return {'healthy': true};
            case 'service.getStatus':
              return {
                'workspace': {
                  'workspaceId': registered ? 'existing-workspace' : null
                },
                'cloud': {'synchronized': connected},
                'workers': <Object>[]
              };
            case 'auth.start':
              registered = true;
              return {'phase': 'pending'};
            case 'auth.status':
              return {'phase': 'complete'};
            case 'connection.connect':
              connected = true;
              return {};
            default:
              fail('Setup must not touch Workers: $command');
          }
        }).run(['--data-dir', '${root.path}/state', 'setup']);
    expect(code, 0);
    expect(
        commands,
        containsAllInOrder([
          'service.getHealth',
          'auth.start',
          'auth.status',
          'connection.connect',
          'service.getStatus'
        ]));
    expect(out.toString(), contains('Workspace is online'));
    expect('$out$err', isNot(contains('private-password')));
  });

  test('rejects excess arguments', () async {
    for (final args in [
      ['status', 'extra'],
      ['workers', 'test', 'w', 'extra'],
      ['login', 'status', 'extra']
    ]) {
      expect((await run(args)).$1, 64);
    }
  });

  test('rejects unknown commands with usage', () async {
    final result = await run(['bogus']);
    expect(result.$1, 64);
    expect(result.$3, contains('Usage:'));
    expect(result.$4, isEmpty);
  });
}

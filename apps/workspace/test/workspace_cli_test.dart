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
    expect((await run(['status'])).$4, ['service.getStatus {}']);
    expect((await run(['workers', 'test', 'w1'])).$4,
        ['workers.testWorker {workerId: w1}']);
    expect((await run(['--json', 'assignments', 'cancel', 'a1'])).$4,
        ['execution.cancelAssignment {assignmentId: a1}']);
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

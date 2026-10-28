import 'dart:io';
import 'package:syntila_cli_worker_runtime/src/cli_command_runner.dart';
import 'package:test/test.dart';

void main() {
  test('returns bounded stdout and exit status', () async {
    if (Platform.isWindows) return;
    final result = await const CliCommandRunner(maxOutputBytes: 32).run(
      '/bin/sh',
      ['-c', 'printf models'],
      environment: {},
      workingDirectory: Directory.current.path,
    );
    expect(result.exitCode, 0);
    expect(result.stdout, 'models');
    await expectLater(
      const CliCommandRunner(maxOutputBytes: 2).run(
        '/bin/sh',
        ['-c', 'printf overflow'],
        environment: {},
        workingDirectory: Directory.current.path,
      ),
      throwsFormatException,
    );
  });
  test('discovery deadline cleans up provider child processes', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('probe-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final child = File('${root.path}/child');
    await expectLater(
      const CliCommandRunner().run(
        '/bin/sh',
        ['-c', 'sleep 30 & printf "%s" "\$!" > "${child.path}"; wait'],
        environment: {},
        workingDirectory: root.path,
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<Object>()),
    );
    final pid = int.parse(await child.readAsString());
    // Process signal 0 is not exposed by Dart; inspect this specific recorded PID.
    final result = await Process.run('ps', ['-p', '$pid', '-o', 'stat=']);
    expect(result.stdout.toString().trim(), anyOf(isEmpty, startsWith('Z')));
  });
}

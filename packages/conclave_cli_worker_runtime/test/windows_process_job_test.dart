import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'Windows job kills descendants when the owner is forcibly terminated',
    () async {
      final owner = await Process.start(Platform.resolvedExecutable, [
        '--packages=.dart_tool/package_config.json',
        'test/fixtures/windows_job_owner.dart',
      ]);
      final errors = owner.stderr.transform(utf8.decoder).join();
      final first = await owner.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final childPid = int.parse(first);
      try {
        owner.kill(ProcessSignal.sigkill);
        await owner.exitCode.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final processes = await Process.run('tasklist.exe', [
          '/FI',
          'PID eq $childPid',
          '/FO',
          'CSV',
          '/NH',
        ]);
        expect(processes.exitCode, 0, reason: processes.stderr.toString());
        expect(processes.stdout.toString(), isNot(contains('"$childPid"')));
        expect(await errors, isEmpty);
      } finally {
        owner.kill(ProcessSignal.sigkill);
        await Process.run('taskkill.exe', ['/PID', '$childPid', '/F']);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 35)),
  );
}

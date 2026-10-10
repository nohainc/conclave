import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('native job status ignores nested states and excludes environment',
      () async {
    if (!Platform.isMacOS) {
      markTestSkipped('Native Swift parser runs on macOS.');
      return;
    }
    final root = await Directory.systemTemp.createTemp('launchd-status-test-');
    addTearDown(() => root.delete(recursive: true));
    final main = File('${root.path}/main.swift');
    await main.writeAsString(r'''
import Foundation
precondition(workspaceServiceHasTrustedSignature(URL(fileURLWithPath: "/bin/echo")))
precondition(!workspaceServiceHasTrustedSignature(URL(fileURLWithPath: CommandLine.arguments[0])))
precondition(!workspaceServiceHasTrustedSignature(URL(fileURLWithPath: "/nonexistent/conclave-service")))
for state in ["running", "not running"] {
  let fixture = """
  gui/501/service = {
    state = \(state)
    last exit code = 7
    environment = {
      TOKEN = secret
    }
    last exit reason = OS_REASON_CODESIGNING
    pid = 42831
    resource coalition = {
      state = active
    }
    jetsam coalition = {
      state = active
    }
  }
  """
  let status = parseWorkspaceLaunchdStatus(fixture)
  precondition(status["launchdState"] as? String == state)
  precondition(status["lastExitCode"] as? Int == 7)
  precondition(status["lastExitReason"] as? String == "OS_REASON_CODESIGNING")
  precondition(status["pid"] as? Int == 42831)
  precondition(status.count == 4)
}
let unknown = parseWorkspaceLaunchdStatus("unrecognized job output")
precondition(unknown["launchdState"] as? String == "unknown")
precondition(unknown["lastExitCode"] == nil)
precondition(unknown["lastExitReason"] == nil)
''');
    final executable = '${root.path}/launchd-status-test';
    final build = await Process.run('xcrun', [
      'swiftc',
      File('macos/Runner/WorkspaceLaunchdStatus.swift').absolute.path,
      main.path,
      '-o',
      executable,
    ]);
    expect(build.exitCode, 0, reason: '${build.stderr}');
    final run = await Process.run(executable, []);
    expect(run.exitCode, 0, reason: '${run.stderr}');
  });
}

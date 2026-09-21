import 'dart:io';

Future<Process> startIsolatedProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  if (Platform.isWindows) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  }

  try {
    return await Process.start(
      'setsid',
      [executable, ...arguments],
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  } on ProcessException {
    // Some minimal environments do not ship setsid. Keep direct-child
    // termination as a safe compatibility fallback there.
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  }
}

Future<void> terminateProcessTree(
  Process process, {
  required bool force,
}) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', [
      '/PID',
      '${process.pid}',
      '/T',
      if (force) '/F',
    ]);
    return;
  }

  final signal = force ? '-KILL' : '-TERM';
  final result = await Process.run('kill', [signal, '-${process.pid}']);
  if (result.exitCode != 0) {
    process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
  }
}

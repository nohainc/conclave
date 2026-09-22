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
    try {
      final result = await Process.run('taskkill', [
        '/PID',
        '${process.pid}',
        '/T',
        if (force) '/F',
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) return;
    } on Object {
      // Fall back to the Dart handle when taskkill is unavailable or times
      // out. This still terminates the direct child safely.
    }
    process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
    return;
  }

  final signal = force ? '-KILL' : '-TERM';
  final dartSignal = force ? ProcessSignal.sigkill : ProcessSignal.sigterm;
  try {
    await Process.run('kill', [signal, '-${process.pid}'])
        .timeout(const Duration(seconds: 5));
  } on Object {
    // Continue with direct-child termination below. Group signalling is
    // best-effort because minimal environments may not provide kill/setsid.
  }

  // Always signal the direct Dart process handle as well. A successful
  // process-group signal can terminate descendants while leaving Dart's
  // Process handle waiting indefinitely on some CI/container platforms.
  process.kill(dartSignal);
}

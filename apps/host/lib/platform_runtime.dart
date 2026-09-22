import 'dart:async';
import 'dart:io';

/// Operating-system services used by the Host.
///
/// Protocol, repository, and worker code should depend on this seam instead
/// of branching on the host operating system themselves.
abstract interface class PlatformRuntime {
  String get operatingSystem;
  bool get isWindows;
  String get homeDirectory;

  Future<void> restrictPermissions(String path, {required bool directory});
  List<StreamSubscription<ProcessSignal>> watchTermination(
    void Function() onTermination,
  );
  Future<Process> startIsolatedProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
  Future<void> terminateProcessTree(Process process, {required bool force});
}

PlatformRuntime get currentPlatformRuntime => _platformRuntime;
final PlatformRuntime _platformRuntime =
    Platform.isWindows ? WindowsRuntime() : PosixRuntime();

final class PosixRuntime implements PlatformRuntime {
  @override
  String get operatingSystem => Platform.operatingSystem;
  @override
  bool get isWindows => false;
  @override
  String get homeDirectory =>
      Platform.environment['HOME'] ?? Directory.current.path;

  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {
    final result =
        await Process.run('chmod', [directory ? '700' : '600', path]);
    if (result.exitCode != 0) {
      throw StateError('failed to restrict permissions for $path');
    }
  }

  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [
        ProcessSignal.sigint.watch().listen((_) => onTermination()),
        ProcessSignal.sigterm.watch().listen((_) => onTermination()),
      ];

  @override
  Future<Process> startIsolatedProcess(
      String executable, List<String> arguments,
      {String? workingDirectory, Map<String, String>? environment}) async {
    try {
      return await Process.start('setsid', [executable, ...arguments],
          workingDirectory: workingDirectory,
          environment: environment,
          runInShell: false);
    } on ProcessException {
      return Process.start(executable, arguments,
          workingDirectory: workingDirectory,
          environment: environment,
          runInShell: false);
    }
  }

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {
    final signal = force ? '-KILL' : '-TERM';
    final dartSignal = force ? ProcessSignal.sigkill : ProcessSignal.sigterm;
    try {
      await Process.run('kill', [signal, '-${process.pid}'])
          .timeout(const Duration(seconds: 5));
    } on Object {
      // Group signalling is best effort in minimal environments.
    }
    process.kill(dartSignal);
  }
}

final class WindowsRuntime implements PlatformRuntime {
  @override
  String get operatingSystem => 'windows';
  @override
  bool get isWindows => true;
  @override
  String get homeDirectory =>
      Platform.environment['USERPROFILE'] ?? Directory.current.path;
  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {}
  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [
        ProcessSignal.sigint.watch().listen((_) => onTermination()),
      ];
  @override
  Future<Process> startIsolatedProcess(
      String executable, List<String> arguments,
      {String? workingDirectory, Map<String, String>? environment}) {
    return Process.start(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false);
  }

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {
    try {
      final result = await Process.run(
              'taskkill', ['/PID', '${process.pid}', '/T', if (force) '/F'])
          .timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) return;
    } on Object {
      // Fall back to the Dart handle if taskkill is unavailable or times out.
    }
    process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
  }
}

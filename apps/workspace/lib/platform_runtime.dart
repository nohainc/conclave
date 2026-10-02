import 'dart:async';
import 'dart:io';

/// Operating-system services used by the Workspace.
///
/// Protocol, repository, and worker code should depend on this seam instead
/// of branching on the workspace operating system themselves.
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
    bool includeParentEnvironment = true,
  });
  Future<void> terminateProcessTree(Process process, {required bool force});
}

PlatformRuntime get currentPlatformRuntime => _platformRuntime;
final PlatformRuntime _platformRuntime =
    Platform.isWindows ? WindowsRuntime() : PosixRuntime();

final class PosixRuntime implements PlatformRuntime {
  final Map<int, Set<int>> _knownDescendants = {};
  final Set<int> _isolatedProcessGroups = {};

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
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true}) async {
    if (Platform.isLinux) {
      try {
        final process = await Process.start(
          'setsid',
          [executable, ...arguments],
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
          runInShell: false,
        );
        _isolatedProcessGroups.add(process.pid);
        return process;
      } on ProcessException {
        // Fall back to the portable process-group helper below.
      }
    }

    final grouped = await _startWithNewProcessGroup(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
    );
    if (grouped != null) return grouped;

    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: false,
    );
  }

  Future<Process?> _startWithNewProcessGroup(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    required bool includeParentEnvironment,
  }) async {
    Directory? handshakeDirectory;
    Process? process;
    try {
      handshakeDirectory = await Directory.systemTemp.createTemp(
        'conclave-process-group-',
      );
      final handshake = File('${handshakeDirectory.path}/ready');
      const groupSetup = r'''
my $ok = setpgid(0, 0) == 0;
open my $ready, ">", $ARGV[0] or exit 126;
print $ready ($ok ? "group" : "fallback");
close $ready;
shift @ARGV;
my $executable = shift @ARGV;
exec {$executable} $executable, @ARGV or exit 127;
''';
      process = await Process.start(
        '/usr/bin/perl',
        ['-MPOSIX', '-e', groupSetup, handshake.path, executable, ...arguments],
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: false,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      var exited = false;
      unawaited(process.exitCode.then((_) => exited = true));
      while (!await handshake.exists() &&
          !exited &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (!await handshake.exists()) {
        process.kill(ProcessSignal.sigkill);
        return null;
      }
      final isolated = (await handshake.readAsString()) == 'group';
      await handshakeDirectory.delete(recursive: true);
      handshakeDirectory = null;
      if (isolated) _isolatedProcessGroups.add(process.pid);
      return process;
    } on ProcessException {
      if (process != null) process.kill(ProcessSignal.sigkill);
      return null;
    } on FileSystemException {
      if (process != null) process.kill(ProcessSignal.sigkill);
      return null;
    } finally {
      if (handshakeDirectory != null) {
        try {
          await handshakeDirectory.delete(recursive: true);
        } on FileSystemException {
          // The helper may already have removed the temporary directory.
        }
      }
    }
  }

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {
    final descendants = _knownDescendants.putIfAbsent(process.pid, () => {});
    // Remember descendants before asking the Worker Package to stop. A package
    // crash can make provider processes outlive their original parent.
    descendants.addAll(await _processDescendants(process.pid));
    if (!force) {
      // Give the Worker Package time to handle the signal and clean up its
      // provider child. Escalation below kills the Workspace-owned tree.
      process.kill(ProcessSignal.sigterm);
      return;
    }

    if (_isolatedProcessGroups.contains(process.pid)) {
      try {
        await Process.run('kill', ['-KILL', '--', '-${process.pid}'])
            .timeout(const Duration(seconds: 2));
      } on Object {
        // Descendant PID cleanup below also handles a vanished group leader.
      }
    }
    final orderedPids = descendants.toList().reversed.toList();
    for (var offset = 0; offset < orderedPids.length; offset += 256) {
      final pids = orderedPids.skip(offset).take(256).map((pid) => '$pid');
      try {
        await Process.run('kill', ['-KILL', ...pids])
            .timeout(const Duration(seconds: 5));
      } on Object {
        // Continue terminating the rest of the tree if one process raced exit.
      }
    }
    process.kill(ProcessSignal.sigkill);
    _knownDescendants.remove(process.pid);
    _isolatedProcessGroups.remove(process.pid);
  }

  Future<Set<int>> _processDescendants(int rootPid) async {
    final discovered = <int>{};
    final pending = <int>[rootPid];
    while (pending.isNotEmpty && discovered.length < 1024) {
      final parent = pending.removeLast();
      try {
        final result = await Process.run('pgrep', ['-P', '$parent'])
            .timeout(const Duration(seconds: 2));
        if (result.exitCode != 0) continue;
        for (final line in result.stdout.toString().split('\n')) {
          final pid = int.tryParse(line.trim());
          if (pid != null && pid != rootPid && discovered.add(pid)) {
            pending.add(pid);
          }
        }
      } on Object {
        // pgrep may be absent; the direct Process.kill below still works.
      }
    }
    return discovered;
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
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true}) {
    return Process.start(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: false);
  }

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {
    if (!force) {
      process.kill(ProcessSignal.sigterm);
      return;
    }
    try {
      final result =
          await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F'])
              .timeout(const Duration(seconds: 5));
      if (result.exitCode == 0) {
        await process.exitCode.timeout(const Duration(seconds: 5));
        return;
      }
    } on Object {
      // Fall back to the Dart handle if taskkill is unavailable or times out.
    }
    process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // The caller retains its own bounded timeout if the process is stuck.
    }
  }
}

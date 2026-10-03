import 'dart:async';
import 'dart:io';

import 'worker_process_cleanup.dart';

/// Abstraction for starting and terminating isolated child process trees.
abstract interface class PlatformProcessSupervisor {
  Future<Process> startIsolatedProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  });

  Future<void> terminateProcessTree(Process process, {required bool force});
}

/// Default standard OS process supervisor using direct Process spawning
/// and WorkerProcessCleanup termination.
class StandardProcessSupervisor implements PlatformProcessSupervisor {
  const StandardProcessSupervisor({
    this.cleanup = const WorkerProcessCleanup(),
  });

  final WorkerProcessCleanup cleanup;

  @override
  Future<Process> startIsolatedProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: false,
    );
  }

  @override
  Future<void> terminateProcessTree(
    Process process, {
    required bool force,
  }) async {
    if (force) {
      await cleanup.terminateTree(process, force: true);
      try {
        await process.exitCode.timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        // Ignored
      }
    } else {
      await cleanup.terminate(process);
    }
  }
}

import 'dart:async';
import 'dart:io';

/// Direct-child cleanup primitive. OS-specific descendant supervision is added
/// by the Worker process supervisor integration.
class WorkerProcessCleanup {
  const WorkerProcessCleanup();

  /// Stops an orphaned process tree when its former service parent crashed.
  /// The caller must verify the PID's executable and ownership before calling.
  Future<void> terminateOrphanedPid(int pid) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      return;
    }
    final descendants = await _descendantsOf(pid);
    for (final child in descendants) {
      Process.killPid(child, ProcessSignal.sigterm);
    }
    Process.killPid(pid, ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final child in descendants) {
      Process.killPid(child, ProcessSignal.sigkill);
    }
    Process.killPid(pid, ProcessSignal.sigkill);
  }

  Future<void> terminateTree(Process process, {required bool force}) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', [
        '/PID',
        '${process.pid}',
        '/T',
        if (force) '/F',
      ]);
      return;
    }

    final descendants = await _descendantsOf(process.pid);
    final signal = force ? ProcessSignal.sigkill : ProcessSignal.sigterm;
    for (final pid in descendants) {
      Process.killPid(pid, signal);
    }
    process.kill(signal);
  }

  Future<int> terminate(
    Process process, {
    Duration grace = const Duration(seconds: 2),
  }) async {
    await terminateTree(process, force: false);
    try {
      return await process.exitCode.timeout(grace);
    } on TimeoutException {
      await terminateTree(process, force: true);
      return process.exitCode;
    }
  }

  Future<List<int>> _descendantsOf(int rootPid) async {
    try {
      final result = await Process.run('ps', ['-axo', 'pid=,ppid=']);
      if (result.exitCode != 0) return const [];
      final childrenByParent = <int, List<int>>{};
      for (final line in result.stdout.toString().split('\n')) {
        final values = line.trim().split(RegExp(r'\s+'));
        if (values.length != 2) continue;
        final pid = int.tryParse(values[0]);
        final parentPid = int.tryParse(values[1]);
        if (pid != null && parentPid != null) {
          childrenByParent.putIfAbsent(parentPid, () => []).add(pid);
        }
      }
      final ordered = <int>[];
      final visited = <int>{};
      void visit(int parentPid) {
        for (final childPid in childrenByParent[parentPid] ?? const <int>[]) {
          if (!visited.add(childPid)) continue;
          visit(childPid);
          ordered.add(childPid);
        }
      }

      visit(rootPid);
      return ordered;
    } on Object {
      return const [];
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'cli_process.dart';

import 'worker_process_cleanup.dart';

typedef CliLineHandler = FutureOr<void> Function(String line);

/// Whether the CLI process [pid] currently has running child processes (a
/// shell command, a build, a test run). Used to tell a quiet but busy agent
/// from a stuck one.
typedef CliChildProcessProbe = Future<bool> Function(int pid);

/// Default probe: direct children via `pgrep -P`. When the platform cannot
/// answer, the agent is assumed busy so it is never stopped wrongly.
Future<bool> hasRunningChildProcesses(int pid) async {
  if (Platform.isWindows) return true;
  try {
    final result = await Process.run('pgrep', ['-P', '$pid']);
    if (result.exitCode == 0)
      return (result.stdout as String).trim().isNotEmpty;
    // pgrep exits 1 when nothing matches; any other code means it failed.
    return result.exitCode != 1;
  } on Object {
    return true;
  }
}

class CliStreamResult {
  const CliStreamResult({required this.exitCode, required this.stderr});

  final int exitCode;
  final String stderr;
}

/// Runs a CLI while draining bounded stdout/stderr streams concurrently.
/// Stdout is delivered line-by-line so provider-neutral consumers can parse
/// structured event streams without buffering the full response.
class CliStreamingRunner {
  const CliStreamingRunner({
    this.maxStdoutBytes = 8 * 1024 * 1024,
    this.maxStderrBytes = 1024 * 1024,
    this.cleanup = const WorkerProcessCleanup(),
    this.drainGrace = const Duration(seconds: 3),
    this.stallCheckInterval = const Duration(seconds: 30),
  });

  final int maxStdoutBytes;
  final int maxStderrBytes;
  final WorkerProcessCleanup cleanup;

  /// How long to keep draining stdout/stderr after the CLI process has exited.
  /// A background process started by the provider (a dev server, a watcher)
  /// can inherit the pipes and keep them open long after the CLI is gone, so
  /// waiting for end-of-stream would hold the assignment until its deadline.
  final Duration drainGrace;

  /// How often a run with a `stallLimit` is checked for a stall.
  final Duration stallCheckInterval;

  Future<CliStreamResult> run(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
    required String stdinText,
    required Duration timeout,
    required CliLineHandler onStdoutLine,
    FutureOr<void> Function()? onStarted,

    /// When set, the run is stopped as stalled once the CLI has written
    /// nothing to stdout or stderr for this long and has no running child
    /// process. A quiet agent that is running a command is not stalled; the
    /// overall [timeout] still bounds it.
    Duration? stallLimit,
    CliChildProcessProbe? childProcessProbe,
  }) async {
    final process = await startCliProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    ).timeout(timeout);
    final stderr = StringBuffer();
    var stderrBytes = 0;
    var stdoutBytes = 0;
    Object? streamError;
    var drainAbandoned = false;
    final sinceOutput = Stopwatch()..start();
    Duration? stalledFor;
    Timer? stallTimer;
    var stallCheckRunning = false;
    final stdoutTask = () async {
      try {
        var pending = '';
        var pendingBytes = 0;
        await for (final chunk in process.stdout.transform(utf8.decoder)) {
          if (drainAbandoned) break;
          sinceOutput.reset();
          final chunkBytes = utf8.encode(chunk).length;
          stdoutBytes += chunkBytes;
          if (stdoutBytes > maxStdoutBytes) {
            throw const FormatException('CLI output exceeds configured limit');
          }
          pending += chunk;
          pendingBytes += chunkBytes;
          var newline = pending.indexOf('\n');
          while (newline >= 0) {
            var line = pending.substring(0, newline);
            if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
            await onStdoutLine(line);
            pendingBytes -= utf8
                .encode(pending.substring(0, newline + 1))
                .length;
            pending = pending.substring(newline + 1);
            newline = pending.indexOf('\n');
          }
          if (pendingBytes > maxStdoutBytes) {
            throw const FormatException(
              'CLI event line exceeds configured limit',
            );
          }
        }
        if (pending.isNotEmpty) await onStdoutLine(pending);
      } on Object catch (error) {
        streamError = error;
        process.kill(ProcessSignal.sigterm);
      }
    }();
    final stderrTask = () async {
      await for (final chunk in process.stderr) {
        if (drainAbandoned) break;
        sinceOutput.reset();
        final remaining = maxStderrBytes - stderrBytes;
        if (remaining > 0) {
          final accepted = chunk.length <= remaining
              ? chunk
              : chunk.sublist(0, remaining);
          stderr.write(utf8.decode(accepted, allowMalformed: true));
          stderrBytes += accepted.length;
        }
      }
    }();
    if (stallLimit != null) {
      final probe = childProcessProbe ?? hasRunningChildProcesses;
      stallTimer = Timer.periodic(stallCheckInterval, (_) async {
        if (stallCheckRunning || stalledFor != null) return;
        if (sinceOutput.elapsed < stallLimit) return;
        stallCheckRunning = true;
        try {
          if (await probe(process.pid)) return;
          // Re-check: output may have arrived while the probe ran.
          if (sinceOutput.elapsed < stallLimit) return;
          stalledFor = sinceOutput.elapsed;
          process.kill(ProcessSignal.sigterm);
        } finally {
          stallCheckRunning = false;
        }
      });
    }
    try {
      final timer = Stopwatch()..start();
      final started = onStarted;
      if (started != null) {
        await Future.sync(started).timeout(_remaining(timeout, timer));
      }
      Object? stdinError;
      final stdinTask = () async {
        try {
          process.stdin.write(stdinText);
          await process.stdin.close();
        } on Object catch (error) {
          stdinError = error;
        }
      }();
      final code = await process.exitCode.timeout(_remaining(timeout, timer));
      if (stalledFor != null) {
        throw TimeoutException(
          'CLI produced no output for ${stalledFor!.inMinutes} minutes and '
          'had no running child process',
        );
      }
      await stdinTask.timeout(_remaining(timeout, timer));
      final drainBudget = _remaining(timeout, timer);
      try {
        await Future.wait([
          stdoutTask,
          stderrTask,
        ]).timeout(drainGrace < drainBudget ? drainGrace : drainBudget);
      } on TimeoutException {
        // The CLI exited but something else still holds its pipes. The
        // provider result is complete, so stop waiting for end-of-stream.
        if (_remaining(timeout, timer) <= Duration.zero) rethrow;
        drainAbandoned = true;
      }
      if (streamError != null) throw streamError!;
      // Some CLIs ignore stdin and exit as soon as their argument-based
      // request finishes. A closed stdin pipe must not override a successful
      // process result in that case.
      if (stdinError != null && code != 0) throw stdinError!;
      return CliStreamResult(exitCode: code, stderr: stderr.toString());
    } on TimeoutException {
      await cleanup.terminate(process);
      rethrow;
    } on Object {
      await cleanup.terminate(process);
      rethrow;
    } finally {
      stallTimer?.cancel();
    }
  }

  Duration _remaining(Duration timeout, Stopwatch timer) {
    final remaining = timeout - timer.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('CLI execution deadline elapsed');
    }
    return remaining;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'worker_process_cleanup.dart';

typedef CliLineHandler = FutureOr<void> Function(String line);

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
  });

  final int maxStdoutBytes;
  final int maxStderrBytes;
  final WorkerProcessCleanup cleanup;

  Future<CliStreamResult> run(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
    required String stdinText,
    required Duration timeout,
    required CliLineHandler onStdoutLine,
    FutureOr<void> Function()? onStarted,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    final stderr = StringBuffer();
    var stderrBytes = 0;
    var stdoutBytes = 0;
    Object? streamError;
    final stdoutTask = () async {
      try {
        var pending = '';
        await for (final chunk in process.stdout.transform(utf8.decoder)) {
          stdoutBytes += utf8.encode(chunk).length;
          if (stdoutBytes > maxStdoutBytes) {
            throw const FormatException('CLI output exceeds configured limit');
          }
          pending += chunk;
          var newline = pending.indexOf('\n');
          while (newline >= 0) {
            var line = pending.substring(0, newline);
            if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
            await onStdoutLine(line);
            pending = pending.substring(newline + 1);
            newline = pending.indexOf('\n');
          }
          if (pending.length > maxStdoutBytes) {
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
    try {
      await onStarted?.call();
      Object? stdinError;
      final stdinTask = () async {
        try {
          process.stdin.write(stdinText);
          await process.stdin.close();
        } on Object catch (error) {
          stdinError = error;
        }
      }();
      final code = await process.exitCode.timeout(timeout);
      await stdinTask;
      await Future.wait([stdoutTask, stderrTask]);
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
    }
  }
}

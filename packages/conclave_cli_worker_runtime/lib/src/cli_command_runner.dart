import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'worker_process_cleanup.dart';

class CliCommandResult {
  const CliCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

class CliCommandRunner {
  const CliCommandRunner({
    this.maxOutputBytes = 1024 * 1024,
    this.cleanup = const WorkerProcessCleanup(),
  });

  final int maxOutputBytes;
  final WorkerProcessCleanup cleanup;

  Future<CliCommandResult> run(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    final stdoutFuture = _readBounded(process.stdout);
    final stderrFuture = _readBounded(process.stderr);
    try {
      // Bound the entire command, including inherited child stdout/stderr pipes.
      final result = await Future.wait<Object>([
        process.exitCode,
        stdoutFuture,
        stderrFuture,
      ], eagerError: true).timeout(timeout);
      return CliCommandResult(
        exitCode: result[0] as int,
        stdout: result[1] as String,
        stderr: result[2] as String,
      );
    } on Object {
      await cleanup.terminate(process);
      rethrow;
    }
  }

  Stream<String> lines(Stream<List<int>> stream) =>
      stream.transform(utf8.decoder).transform(const LineSplitter());

  Future<String> _readBounded(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxOutputBytes) {
        throw const FormatException('CLI output exceeds configured limit');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}

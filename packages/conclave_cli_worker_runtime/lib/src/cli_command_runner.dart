import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  const CliCommandRunner({this.maxOutputBytes = 1024 * 1024});

  final int maxOutputBytes;

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
    final stdoutFuture = _readBounded(process.stdout, process);
    final stderrFuture = _readBounded(process.stderr, process);
    try {
      final code = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          throw TimeoutException('CLI command exceeded its deadline', timeout);
        },
      );
      return CliCommandResult(
        exitCode: code,
        stdout: await stdoutFuture,
        stderr: await stderrFuture,
      );
    } on Object {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  Stream<String> lines(Stream<List<int>> stream) =>
      stream.transform(utf8.decoder).transform(const LineSplitter());

  Future<String> _readBounded(Stream<List<int>> stream, Process process) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxOutputBytes) {
        process.kill(ProcessSignal.sigterm);
        throw const FormatException('CLI output exceeds configured limit');
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}

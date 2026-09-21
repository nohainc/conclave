import 'dart:io';

typedef CommandInvoker = Future<ProcessResult> Function(
    String executable, List<String> arguments);

class ClaudeCodeWorker {
  ClaudeCodeWorker({CommandInvoker? invoke}) : _invoke = invoke ?? Process.run;
  final CommandInvoker _invoke;

  Future<String> execute(String objective,
      {String executable = 'claude'}) async {
    final result =
        await _invoke(executable, ['-p', objective, '--output-format', 'json']);
    if (result.exitCode != 0)
      throw StateError('Claude Code command failed: ${result.stderr}');
    return result.stdout.toString();
  }
}

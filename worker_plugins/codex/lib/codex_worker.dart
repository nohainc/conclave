import 'dart:io';

typedef CommandInvoker = Future<ProcessResult> Function(
    String executable, List<String> arguments);

class CodexWorker {
  CodexWorker({CommandInvoker? invoke}) : _invoke = invoke ?? _defaultInvoke;
  final CommandInvoker _invoke;

  Future<String> execute(String objective,
      {String executable = 'codex'}) async {
    final result = await _invoke(executable, ['exec', '--json', objective]);
    if (result.exitCode != 0) {
      throw StateError('Codex command failed: ${result.stderr}');
    }
    return result.stdout.toString();
  }

  static Future<ProcessResult> _defaultInvoke(
          String executable, List<String> args) =>
      Process.run(executable, args);
}

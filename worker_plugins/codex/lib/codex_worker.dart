import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef CommandInvoker = Future<ProcessResult> Function(
    String executable, List<String> arguments);
typedef ProcessStarter = Future<Process> Function(
    String executable, List<String> arguments,
    {String? workingDirectory});

class CodexAvailability {
  const CodexAvailability({
    required this.installed,
    this.version,
    required this.authenticated,
  });

  final bool installed;
  final String? version;
  final bool authenticated;
}

class CodexTaskResult {
  const CodexTaskResult({
    required this.summary,
    required this.output,
    required this.events,
  });

  final String summary;
  final Map<String, Object?> output;
  final List<Map<String, Object?>> events;
}

class CodexWorker {
  CodexWorker({CommandInvoker? invoke, ProcessStarter? start})
      : _invoke = invoke ?? _defaultInvoke,
        _start = start ?? _defaultStart;
  final CommandInvoker _invoke;
  final ProcessStarter _start;

  Future<CodexAvailability> availability({String executable = 'codex'}) async {
    try {
      final versionResult = await _invoke(executable, ['--version']);
      if (versionResult.exitCode != 0) {
        return const CodexAvailability(installed: false, authenticated: false);
      }
      final version = _firstVersion(versionResult.stdout.toString());
      final authResult = await _invoke(executable, ['login', 'status']);
      return CodexAvailability(
        installed: true,
        version: version,
        authenticated: authResult.exitCode == 0,
      );
    } on ProcessException {
      return const CodexAvailability(installed: false, authenticated: false);
    }
  }

  Future<String> execute(String objective,
      {String executable = 'codex'}) async {
    final result = await _invoke(executable, ['exec', '--json', objective]);
    if (result.exitCode != 0) {
      throw StateError('Codex command failed: ${result.stderr}');
    }
    return result.stdout.toString();
  }

  Future<CodexTaskResult> executeTask(
    String objective, {
    String executable = 'codex',
    String? workingDirectory,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final process = await _start(
      executable,
      ['exec', '--json', objective],
      workingDirectory: workingDirectory,
    );
    final stdout = <int>[];
    final stderr = <int>[];
    final stdoutSubscription = process.stdout.listen(stdout.addAll);
    final stderrSubscription = process.stderr.listen(stderr.addAll);
    try {
      final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        throw TimeoutException('Codex task timed out', timeout);
      });
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      if (exitCode != 0) {
        throw StateError(
          'Codex command failed: ${String.fromCharCodes(stderr)}',
        );
      }
      return parseStructuredOutput(String.fromCharCodes(stdout));
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }
  }

  CodexTaskResult parseStructuredOutput(String raw) {
    final events = <Map<String, Object?>>[];
    for (final line in raw.split('\n')) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('Codex JSON event must be an object');
      }
      events.add(Map<String, Object?>.from(decoded));
    }
    if (events.isEmpty) {
      throw const FormatException('Codex returned no JSON events');
    }
    final finalEvent = events.last;
    final result = finalEvent['result'];
    final output = result is Map
        ? Map<String, Object?>.from(result)
        : Map<String, Object?>.from(finalEvent);
    final summary = output['summary'] ?? output['message'] ?? output['text'];
    return CodexTaskResult(
      summary: summary is String && summary.isNotEmpty
          ? summary
          : 'Codex task completed',
      output: output,
      events: events,
    );
  }

  String? _firstVersion(String value) {
    final match =
        RegExp(r'\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?').firstMatch(value);
    return match?.group(0);
  }

  static Future<ProcessResult> _defaultInvoke(
          String executable, List<String> args) =>
      Process.run(executable, args);

  static Future<Process> _defaultStart(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) =>
      Process.start(executable, args, workingDirectory: workingDirectory);
}

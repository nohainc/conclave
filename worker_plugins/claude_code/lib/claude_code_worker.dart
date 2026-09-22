import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef CommandInvoker = Future<ProcessResult> Function(
    String executable, List<String> arguments);
typedef ProcessStarter = Future<Process> Function(
    String executable, List<String> arguments,
    {String? workingDirectory});

class ClaudeCodeAvailability {
  const ClaudeCodeAvailability({
    required this.installed,
    this.version,
    required this.authenticated,
  });

  final bool installed;
  final String? version;
  final bool authenticated;
}

class ClaudeCodeTaskResult {
  const ClaudeCodeTaskResult({
    required this.summary,
    required this.output,
    required this.events,
  });

  final String summary;
  final Map<String, Object?> output;
  final List<Map<String, Object?>> events;
}

class ClaudeCodeWorker {
  ClaudeCodeWorker({CommandInvoker? invoke, ProcessStarter? start})
      : _invoke = invoke ?? _defaultInvoke,
        _start = start ?? _defaultStart;

  final CommandInvoker _invoke;
  final ProcessStarter _start;

  Future<ClaudeCodeAvailability> availability({
    String executable = 'claude',
  }) async {
    try {
      final versionResult = await _invoke(executable, ['--version']);
      if (versionResult.exitCode != 0) {
        return const ClaudeCodeAvailability(
            installed: false, authenticated: false);
      }
      final authResult = await _invoke(executable, ['auth', 'status']);
      return ClaudeCodeAvailability(
        installed: true,
        version: _firstVersion(versionResult.stdout.toString()),
        authenticated: authResult.exitCode == 0,
      );
    } on ProcessException {
      return const ClaudeCodeAvailability(
          installed: false, authenticated: false);
    }
  }

  Future<String> execute(String objective,
      {String executable = 'claude'}) async {
    final result =
        await _invoke(executable, ['-p', objective, '--output-format', 'json']);
    if (result.exitCode != 0) {
      throw StateError('Claude Code command failed: ${result.stderr}');
    }
    return result.stdout.toString();
  }

  Future<ClaudeCodeTaskResult> executeTask(
    String objective, {
    String executable = 'claude',
    String? workingDirectory,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputBytes = 4 * 1024 * 1024,
  }) async {
    if (maxOutputBytes <= 0) {
      throw ArgumentError.value(
          maxOutputBytes, 'maxOutputBytes', 'must be positive');
    }
    final process = await _start(
      executable,
      ['-p', objective, '--output-format', 'json'],
      workingDirectory: workingDirectory,
    );
    final stdout = <int>[];
    final stderr = <int>[];
    var outputExceeded = false;
    void stopForOutputLimit() {
      if (outputExceeded) return;
      outputExceeded = true;
      unawaited(_terminate(process));
    }

    final stdoutSubscription = process.stdout.listen((chunk) {
      if (stdout.length + chunk.length > maxOutputBytes) {
        stdout.addAll(chunk.take(maxOutputBytes - stdout.length));
        stopForOutputLimit();
        return;
      }
      stdout.addAll(chunk);
    });
    final stderrSubscription = process.stderr.listen((chunk) {
      if (stderr.length + chunk.length > maxOutputBytes) {
        stderr.addAll(chunk.take(maxOutputBytes - stderr.length));
        stopForOutputLimit();
        return;
      }
      stderr.addAll(chunk);
    });
    try {
      final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
        unawaited(_terminate(process));
        throw TimeoutException('Claude Code task timed out', timeout);
      });
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      if (outputExceeded) {
        throw StateError('Claude Code output exceeded $maxOutputBytes bytes');
      }
      if (exitCode != 0) {
        throw StateError(
          'Claude Code command failed: ${String.fromCharCodes(stderr)}',
        );
      }
      return parseStructuredOutput(String.fromCharCodes(stdout));
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }
  }

  ClaudeCodeTaskResult parseStructuredOutput(String raw) {
    final events = <Map<String, Object?>>[];
    for (final line in raw.split('\n')) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('Claude Code JSON event must be an object');
      }
      events.add(Map<String, Object?>.from(decoded));
    }
    if (events.isEmpty) {
      throw const FormatException('Claude Code returned no JSON events');
    }
    final finalEvent = events.last;
    final result = finalEvent['result'];
    final output = result is Map
        ? Map<String, Object?>.from(result)
        : Map<String, Object?>.from(finalEvent);
    final summary = output['summary'] ?? output['message'] ?? output['text'];
    return ClaudeCodeTaskResult(
      summary: summary is String && summary.isNotEmpty
          ? summary
          : 'Claude Code task completed',
      output: output,
      events: events,
    );
  }

  String? _firstVersion(String value) => RegExp(
        r'\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?',
      ).firstMatch(value)?.group(0);

  Future<void> _terminate(Process process) async {
    if (!process.kill(ProcessSignal.sigterm)) return;
    try {
      await process.exitCode.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
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

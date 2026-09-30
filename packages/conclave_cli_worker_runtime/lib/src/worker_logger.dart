import 'dart:convert';
import 'dart:io';

class WorkerLogger {
  const WorkerLogger({this.writeLine});

  final void Function(String line)? writeLine;

  void log(
    String level,
    String event, {
    Map<String, Object?> context = const {},
  }) {
    if (!RegExp(r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$').hasMatch(event)) {
      throw ArgumentError.value(event, 'event', 'must be a stable event code');
    }
    const contextFields = {
      'workerTypeId',
      'workerVersion',
      'protocolStage',
      'assignmentId',
      'requestId',
      'providerToolVersion',
      'durationMs',
      'errorCode',
      'processExitCode',
      'sessionPolicy',
    };
    final safeContext = <String, Object?>{};
    for (final entry in context.entries) {
      if (!contextFields.contains(entry.key)) continue;
      final value = entry.value;
      if (value is String || value is num || value is bool) {
        safeContext[entry.key] = value is String
            ? WorkerRedactor.redact(
                value.length > 128 ? value.substring(0, 128) : value,
              )
            : value;
      }
    }
    final line = WorkerRedactor.redact(
      jsonEncode({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'level': const {'debug', 'info', 'warning', 'error'}.contains(level)
            ? level
            : 'info',
        'event': event,
        'context': safeContext,
      }),
    );
    final writer = writeLine;
    if (writer == null) {
      stderr.writeln(line);
    } else {
      writer(line);
    }
  }
}

abstract final class WorkerRedactor {
  static String redact(String value) => value
      .replaceAll(
        RegExp(r'(bearer\s+)[a-z0-9._~+/-]+=*', caseSensitive: false),
        r'$1[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*["'])([^"']*)(["'])|(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*)([^\s,}&]+)''',
          caseSensitive: false,
        ),
        r'$1[REDACTED]$3$4[REDACTED]',
      );
}

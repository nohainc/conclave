import 'dart:convert';
import 'dart:io';

class EngineLogger {
  const EngineLogger({this.writeLine});

  final void Function(String line)? writeLine;

  void log(
    String level,
    String event, {
    Map<String, Object?> context = const {},
  }) {
    final safe = <String, Object?>{};
    for (final key in const {
      'conversationId',
      'workerSessionId',
      'baseContextRevision',
      'synchronizedContextRevision',
      'targetContextRevision',
      'synchronizedHistorySequence',
      'throughSequence',
      'requestId',
      'assignmentId',
      'workerTypeId',
      'engineVersion',
      'profileDefinitionId',
      'profileReleaseVersion',
      'profileSchemaVersion',
      'providerToolName',
      'providerToolVersion',
      'profileResolutionSource',
      'probeStage',
      'failureLayer',
      'durationMs',
      'errorCode',
      'processExitCode',
    }) {
      final value = context[key];
      if (value is String || value is num || value is bool) {
        safe[key] = value is String ? _captureDiagnostic(value) : value;
      }
    }
    final line = jsonEncode({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': const {'debug', 'info', 'warning', 'error'}.contains(level)
          ? level
          : 'info',
      'event': event,
      'context': safe,
    });
    final writer = writeLine;
    if (writer == null) {
      stderr.writeln(line);
    } else {
      writer(line);
    }
  }
}

String _captureDiagnostic(String value) {
  final safe = value
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
  return safe.length <= 128 ? safe : safe.substring(0, 128);
}

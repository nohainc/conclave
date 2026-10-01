import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/src/worker_diagnostics.dart';

class EngineLogger {
  const EngineLogger();

  void log(
    String level,
    String event, {
    Map<String, Object?> context = const {},
  }) {
    final safe = <String, Object?>{};
    for (final key in const {
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
        safe[key] = value is String
            ? WorkerDiagnosticCollector(maxCharacters: 128).capture(value)
            : value;
      }
    }
    stderr.writeln(
      jsonEncode({
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'level': const {'debug', 'info', 'warning', 'error'}.contains(level)
            ? level
            : 'info',
        'event': event,
        'context': safe,
      }),
    );
  }
}

import 'dart:convert';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

/// Utilities for sanitizing provider and worker diagnostics so that secrets,
/// raw environment variables, full home directories, and user prompts never leak.
abstract final class SafeProviderDiagnostics {
  static const int maxTokenLength = 64;
  static const int maxEventLength = 96;
  static const int maxReportChars = 16000;

  static const _allowedLevels = {'debug', 'info', 'warn', 'warning', 'error'};

  static String safeLevel(String level) =>
      _allowedLevels.contains(level.toLowerCase())
      ? level.toLowerCase()
      : 'info';

  static String safeEvent(String event) {
    final trimmed = event.trim();
    if (trimmed.length > maxEventLength ||
        !RegExp(
          r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*$',
        ).hasMatch(trimmed)) {
      return 'worker.log.invalid_event';
    }
    return trimmed;
  }

  static String safeToken(String token, {int maxLength = maxTokenLength}) {
    final sanitized = token.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
    return sanitized.length > maxLength
        ? sanitized.substring(0, maxLength)
        : sanitized;
  }

  static Map<String, Object?> safeContext(Map<String, Object?> context) {
    final result = <String, Object?>{};
    for (final entry in context.entries) {
      final key = safeToken(entry.key, maxLength: 32);
      final value = entry.value;
      if (value is String) {
        result[key] = safeToken(value, maxLength: 128);
      } else if (value is num || value is bool) {
        result[key] = value;
      } else if (value is List) {
        result[key] = value
            .take(16)
            .map(
              (item) => item is String ? safeToken(item, maxLength: 64) : item,
            )
            .where((item) => item is num || item is bool || item is String)
            .toList();
      }
    }
    return result;
  }

  /// Parses an arbitrary line of worker/provider stderr output into a safe
  /// sanitized JSON context map. Arbitrary messages and raw text are discarded.
  static Map<String, Object?> parseStderrLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) throw const FormatException();
      final event = decoded['event'];
      final level = decoded['level'];
      final rawContext = decoded['context'];
      final context = rawContext is Map
          ? Map<String, Object?>.from(rawContext)
          : const <String, Object?>{};

      // Remove sensitive or smuggled identity fields
      context.remove('assignmentId');
      context.remove('requestId');
      context.remove('prompt');
      context.remove('apiKey');
      context.remove('token');
      context.remove('credential');

      return {
        'event':
            event is String &&
                RegExp(
                  r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$',
                ).hasMatch(event)
            ? 'worker.$event'
            : 'worker.log.invalid_event',
        'level': level is String ? safeLevel(level) : 'info',
        'context': safeContext(context),
      };
    } on Object {
      return {
        'event': 'worker.stderr.unstructured',
        'level': 'warn',
        'context': {'lineBytes': utf8.encode(line).length},
      };
    }
  }

  static String redact(String value) => value
      .replaceAllMapped(
        RegExp(r'(bearer\s+)[a-z0-9._~+/-]+=*', caseSensitive: false),
        (match) => '${match[1]}[REDACTED]',
      )
      .replaceAllMapped(
        RegExp(
          r'''((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)\s*[:=]\s*)[^\s,;]+''',
          caseSensitive: false,
        ),
        (match) => '${match[1]}[REDACTED]',
      );

  /// Normalizes an exception or error into a stable WorkerIssueCode.
  static String normalizeIssueCode(Object error) {
    if (error is FormatException) return WorkerIssueCode.malformedFrame;
    final message = error.toString().toLowerCase();
    if (message.contains('timeout') || message.contains('deadline')) {
      return WorkerIssueCode.deadlineExceeded;
    }
    if (message.contains('not found') || message.contains('unavailable')) {
      return WorkerIssueCode.providerToolUnavailable;
    }
    if (message.contains('auth') || message.contains('unauthorized')) {
      return WorkerIssueCode.providerAuthenticationRequired;
    }
    if (message.contains('unsupported version')) {
      return WorkerIssueCode.unsupportedProviderToolVersion;
    }
    return WorkerIssueCode.providerFailure;
  }
}

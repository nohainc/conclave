import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'platform_runtime.dart';

/// Bounded JSONL logs for one Worker type. Files live beside Worker state,
/// outside immutable version directories so updates do not discard history.
final class WorkerDiagnosticStore {
  WorkerDiagnosticStore({
    required this.directory,
    this.maxFileBytes = 256 * 1024,
    this.maxFiles = 3,
    PlatformRuntime? platformRuntime,
  }) : _platformRuntime = platformRuntime ?? currentPlatformRuntime {
    if (maxFileBytes < 512) {
      throw ArgumentError.value(maxFileBytes, 'maxFileBytes', 'must be >= 512');
    }
    if (maxFiles < 1 || maxFiles > 10) {
      throw ArgumentError.value(maxFiles, 'maxFiles', 'must be from 1 to 10');
    }
  }

  final Directory directory;
  final int maxFileBytes;
  final int maxFiles;
  final PlatformRuntime _platformRuntime;

  static final Map<String, Future<void>> _writeQueues = {};
  File get currentFile => File('${directory.path}/worker.jsonl');

  Future<void> record({
    required String workerTypeId,
    required String workerVersion,
    required String protocolStage,
    required String event,
    String level = 'info',
    String? runId,
    String? providerToolName,
    String? providerToolVersion,
    int? durationMs,
    String? errorCode,
    int? processExitCode,
    Map<String, Object?> context = const {},
  }) {
    final normalized = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': _safeLevel(level),
      'event': _safeEvent(event),
      'workerTypeId': _safeToken(workerTypeId, maxLength: 64),
      'workerVersion': _safeToken(workerVersion, maxLength: 64),
      'protocolStage': _safeToken(protocolStage, maxLength: 32),
      if (runId != null) 'runId': _safeToken(runId, maxLength: 128),
      if (providerToolName != null)
        'providerToolName': _safeToken(providerToolName, maxLength: 64),
      if (providerToolVersion != null)
        'providerToolVersion': _safeToken(providerToolVersion, maxLength: 64),
      if (durationMs != null) 'durationMs': durationMs.clamp(0, 0x7fffffff),
      if (errorCode != null) 'errorCode': _safeToken(errorCode, maxLength: 64),
      if (processExitCode != null) 'processExitCode': processExitCode,
      if (context.isNotEmpty) 'context': _safeContext(context),
    };
    final line = '${jsonEncode(normalized)}\n';
    if (utf8.encode(line).length > maxFileBytes) {
      return Future.error(StateError('Worker diagnostic record exceeds limit'));
    }
    final key = directory.absolute.path;
    final previous = _writeQueues[key] ?? Future<void>.value();
    final queued = previous.catchError((_) {}).then((_) => _append(line));
    _writeQueues[key] = queued;
    return queued.whenComplete(() {
      if (identical(_writeQueues[key], queued)) _writeQueues.remove(key);
    });
  }

  /// Imports only stable event codes and explicitly safe scalar context from
  /// Worker JSONL. Free-form messages, stderr text, prompts and paths are
  /// deliberately discarded.
  Future<void> recordWorkerStderrLine(
    String line, {
    required String workerTypeId,
    required String workerVersion,
    required String protocolStage,
    String? runId,
  }) async {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final event = decoded['event'];
      final level = decoded['level'];
      final rawContext = decoded['context'];
      final context = rawContext is Map
          ? Map<String, Object?>.from(rawContext)
          : const <String, Object?>{};
      // The host supplies run identity; Worker-provided identity fields are
      // discarded so user text cannot be smuggled through a mislabeled key.
      context.remove('assignmentId');
      context.remove('requestId');
      await record(
        workerTypeId: workerTypeId,
        workerVersion: workerVersion,
        protocolStage: protocolStage,
        event: event is String &&
                RegExp(r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$')
                    .hasMatch(event)
            ? 'worker.$event'
            : 'worker.log.invalid_event',
        level: level is String ? level : 'info',
        runId: runId,
        providerToolName: _stringContext(context, 'providerToolName'),
        providerToolVersion: _stringContext(context, 'providerToolVersion'),
        durationMs: _intContext(context, 'durationMs'),
        errorCode: _stringContext(context, 'errorCode'),
        context: context,
      );
    } on Object {
      await record(
        workerTypeId: workerTypeId,
        workerVersion: workerVersion,
        protocolStage: protocolStage,
        event: 'worker.stderr.unstructured',
        runId: runId,
        context: {'lineBytes': utf8.encode(line).length},
      );
    }
  }

  Future<String> createCopyableReport({int maxCharacters = 16000}) async {
    if (maxCharacters < 512) {
      throw ArgumentError.value(
          maxCharacters, 'maxCharacters', 'must be >= 512');
    }
    final lines = <String>[];
    for (var index = maxFiles - 1; index >= 1; index--) {
      final file = File('${directory.path}/worker.jsonl.$index');
      if (await file.exists()) lines.addAll(await file.readAsLines());
    }
    if (await currentFile.exists()) {
      lines.addAll(await currentFile.readAsLines());
    }
    final safeLines = <String>[];
    for (final line in lines) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          safeLines.add(jsonEncode(_safeStoredRecord(decoded)));
        }
      } on Object {
        // Ignore incomplete/corrupt trailing records after a crash.
      }
    }
    final report = StringBuffer()
      ..writeln('Conclave Worker diagnostic report')
      ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('Sensitive Worker input and free-form output are omitted.')
      ..writeln();
    for (final line in safeLines.reversed) {
      if (report.length + line.length + 1 > maxCharacters) break;
      report.writeln(line);
    }
    final output = report.toString();
    if (output.length <= maxCharacters) return output;
    return output.substring(0, maxCharacters);
  }

  Future<void> _append(String line) async {
    await directory.create(recursive: true);
    await _platformRuntime.restrictPermissions(directory.path, directory: true);
    final bytes = utf8.encode(line);
    final file = currentFile;
    var currentLength = await file.exists() ? await file.length() : 0;
    if (currentLength > 0 &&
        await _hasIncompleteFinalRecord(file, currentLength)) {
      await _rotate();
      currentLength = 0;
    }
    if (currentLength + bytes.length > maxFileBytes) await _rotate();
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    await _platformRuntime.restrictPermissions(file.path, directory: false);
  }

  Future<void> _rotate() async {
    if (maxFiles == 1) {
      if (await currentFile.exists()) await currentFile.delete();
      return;
    }
    final oldest = File('${directory.path}/worker.jsonl.${maxFiles - 1}');
    if (await oldest.exists()) await oldest.delete();
    for (var index = maxFiles - 2; index >= 1; index--) {
      final source = File('${directory.path}/worker.jsonl.$index');
      if (await source.exists()) {
        await source.rename('${directory.path}/worker.jsonl.${index + 1}');
      }
    }
    if (await currentFile.exists()) {
      await currentFile.rename('${directory.path}/worker.jsonl.1');
    }
  }

  Future<bool> _hasIncompleteFinalRecord(File file, int length) async {
    final handle = await file.open(mode: FileMode.read);
    try {
      await handle.setPosition(length - 1);
      return await handle.readByte() != 10;
    } finally {
      await handle.close();
    }
  }

  static Map<String, Object?> _safeStoredRecord(Map<String, dynamic> value) {
    return {
      'timestamp': value['timestamp'] is String &&
              DateTime.tryParse(value['timestamp'] as String) != null
          ? value['timestamp']
          : 'unknown',
      'level': _safeLevel(value['level']?.toString() ?? 'info'),
      'event': _safeEvent(value['event']?.toString() ?? ''),
      'workerTypeId': _safeToken(
        value['workerTypeId']?.toString() ?? '',
        maxLength: 64,
      ),
      'workerVersion': _safeToken(
        value['workerVersion']?.toString() ?? '',
        maxLength: 64,
      ),
      'protocolStage': _safeToken(
        value['protocolStage']?.toString() ?? '',
        maxLength: 32,
      ),
      if (value['runId'] is String)
        'runId': _safeToken(value['runId'] as String, maxLength: 128),
      if (value['providerToolName'] is String)
        'providerToolName': _safeToken(
          value['providerToolName'] as String,
          maxLength: 64,
        ),
      if (value['providerToolVersion'] is String)
        'providerToolVersion': _safeToken(
          value['providerToolVersion'] as String,
          maxLength: 64,
        ),
      if (value['durationMs'] is int)
        'durationMs': (value['durationMs'] as int).clamp(0, 0x7fffffff),
      if (value['errorCode'] is String)
        'errorCode': _safeToken(value['errorCode'] as String, maxLength: 64),
      if (value['processExitCode'] is int)
        'processExitCode': value['processExitCode'],
      if (value['context'] is Map)
        'context': _safeContext(
          Map<String, Object?>.from(value['context'] as Map),
        ),
    };
  }

  static Map<String, Object?> _safeContext(Map<String, Object?> context) {
    const fields = {
      'assignmentId',
      'requestId',
      'providerToolName',
      'providerToolVersion',
      'durationMs',
      'errorCode',
      'protocolStage',
      'sessionPolicy',
      'processExitCode',
    };
    return {
      for (final entry in context.entries)
        if (fields.contains(entry.key) &&
            (entry.value is String ||
                entry.value is num ||
                entry.value is bool))
          entry.key: entry.value is String
              ? _safeText(entry.value as String, maxLength: 128)
              : entry.value,
    };
  }

  static String? _stringContext(Map<String, Object?> context, String key) {
    final value = context[key];
    return value is String ? value : null;
  }

  static int? _intContext(Map<String, Object?> context, String key) {
    final value = context[key];
    return value is int ? value : null;
  }

  static String _safeLevel(String value) =>
      const {'debug', 'info', 'warning', 'error'}.contains(value)
          ? value
          : 'info';

  static String _safeEvent(String value) =>
      RegExp(r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$').hasMatch(value)
          ? value
          : 'invalid.event';

  static String _safeToken(String value, {required int maxLength}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > maxLength ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:+-]*$').hasMatch(trimmed)) {
      return 'invalid';
    }
    return trimmed;
  }

  static String _safeText(String value, {required int maxLength}) {
    final safe = _redact(value.replaceAll(RegExp(r'[\r\n\t]'), ' '));
    return safe.length <= maxLength ? safe : safe.substring(0, maxLength);
  }

  static String _redact(String value) => value
      .replaceAll(
        RegExp(r'(bearer\s+)[a-z0-9._~+/-]+=*', caseSensitive: false),
        r'$1[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)\s*[:=]\s*)[^\s,;]+''',
          caseSensitive: false,
        ),
        r'$1[REDACTED]',
      );
}

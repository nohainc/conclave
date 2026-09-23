import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:conclave_codex_worker/codex_worker.dart';
import 'package:conclave_codex_worker/codex_manifest.dart';

Future<void> main() async {
  final worker = CodexWorker();
  final active = <String, CodexCancellationToken>{};
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final method = request['method'];
      if (method == 'cancel') {
        final params = request['params'] is Map
            ? Map<String, Object?>.from(request['params'] as Map)
            : const <String, Object?>{};
        final assignmentId = params['assignmentId'] ?? params['id'];
        if (assignmentId is! String || assignmentId.isEmpty) {
          throw const FormatException('assignmentId is required');
        }
        active.remove(assignmentId)?.cancel();
        _writeResponse(request['id'], {'cancelled': true});
        continue;
      }
      if (method == 'execute') {
        final assignmentId = request['id'];
        if (assignmentId is! String || assignmentId.isEmpty) {
          throw const FormatException('assignment id is required');
        }
        final token = CodexCancellationToken();
        active[assignmentId] = token;
        unawaited(_runAssignment(worker, request, token).then((result) {
          active.remove(assignmentId);
          _writeResponse(assignmentId, result);
        }, onError: (Object error, StackTrace stack) {
          active.remove(assignmentId);
          _writeError(assignmentId, error);
        }));
        continue;
      }
      final result = switch (method) {
        'initialize' => {
            'workerId': codexWorkerManifest['workerId'],
            'version': codexWorkerManifest['version'],
            'protocolVersion': codexWorkerManifest['protocolVersion'],
            'runtimeLanguage': 'dart',
            'capabilities': codexWorkerManifest['capabilities'],
          },
        'health' => await _health(worker),
        'describe' => codexWorkerManifest,
        'cancel' => {'cancelled': false},
        'shutdown' => {'stopped': true},
        _ => throw StateError('unsupported method'),
      };
      _writeResponse(request['id'], result);
    } on Object catch (error) {
      _writeError(request['id'], error);
    }
  }
}

Future<Map<String, Object?>> _health(CodexWorker worker) async {
  final status = await worker.availability();
  return {
    'status':
        status.installed && status.authenticated ? 'healthy' : 'unavailable',
    'installed': status.installed,
    'authenticated': status.authenticated,
    if (status.version != null) 'version': status.version,
  };
}

Future<Map<String, Object?>> _runAssignment(
  CodexWorker worker,
  Map<String, dynamic> request,
  CodexCancellationToken cancellation,
) =>
    _executeAssignment(worker, request, cancellation);

void _writeResponse(Object? id, Map<String, Object?> result) {
  stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  unawaited(stdout.flush());
}

void _writeError(Object? id, Object error) {
  stdout.writeln(jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': -32000, 'message': '$error'}
  }));
  unawaited(stdout.flush());
}

Future<Map<String, Object?>> _executeAssignment(
  CodexWorker worker,
  Map<String, dynamic> request,
  CodexCancellationToken cancellation,
) async {
  final params = Map<String, Object?>.from(request['params'] as Map);
  final snapshot = params['snapshot'] is Map
      ? Map<String, Object?>.from(params['snapshot'] as Map)
      : const <String, Object?>{};
  final input = params['input'] is Map
      ? Map<String, Object?>.from(params['input'] as Map)
      : const <String, Object?>{};
  final config = params['config'] is Map
      ? Map<String, Object?>.from(params['config'] as Map)
      : const <String, Object?>{};
  final objective = params['objective'] ?? input['objective'];
  if (objective is! String || objective.trim().isEmpty) {
    throw const FormatException('assignment objective is required');
  }
  final result = await worker.executeTask(
    objective,
    input: {...config, ...input},
    workingDirectory: input['repositoryPath'] is String
        ? input['repositoryPath'] as String
        : null,
    cancellation: cancellation,
  );
  return {
    'status': 'completed',
    'summary': result.summary,
    if (snapshot['credentialProfileId'] is String)
      'credentialProfileId': snapshot['credentialProfileId'],
    if (snapshot['model'] is String) 'model': snapshot['model'],
    'usage': {'inputTokens': 0, 'outputTokens': 0, 'totalTokens': 0},
    'output': result.output,
    'evidence': {
      'metrics': {'events': result.events.length},
      'logs': ['Codex returned structured JSON output'],
    },
  };
}

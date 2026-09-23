import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_echo_worker/echo_manifest.dart';

Future<void> main() async {
  final cancelled = <String>{};
  final active = <String>{};

  void respond(Object? id, Object? result) {
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    unawaited(stdout.flush());
  }

  Future<void> execute(Map<String, dynamic> request) async {
    final id = request['id'];
    final rawParams = request['params'];
    final params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : <String, Object?>{};
    final snapshot = params['snapshot'] is Map
        ? Map<String, Object?>.from(params['snapshot'] as Map)
        : const <String, Object?>{};
    final assignmentId = snapshot['assignmentId'] is String
        ? snapshot['assignmentId'] as String
        : id is String
            ? id
            : '';
    active.add(assignmentId);
    try {
      final input = params['input'] is Map
          ? Map<String, Object?>.from(params['input'] as Map)
          : <String, Object?>{};
      final rawDelay = input['delayMs'];
      final delay = rawDelay is num ? rawDelay.toInt().clamp(0, 10000) : 0;
      for (var elapsed = 0; elapsed < delay; elapsed += 10) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (cancelled.remove(assignmentId)) {
          respond(id, {'status': 'cancelled', 'assignmentId': assignmentId});
          return;
        }
        if (delay >= 20 && elapsed == 0) {
          stdout.writeln(jsonEncode({
            'jsonrpc': '2.0',
            'method': 'progress',
            'params': {
              'assignmentId': assignmentId,
              'percentage': 1,
              'timestamp': DateTime.now().toUtc().toIso8601String(),
            },
          }));
        }
      }
      if (cancelled.remove(assignmentId)) {
        respond(id, {'status': 'cancelled', 'assignmentId': assignmentId});
        return;
      }
      if (input['fail'] == true) {
        _error(id, -32001, 'Deterministic echo failure');
        return;
      }
      final artifactIds = input['artifactIds'] is List
          ? (input['artifactIds'] as List).whereType<String>().toList()
          : const <String>[];
      respond(id, {
        'status': 'completed',
        'assignmentId': assignmentId,
        'summary': 'Deterministic echo worker completed assignment',
        'input': params,
        'artifactIds': artifactIds,
        'usage': {'inputTokens': 0, 'outputTokens': 0, 'totalTokens': 0},
        'evidence': {'kind': 'deterministic_echo', 'delayMs': delay},
      });
    } finally {
      active.remove(assignmentId);
    }
  }

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    try {
      final method = request['method'];
      final params = request['params'] is Map
          ? Map<String, Object?>.from(request['params'] as Map)
          : const <String, Object?>{};
      if (method == 'execute') {
        unawaited(execute(request));
        continue;
      }
      if (method == 'cancel') {
        final target = params['assignmentId'];
        if (target is String && active.contains(target)) cancelled.add(target);
        respond(request['id'], {'cancelled': target is String});
        continue;
      }
      final result = switch (method) {
        'initialize' => {
            'workerId': echoWorkerManifest['workerId'],
            'version': echoWorkerManifest['version'],
            'protocolVersion': echoWorkerManifest['protocolVersion'],
            'runtimeLanguage': 'dart',
            'capabilities': echoWorkerManifest['capabilities'],
          },
        'health' => {'status': 'healthy'},
        'describe' => echoWorkerManifest,
        'shutdown' => {'stopped': true},
        _ => throw StateError('unsupported worker method'),
      };
      respond(request['id'], result);
    } on Object catch (error) {
      _error(request['id'], -32000, '$error');
    }
  }
}

void _error(Object? id, int code, String message) {
  stdout.writeln(jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  }));
  unawaited(stdout.flush());
}

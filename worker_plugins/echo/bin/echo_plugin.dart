import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final cancelledAssignments = <String>{};
  final activeAssignments = <String>{};

  void respond(Object? id, Map<String, Object?> result) {
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  Future<void> runAssignment(Map<String, dynamic> request) async {
    final id = request['id'];
    final assignmentId = id is String ? id : '';
    activeAssignments.add(assignmentId);
    try {
      final rawParams = request['params'];
      final params = rawParams is Map
          ? Map<String, Object?>.from(rawParams)
          : <String, Object?>{};
      final input = params['input'] is Map
          ? Map<String, Object?>.from(params['input'] as Map)
          : <String, Object?>{};
      final delayMs = input['delayMs'];
      final delay = delayMs is int ? delayMs.clamp(0, 10000) : 0;
      for (var elapsed = 0; elapsed < delay; elapsed += 10) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (cancelledAssignments.remove(assignmentId)) {
          respond(id, {
            'status': 'cancelled',
            'summary': 'Deterministic echo assignment cancelled',
          });
          return;
        }
        if (delay >= 20 && elapsed == 0) {
          stdout.writeln(jsonEncode({
            'jsonrpc': '2.0',
            'method': 'progress',
            'params': {'stage': 'running', 'percent': 1},
          }));
        }
      }
      if (cancelledAssignments.remove(assignmentId)) {
        respond(id, {
          'status': 'cancelled',
          'summary': 'Deterministic echo assignment cancelled',
        });
        return;
      }
      if (input['fail'] == true) {
        stdout.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': -32001,
            'message': 'Deterministic echo failure',
          },
        }));
        return;
      }
      final artifactIds = input['artifactIds'] is List
          ? (input['artifactIds'] as List).whereType<String>().toList()
          : const <String>[];
      respond(id, {
        'status': 'completed',
        'summary': 'Deterministic echo worker completed assignment',
        'input': params,
        'artifactIds': artifactIds,
        'evidence': {
          'kind': 'deterministic_echo',
          'delayMs': delay,
        },
      });
    } finally {
      activeAssignments.remove(assignmentId);
    }
  }

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = jsonDecode(line) as Map<String, dynamic>;
    final method = request['method'];
    final params = request['params'] is Map
        ? Map<String, Object?>.from(request['params'] as Map)
        : const <String, Object?>{};
    if (method == 'start_assignment') {
      unawaited(runAssignment(request));
      continue;
    }
    if (method == 'cancel_assignment') {
      final target = params['assignmentId'];
      if (target is String && activeAssignments.contains(target)) {
        cancelledAssignments.add(target);
      }
      respond(request['id'], {'cancelled': target is String});
      continue;
    }
    final result = switch (method) {
      'initialize' => {
        'pluginId': 'conclave.echo',
        'version': '1.0.0',
        'protocolVersion': '2.0',
        'runtimeLanguage': 'dart',
        'capabilities': ['deterministic_echo'],
      },
      'health' => {'status': 'healthy'},
      'configure_worker' => {'configured': true},
      'cancel_assignment' => {'cancelled': true},
      'shutdown' => {'stopped': true},
      _ => throw StateError('unsupported method'),
    };
    stdout.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
  }
}

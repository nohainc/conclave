import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  Future<Map<String, dynamic>> responseFor(
    Stream<String> output,
    String id,
  ) async {
    await for (final line in output) {
      final response = jsonDecode(line) as Map<String, dynamic>;
      if (response['id'] == id) return response;
    }
    throw StateError('plugin exited before response $id');
  }

  test('executes the real echo plugin over stdin/stdout', () async {
    final process =
        await Process.start('dart', ['run', 'bin/echo_worker.dart']);
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'assignment-1',
      'method': 'start_assignment',
      'params': {'objective': 'echo'},
    }));
    final response = await responseFor(output, 'assignment-1');
    expect(response['result']['status'], 'completed');
    process.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': 'shutdown', 'method': 'shutdown'}));
    final shutdown = await responseFor(output, 'shutdown');
    expect(shutdown['result']['stopped'], true);
    await process.stdin.close();
    await process.kill(ProcessSignal.sigterm);
  });

  test('emits deterministic artifacts and evidence', () async {
    final process =
        await Process.start('dart', ['run', 'bin/echo_worker.dart']);
    final output =
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'assignment-2',
      'method': 'start_assignment',
      'params': {
        'input': {
          'artifactIds': ['artifact-1'],
          'delayMs': 1
        },
      },
    }));
    final response = await responseFor(output, 'assignment-2');
    expect(response['result']['artifactIds'], ['artifact-1']);
    expect(response['result']['evidence']['kind'], 'deterministic_echo');
    await process.kill(ProcessSignal.sigterm);
  });

  test('returns a structured deterministic failure', () async {
    final process =
        await Process.start('dart', ['run', 'bin/echo_worker.dart']);
    final output =
        process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'assignment-3',
      'method': 'start_assignment',
      'params': {
        'input': {'fail': true},
      },
    }));
    final response = await responseFor(output, 'assignment-3');
    expect(response['error']['message'], 'Deterministic echo failure');
    await process.kill(ProcessSignal.sigterm);
  });

  test('cancels a delayed assignment while it is running', () async {
    final process =
        await Process.start('dart', ['run', 'bin/echo_worker.dart']);
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'assignment-cancelled',
      'method': 'start_assignment',
      'params': {'input': {'delayMs': 200}},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 25));
    process.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'cancel-1',
      'method': 'cancel_assignment',
      'params': {'assignmentId': 'assignment-cancelled'},
    }));
    final cancel = await responseFor(output, 'cancel-1');
    final result = await responseFor(output, 'assignment-cancelled');
    expect(cancel['result']['cancelled'], true);
    expect(result['result']['status'], 'cancelled');
    await process.kill(ProcessSignal.sigterm);
  });
}

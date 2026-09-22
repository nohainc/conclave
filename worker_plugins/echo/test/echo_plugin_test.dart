import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('executes the real echo plugin over stdin/stdout', () async {
    final process =
        await Process.start('dart', ['run', 'bin/echo_plugin.dart']);
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
    final response = jsonDecode(await output.first) as Map<String, dynamic>;
    expect(response['result']['status'], 'completed');
    process.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': 'shutdown', 'method': 'shutdown'}));
    final shutdown = jsonDecode(await output.first) as Map<String, dynamic>;
    expect(shutdown['result']['stopped'], true);
    await process.stdin.close();
    await process.kill(ProcessSignal.sigterm);
  });

  test('emits deterministic artifacts and evidence', () async {
    final process =
        await Process.start('dart', ['run', 'bin/echo_plugin.dart']);
    final output =
        process.stdout.transform(utf8.decoder).transform(const LineSplitter());
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
    final response = jsonDecode(await output.first) as Map<String, dynamic>;
    expect(response['result']['artifactIds'], ['artifact-1']);
    expect(response['result']['evidence']['kind'], 'deterministic_echo');
    await process.kill(ProcessSignal.sigterm);
  });

  test('returns a structured deterministic failure', () async {
    final process =
        await Process.start('dart', ['run', 'bin/echo_plugin.dart']);
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
    final response = jsonDecode(await output.first) as Map<String, dynamic>;
    expect(response['error']['message'], 'Deterministic echo failure');
    await process.kill(ProcessSignal.sigterm);
  });
}

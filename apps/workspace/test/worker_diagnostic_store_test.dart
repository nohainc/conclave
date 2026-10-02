import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/worker_diagnostic_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('worker-diagnostics-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('Worker JSONL import drops prompts, paths, and credential fields',
      () async {
    final store = WorkerDiagnosticStore(
      directory: Directory('${temporary.path}/logs'),
    );
    await store.recordWorkerStderrLine(
      jsonEncode({
        'level': 'info',
        'event': 'assignment.started',
        'message': 'user prompt: do something private',
        'context': {
          'assignmentId': 'assignment-1',
          'prompt': 'full sensitive prompt',
          'fileContents': 'private source text',
          'apiKey': 'secret-key-value',
          'providerToolName': 'Codex CLI',
          'providerToolVersion': '1.2.3',
          'workspaceVersion': '8.2.0',
          'engineVersion': '1.3.0',
          'profileDefinitionId': 'chatgpt-codex',
          'profileReleaseVersion': 9,
          'profileResolutionSource': 'stable',
          'probeStage': 'live',
          'failureLayer': 'provider_tool',
          'durationMs': 345,
          'errorCode': 'provider_auth_required',
          'profilePayload': {'secret': 'profile-private-value'},
        },
      }),
      workerTypeId: 'chatgpt',
      workerVersion: '1.0.0-beta+2',
      protocolStage: 'execute',
      runId: 'assignment-1',
    );

    final report = await store.createCopyableReport();
    expect(report, contains('chatgpt'));
    expect(report, contains('1.0.0-beta+2'));
    expect(report, contains('assignment-1'));
    expect(report, contains('Codex CLI'));
    expect(report, contains('1.2.3'));
    expect(report, contains('8.2.0'));
    expect(report, contains('1.3.0'));
    expect(report, contains('chatgpt-codex'));
    expect(report, contains('"profileReleaseVersion":9'));
    expect(report, contains('"profileResolutionSource":"stable"'));
    expect(report, contains('"probeStage":"live"'));
    expect(report, contains('"failureLayer":"provider_tool"'));
    expect(report, contains('"durationMs":345'));
    expect(report, contains('provider_auth_required'));
    expect(report, isNot(contains('full sensitive prompt')));
    expect(report, isNot(contains('private source text')));
    expect(report, isNot(contains('secret-key-value')));
    expect(report, isNot(contains('profile-private-value')));
    expect(report, isNot(contains('do something private')));
  });

  test('rotates Worker logs by both size and retained file count', () async {
    final logDirectory = Directory('${temporary.path}/logs');
    final store = WorkerDiagnosticStore(
      directory: logDirectory,
      maxFileBytes: 700,
      maxFiles: 2,
    );
    for (var index = 0; index < 12; index++) {
      await store.record(
        workerTypeId: 'gemini',
        workerVersion: '2.0.0',
        protocolStage: 'execute',
        event: 'assignment.progress',
        runId: 'run-$index',
        context: {'assignmentId': 'run-$index'},
      );
    }

    final files =
        await logDirectory.list().where((entity) => entity is File).toList();
    expect(files, hasLength(2));
    for (final file in files.cast<File>()) {
      expect(await file.length(), lessThanOrEqualTo(700));
    }
    final report = await store.createCopyableReport();
    expect(report, contains('run-11'));
    expect(report, isNot(contains('run-0"')));
  });

  test('copyable report ignores an incomplete crash-tail record', () async {
    final store = WorkerDiagnosticStore(
      directory: Directory('${temporary.path}/logs'),
    );
    await store.record(
      workerTypeId: 'test',
      workerVersion: '0.1.0',
      protocolStage: 'execute',
      event: 'assignment.failed',
      errorCode: 'worker_internal_failure',
      processExitCode: 9,
    );
    await store.currentFile.writeAsString('{truncated', mode: FileMode.append);
    await store.record(
      workerTypeId: 'test',
      workerVersion: '0.1.0',
      protocolStage: 'process_start',
      event: 'process.restarted',
    );

    final report = await store.createCopyableReport();
    expect(report, contains('worker_internal_failure'));
    expect(report, contains('process.restarted'));
    expect(report, contains('processExitCode'));
    expect(report, isNot(contains('{truncated')));
  });
}

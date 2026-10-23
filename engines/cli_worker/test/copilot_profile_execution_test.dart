import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Replays GitHub Copilot CLI 1.0.103 `--output-format json` events captured
/// on a real install (trimmed to the fields the Profile reads).
const _sessionId = 'd5538f5f-d90d-4ae1-846d-f1580406c356';

List<Map<String, Object?>> _events({required int exitCode}) => [
  {
    'type': 'session.tools_updated',
    'data': {'model': 'claude-haiku-4.5'},
    'ephemeral': true,
  },
  {
    'type': 'assistant.turn_start',
    'data': {'turnId': '0'},
  },
  {
    'type': 'assistant.message_delta',
    'data': {'messageId': 'm1', 'deltaContent': 'Checking'},
    'ephemeral': true,
  },
  {
    'type': 'assistant.message',
    'data': {
      'messageId': 'm1',
      'model': 'claude-haiku-4.5',
      'content': 'Checking the project.',
      'toolRequests': [
        {'name': 'view'},
      ],
    },
  },
  {
    'type': 'tool.execution_start',
    'data': {
      'toolCallId': 'call_view',
      'toolName': 'view',
      'arguments': {'path': '/work/README.md'},
    },
  },
  {
    'type': 'tool.execution_complete',
    'data': {'toolCallId': 'call_view', 'success': true},
  },
  {
    'type': 'tool.execution_start',
    'data': {
      'toolCallId': 'call_bash',
      'toolName': 'bash',
      'arguments': {'command': 'false'},
    },
  },
  {
    'type': 'tool.execution_complete',
    'data': {'toolCallId': 'call_bash', 'success': false},
  },
  {
    'type': 'assistant.message',
    'data': {
      'messageId': 'm2',
      'model': 'claude-haiku-4.5',
      'content': 'OK',
      'toolRequests': <Object?>[],
    },
  },
  {
    'type': 'assistant.turn_end',
    'data': {'turnId': '0'},
  },
  if (exitCode != 0)
    {
      'type': 'session.error',
      'data': {
        'errorType': 'query',
        'message':
            "Execution failed: Reasoning effort 'medium' is not supported "
            "for model 'claude-haiku-4.5'.",
      },
    },
  {
    'type': 'result',
    'sessionId': _sessionId,
    'exitCode': exitCode,
    'usage': {'premiumRequests': 0.33},
  },
];

/// Copilot CLI 1.0.103 stderr for a bare `copilot --model` (exit code 2).
const _modelListError =
    "error: a value is required for '--model <model>' but none was supplied\n"
    '  [possible values: auto, claude-haiku-4.5, gpt-5.3-codex, kimi-k3]';

/// Copilot CLI 1.0.103 stderr when no login is available (exit code 1).
const _authError = 'Error: No authentication information found.';

void main() {
  // Exit code 2 stands for the logged-out case: stderr only, real exit 1.
  for (final exitCode in [0, 1, 2, 3]) {
    test('Copilot Profile interprets real CLI output (case $exitCode)', () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('copilot-profile-');
      final profile =
          jsonDecode(
                await File(
                  '$repository/apps/profile_lab/assets/profiles/copilot.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final providerPath = '${root.path}/provider.dart';
      final invocationPath = '${root.path}/invocation.json';
      final events = base64.encode(
        utf8.encode(jsonEncode(_events(exitCode: exitCode))),
      );
      await File(providerPath).writeAsString('''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('GitHub Copilot CLI 1.0.103.');
    return;
  }
  if (args.length == 1 && args.single == '--model') {
    stderr.writeln(${jsonEncode(_modelListError)});
    exitCode = 2;
    return;
  }
  final prompt = await stdin.transform(utf8.decoder).join();
  File(${jsonEncode(invocationPath)}).writeAsStringSync(
    jsonEncode({'args': args, 'stdin': prompt}),
  );
  if ($exitCode == 2) {
    stderr.writeln(${"'$_authError'"});
    exitCode = 1;
    return;
  }
  if ($exitCode == 3) {
    stderr.writeln('Error: Model "gpt-5.3-codex" from --model flag is not available.');
    exitCode = 1;
    return;
  }
  for (final event in jsonDecode(utf8.decode(base64Decode('$events'))) as List) {
    stdout.writeln(jsonEncode(event));
  }
  exitCode = $exitCode;
}
''');
      // Replace only executable resolution; keep the Profile's own arguments
      // after the fake provider path.
      final provider = profile['providerTool']! as Map<String, Object?>;
      provider['executableCandidates'] = ['dart'];
      (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
          <String>[];
      (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
        'run',
        providerPath,
        '--version',
      ];
      final execution = profile['execution']! as Map<String, Object?>;
      final discovery =
          (profile['model']! as Map<String, Object?>)['discovery']!
              as Map<String, Object?>;
      discovery['arguments'] = [
        'run',
        providerPath,
        ...discovery['arguments']! as List,
      ];
      execution['arguments'] = [
        'run',
        providerPath,
        ...execution['arguments']! as List,
      ];
      final bytes = utf8.encode(jsonEncode(profile));
      final profileFile = File('${root.path}/profile.json');
      await profileFile.writeAsBytes(bytes);
      final state = await Directory('${root.path}/state').create();
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '$repository/engines/cli_worker/bin/conclave_cli_worker.dart',
          '--profile',
          profileFile.path,
          '--engine-version',
          '1.0.0',
          '--state-directory',
          state.path,
        ],
        workingDirectory: repository,
        environment: {
          ...Platform.environment,
          'PATH':
              '${File(Platform.resolvedExecutable).parent.path}'
              '${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
        },
      );
      final lines = StreamIterator<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await root.delete(recursive: true);
      });
      process.stdin.writeln(
        InitializeRequest(
          requestId: 'copilot-init',
          workerTypeId: 'copilot',
          expectedEngineVersion: '1.0.0',
          profileDefinitionId: 'copilot-cli',
          profileReleaseVersion: '${profile['releaseVersion']}',
          profileDigest: sha256.convert(bytes).toString(),
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());
      process.stdin.writeln(
        ExecuteRequest(
          requestId: 'copilot-execute',
          assignmentId: 'copilot-assignment',
          prompt: 'Reply with exactly: OK',
          model: 'gpt-5.3-codex',
          reasoningEffort: 'xhigh',
          timeoutMs: 20000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ).encode(),
      );
      await process.stdin.flush();
      WorkerFrame? terminal;
      final activities = <WorkerActivity>[];
      while (await lines.moveNext().timeout(const Duration(seconds: 30))) {
        final frame = decodeWorkerFrame(lines.current);
        if (frame is WorkerActivity) activities.add(frame);
        if (frame is WorkerErrorFrame || frame is WorkerResult) {
          terminal = frame;
          break;
        }
      }
      if (exitCode == 0) {
        expect(terminal, isA<WorkerResult>());
        expect((terminal as WorkerResult).output, 'OK');
      } else {
        expect(terminal, isA<WorkerErrorFrame>());
        if (exitCode == 2) {
          expect(
            (terminal as WorkerErrorFrame).code,
            'provider_authentication_required',
          );
        }
        if (exitCode == 3) {
          expect((terminal as WorkerErrorFrame).code, 'model_not_supported');
        }
      }
      // Cases 2 and 3 fail before Copilot emits any events.
      if (exitCode < 2) {
        final tools = activities
            .where((activity) => activity.eventType.startsWith('tool.'))
            .map((activity) => '${activity.eventType}:${activity.activityId}')
            .toList();
        expect(tools, [
          'tool.started:call_view',
          'tool.completed:call_view',
          'tool.started:call_bash',
          'tool.failed:call_bash',
        ]);
        expect(
          activities.map((activity) => activity.eventType),
          containsAll(['model.started', 'message.updated']),
        );
        expect(
          activities
                  .firstWhere((a) => a.eventType == 'tool.started')
                  .toolName ??
              activities
                  .firstWhere((a) => a.eventType == 'tool.started')
                  .details?['toolName'],
          'view',
        );
      }
      final invocation =
          jsonDecode(await File(invocationPath).readAsString())
              as Map<String, Object?>;
      final args = (invocation['args']! as List).cast<String>();
      expect(invocation['stdin'], 'Reply with exactly: OK');
      expect(args, isNot(contains('-p')));
      expect(args, containsAllInOrder(['--model', 'gpt-5.3-codex']));
      expect(args, containsAllInOrder(['--reasoning-effort', 'xhigh']));
      expect(args, containsAllInOrder(['--output-format', 'json']));
      expect(args, containsAllInOrder(['--stream', 'off']));
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    });
  }
}

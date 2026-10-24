import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_engine/src/engine_session_store.dart';
import 'package:conclave_cli_worker_engine/src/model_discovery.dart';
import 'package:conclave_cli_worker_engine/src/provider_activity_adapter.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Grok Build 1.0.67 `--output-format streaming-json` captured on a real
/// install (tool catalog, signatures and raw tool output removed). The model
/// says "checking", reads a file, runs a command, writes a file, and answers
/// "hello".
const _fixture = 'test/fixtures/grok-streaming-tools-1.0.67.jsonl';
const _sessionId = '01a16ab7-c68a-72d2-90da-bdbbfc983ea4';

/// `grok models` output from the same install, plus one extra model line.
const _modelsOutput = '''
You are logged in with grok.com.

Default model: grok-4.7

Available models:
  * grok-4.7 (default)
  grok-4.6
''';

Future<
  ({
    WorkerFrame? terminal,
    List<WorkerActivity> activities,
    Map invocation,
    DiscoveredModelCatalog? catalog,
  })
>
_execute({required String events, required int exitCode}) async {
  final repository = Directory.current.parent.parent.path;
  final root = await Directory.systemTemp.createTemp('grok-profile-');
  addTearDown(() => root.delete(recursive: true));
  final profile =
      jsonDecode(
            await File(
              '$repository/apps/profile_lab/assets/profiles/grok.json',
            ).readAsString(),
          )
          as Map<String, Object?>;
  final providerPath = '${root.path}/provider.dart';
  final invocationPath = '${root.path}/invocation.json';
  await File(providerPath).writeAsString('''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('grok 1.0.67 (2fe064390d07) [stable]');
    return;
  }
  if (args.contains('models')) {
    stdout.write(utf8.decode(base64Decode('${base64.encode(utf8.encode(_modelsOutput))}')));
    return;
  }
  if (args.contains('conclave-effort-probe')) {
    // Grok Build 1.0.67 wording: the account's catalog lists grok-4.7 only.
    final model = args[args.indexOf('--model') + 1];
    final reason = model == 'grok-4.7'
        ? "; use one of: xhigh, high, medium, low"
        : " (\$model isn't in the model catalog)";
    stderr.writeln(
        "Error: --effort/--reasoning-effort: unknown effort level "
        "'conclave-effort-probe'\$reason");
    exitCode = 1;
    return;
  }
  final prompt = await stdin.transform(utf8.decoder).join();
  File(${jsonEncode(invocationPath)}).writeAsStringSync(
    jsonEncode({'args': args, 'stdin': prompt}),
  );
  stdout.write(utf8.decode(base64Decode('${base64.encode(utf8.encode(events))}')));
  exitCode = $exitCode;
}
''');
  final provider = profile['providerTool']! as Map<String, Object?>;
  provider['executableCandidates'] = ['dart'];
  (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
      <String>[];
  (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
    'run',
    providerPath,
    '--version',
  ];
  final discovery =
      (profile['model']! as Map<String, Object?>)['discovery']!
          as Map<String, Object?>;
  discovery['arguments'] = [
    'run',
    providerPath,
    ...discovery['arguments']! as List,
  ];
  final effortProbe = discovery['effortProbe']! as Map<String, Object?>;
  effortProbe['arguments'] = [
    'run',
    providerPath,
    ...effortProbe['arguments']! as List,
  ];
  final execution = profile['execution']! as Map<String, Object?>;
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
  });
  process.stdin.writeln(
    InitializeRequest(
      requestId: 'grok-init',
      workerTypeId: 'grok',
      expectedEngineVersion: '1.0.0',
      profileDefinitionId: 'grok-cli',
      profileReleaseVersion: '${profile['releaseVersion']}',
      profileDigest: sha256.convert(bytes).toString(),
    ).encode(),
  );
  await process.stdin.flush();
  expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
  expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());
  process.stdin.writeln(
    ProbeRequest(
      requestId: 'grok-probe',
      mode: WorkerProbeMode.passive,
    ).encode(),
  );
  await process.stdin.flush();
  expect(await lines.moveNext().timeout(const Duration(seconds: 60)), isTrue);
  final catalog =
      (decodeWorkerFrame(lines.current) as ProbeResult).modelCatalog;
  process.stdin.writeln(
    ExecuteRequest(
      requestId: 'grok-execute',
      assignmentId: 'grok-assignment',
      prompt: 'Read a.txt and reply with its content',
      model: 'grok-4.7',
      reasoningEffort: 'high',
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
  await process.stdin.close();
  if (terminal is WorkerErrorFrame && !File(invocationPath).existsSync()) {
    fail('Engine stopped before the provider ran: ${terminal.encode()}');
  }
  final invocation =
      jsonDecode(await File(invocationPath).readAsString()) as Map;
  return (
    terminal: terminal,
    activities: activities,
    invocation: invocation,
    catalog: catalog,
  );
}

void main() {
  test('Grok Profile answers with the text after the last tool call', () async {
    final run = await _execute(
      events: await File(_fixture).readAsString(),
      exitCode: 0,
    );
    expect(run.terminal, isA<WorkerResult>());
    expect((run.terminal as WorkerResult).output, 'hello');
    final args = (run.invocation['args']! as List).cast<String>();
    // The prompt travels on stdin (`-p -`), not argv, so long Threads are
    // bounded by the 1 MiB stdin limit instead of the argv limit.
    expect(run.invocation['stdin'], 'Read a.txt and reply with its content');
    expect(args, containsAllInOrder(['-p', '-']));
    expect(args, isNot(contains('Read a.txt and reply with its content')));
    expect(args, containsAllInOrder(['--output-format', 'streaming-json']));
    expect(args, containsAllInOrder(['--model', 'grok-4.7']));
    expect(args, containsAllInOrder(['--reasoning-effort', 'high']));
    expect(
      args,
      containsAllInOrder([
        '--sandbox',
        'workspace',
        '--permission-mode',
        'dontAsk',
      ]),
    );
    final tools = run.activities
        .where((activity) => activity.eventType.startsWith('tool.'))
        .map((activity) => '${activity.eventType}:${activity.title}')
        .toList();
    expect(tools, [
      'tool.started:Reading files',
      'tool.started:Running a command',
      'tool.started:Editing files',
      'tool.completed:Read files',
      'tool.completed:Edited files',
      'tool.completed:Ran a command',
    ]);
    expect(
      run.activities.map((activity) => activity.eventType),
      containsAll(['model.status', 'message.updated']),
    );
  });

  test('Grok Profile fails on the provider error event', () async {
    final run = await _execute(
      events:
          '${jsonEncode({'type': 'error', 'message': "Couldn't set model 'nope': Invalid params", 'cwd': '/work'})}\n',
      exitCode: 1,
    );
    expect(run.terminal, isA<WorkerErrorFrame>());
  });

  test(
    'Grok Profile classifies usage limit error event as quota_exhausted',
    () async {
      final run = await _execute(
        events:
            '${jsonEncode({'type': 'error', 'message': "You've reached your free Grok Build usage limit for now. Get SuperGrok for much higher limits, or try again later…", 'cwd': '/work'})}\n',
        exitCode: 1,
      );
      expect(run.terminal, isA<WorkerErrorFrame>());
      final terminal = run.terminal as WorkerErrorFrame;
      expect(terminal.code, WorkerIssueCode.quotaExhausted);
      expect(terminal.message, "The provider's usage limit has been reached.");
    },
  );

  test(
    'Grok Profile classifies free-usage-exhausted 429 as quota_exhausted',
    () async {
      final run = await _execute(
        events:
            '${jsonEncode({'type': 'error', 'message': "API error (status 429 Too Many Requests): subscription:free-usage-exhausted: You've used all the included free usage for model grok-4.7 for now. Usage resets over a rolling 24-hour window.", 'cwd': '/work'})}\n',
        exitCode: 1,
      );
      final terminal = run.terminal as WorkerErrorFrame;
      expect(terminal.code, WorkerIssueCode.quotaExhausted);
    },
  );

  test('Grok adapter keeps narration and tool rows apart', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Grok Build CLI'},
      'activity': {'adapter': 'grok-streaming-json', 'mappings': <Object?>[]},
    })!;
    final observations = <ProviderActivityObservation>[];
    for (final line in File(_fixture).readAsLinesSync()) {
      observations.addAll(
        adapter.normalizeLine(line, declarativeMatched: false),
      );
    }
    final messages = observations
        .where((o) => o.type == 'message.updated')
        .map((o) => '${o.activityId}:${o.details['preview']}')
        .toList();
    expect(messages, ['grok-msg-0:checking', 'grok-msg-3:hello']);
    final started = observations.firstWhere((o) => o.type == 'tool.started');
    expect(started.activityId, 'call-32a54325-d1ec-4a29-bfb7-4a60b4847a37-0');
    expect(started.details['summary'], 'a.txt');
    expect(observations.where((o) => o.details['diagnostic'] != null), isEmpty);
  });

  test('use-one-of effort lists are read lowest first', () {
    expect(
      parseUseOneOfEfforts(
        "Error: --effort/--reasoning-effort: unknown effort level 'x'; "
        'use one of: xhigh, high, medium, low',
      ),
      ['low', 'medium', 'high', 'xhigh'],
    );
    expect(
      parseUseOneOfEfforts(
        "unknown effort level 'x' (grok-4.6 isn't in the model catalog)",
      ),
      isEmpty,
    );
    expect(parseUseOneOfEfforts('use one of: fast, think'), ['fast', 'think']);
  });

  test('indented model lists read bullets and default markers', () {
    final models = parseIndentedModelList(
      _modelsOutput,
      '',
      catalog: [
        {
          'id': 'grok-4.7',
          'name': 'Grok 4.7',
          'supportedReasoningEfforts': ['low', 'high'],
        },
      ],
      defaultEfforts: ['low', 'medium', 'high', 'xhigh'],
    );
    expect(models.map((m) => m.id), ['grok-4.7', 'grok-4.6']);
    expect(models.first.name, 'Grok 4.7');
    expect(models.first.supportedReasoningEfforts, ['low', 'high']);
    expect(models.last.supportedReasoningEfforts, [
      'low',
      'medium',
      'high',
      'xhigh',
    ]);
    expect(
      () => parseIndentedModelList('No models\n', ''),
      throwsFormatException,
    );
  });

  group('execution-policy-bound sessions', () {
    late Directory directory;
    late EngineSessionStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('grok-sessions-');
      store = EngineSessionStore(directory);
      await store.write(
        sessionKey: 'thread-1',
        workerTypeId: 'grok',
        profileDefinitionId: 'grok-cli',
        providerToolIdentity: 'Grok Build CLI',
        profileReleaseVersion: 2,
        sessionFormatId: 'grok-session-v1',
        sessionId: _sessionId,
        executionPolicy: 'provider_default',
      );
    });
    tearDown(() => directory.delete(recursive: true));

    Future<String?> read(
      String policy, {
      bool bound = true,
      bool rebuild = true,
    }) => store.read(
      sessionKey: 'thread-1',
      workerTypeId: 'grok',
      profileDefinitionId: 'grok-cli',
      providerToolIdentity: 'Grok Build CLI',
      compatibleFormatIds: const ['grok-session-v1'],
      executionPolicy: policy,
      executionPolicyBound: bound,
      allowModelReconstruction: rebuild,
    );

    test('resume under the same policy', () async {
      expect(await read('provider_default'), _sessionId);
    });

    test('start fresh from the bootstrap when the policy changes', () async {
      expect(await read('restricted'), isNull);
    });

    test('fail without a bootstrap to rebuild from', () async {
      await expectLater(
        read('restricted', rebuild: false),
        throwsFormatException,
      );
    });

    test('unbound Profiles keep resuming across policies', () async {
      expect(await read('restricted', bound: false), _sessionId);
    });
  });
}

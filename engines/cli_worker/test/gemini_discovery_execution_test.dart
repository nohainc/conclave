import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Gemini discovery, exact selection, refresh, model errors and read-only admission',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('gemini-discovery-');
      final provider = File('${root.path}/provider.dart');
      final models = File('${root.path}/models.tsv');
      await models.writeAsString(
        'gemini-fixture-high\tGemini Fixture (High)\tlow,high\thigh\nclaude-fixture\tClaude\n',
      );
      await provider.writeAsString('''
import 'dart:io';
import 'dart:convert';
Future<void> main(List<String> args) async {
  if(args.contains('--version')) { stdout.writeln('1.2.16'); return; }
  if(args.contains('models')) { stdout.write(await File(r'${models.path}').readAsString()); return; }
  final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final prompt = (input['message'] as Map)['content'];
  final modelIndex = args.indexOf('--model');
  final model = modelIndex < 0 ? 'default' : args[modelIndex+1];
  if(prompt == 'reject-model') {
    stdout.writeln(jsonEncode({'event':'result','result':{'status':'ERROR','error':'invalid model selection: model not available'}}));
    exitCode=1; return;
  }
  stdout.writeln(jsonEncode({'event':'init','conversation_id':'fixture-session'}));
  stdout.writeln(jsonEncode({'event':'step_update','step_update':{'state':'ACTIVE','step_type':'agent_response'}}));
  stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','conversation_id':'fixture-session','response':prompt.toString().contains('exactly the word OK') ? 'OK' : model}}));
}
''');
      final profile =
          jsonDecode(
                await File(
                  '$repository/packages/tool-profile/test/fixtures/gemini-antigravity.v2.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final tool = profile['providerTool'] as Map;
      tool['executableCandidates'] = ['dart'];
      (tool['discovery'] as Map)['standardLocations'] = <String>[];
      (tool['versionProbe'] as Map)['arguments'] = [
        'run',
        provider.path,
        '--version',
      ];
      (profile['model'] as Map)['discovery']['arguments'] = [
        'run',
        provider.path,
        'models',
      ];
      final execution = profile['execution'] as Map;
      execution['arguments'] = [
        'run',
        provider.path,
        ...execution['arguments'] as List,
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
          '1.1.0',
          '--state-directory',
          state.path,
        ],
        workingDirectory: repository,
        environment: {
          ...Platform.environment,
          'PATH':
              '${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH'] ?? ''}',
        },
      );
      final errors = StringBuffer();
      process.stderr.transform(utf8.decoder).listen(errors.write);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await root.delete(recursive: true);
      });
      Future<WorkerFrame> exchange(WorkerFrame request) async {
        process.stdin.writeln(request.encode());
        await process.stdin.flush();
        while (await lines.moveNext().timeout(const Duration(seconds: 20))) {
          final frame = decodeWorkerFrame(lines.current);
          if (frame.requestId == request.requestId && frame is! WorkerProgress)
            return frame;
        }
        throw StateError('No response: $errors');
      }

      expect(
        await exchange(
          InitializeRequest(
            requestId: 'init',
            workerTypeId: 'gemini',
            expectedEngineVersion: '1.1.0',
            profileDefinitionId: 'gemini-antigravity',
            profileReleaseVersion: '2',
            profileDigest: sha256.convert(bytes).toString(),
          ),
        ),
        isA<InitializeResult>(),
      );
      final passive =
          await exchange(
                ProbeRequest(requestId: 'probe', mode: WorkerProbeMode.passive),
              )
              as ProbeResult;
      expect(passive.ready, isTrue, reason: '${passive.toJson()} $errors');
      expect(passive.modelCatalog!.models.single.id, 'gemini-fixture-high');
      expect(passive.modelCatalog!.models.single.status, 'listed');
      expect(passive.modelCatalog!.models.single.supportedReasoningEfforts, [
        'low',
        'high',
      ]);
      expect(
        passive.modelCatalog!.models.single.defaultReasoningEffort,
        'high',
      );
      final live =
          await exchange(
                ProbeRequest(requestId: 'live', mode: WorkerProbeMode.live),
              )
              as ProbeResult;
      expect(live.ready, isTrue, reason: '${live.toJson()} $errors');
      final result = await exchange(
        ExecuteRequest(
          sessionPolicy: WorkerSessionPolicy.stateless,
          requestId: 'execute',
          assignmentId: 'assignment',
          prompt: 'echo',
          model: 'gemini-fixture-high',
          timeoutMs: 10000,
        ),
      );
      expect(result, isA<WorkerResult>(), reason: '${result.toJson()} $errors');
      expect((result as WorkerResult).output, 'gemini-fixture-high');
      final verified =
          await exchange(
                ProbeRequest(
                  requestId: 'verified',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(verified.modelCatalog!.models.single.status, 'verified');
      final rejected = await exchange(
        ExecuteRequest(
          sessionPolicy: WorkerSessionPolicy.stateless,
          requestId: 'reject',
          assignmentId: 'assignment-reject',
          prompt: 'reject-model',
          model: 'gemini-fixture-high',
          timeoutMs: 10000,
        ),
      );
      expect(
        (rejected as WorkerErrorFrame).code,
        WorkerIssueCode.modelNotSupported,
      );
      final invalidEffort = await exchange(
        ExecuteRequest(
          sessionPolicy: WorkerSessionPolicy.stateless,
          requestId: 'invalid-effort',
          assignmentId: 'assignment-invalid-effort',
          prompt: 'echo',
          model: 'gemini-fixture-high',
          reasoningEffort: 'max',
          timeoutMs: 10000,
        ),
      );
      expect(
        (invalidEffort as WorkerErrorFrame).code,
        WorkerIssueCode.modelNotSupported,
      );
      final unavailable =
          await exchange(
                ProbeRequest(
                  requestId: 'unavailable',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(unavailable.modelCatalog!.models.single.status, 'unavailable');
      await models.writeAsString('malformed');
      final failedRefresh =
          await exchange(
                ProbeRequest(
                  requestId: 'failed-refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(failedRefresh.ready, isTrue);
      expect(
        failedRefresh.modelCatalog!.models.single.id,
        'gemini-fixture-high',
      );
      expect(
        failedRefresh.checks.any(
          (c) =>
              c.code == 'model_discovery' &&
              c.status == ProbeCheckStatus.warning,
        ),
        isTrue,
      );
      await models.writeAsString('gemini-new-low\tGemini New (Low)\n');
      final refreshed =
          await exchange(
                ProbeRequest(
                  requestId: 'refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(refreshed.modelCatalog!.models.single.id, 'gemini-new-low');
      final removed = await exchange(
        ExecuteRequest(
          sessionPolicy: WorkerSessionPolicy.stateless,
          requestId: 'removed',
          assignmentId: 'assignment-removed',
          prompt: 'echo',
          model: 'gemini-fixture-high',
          timeoutMs: 10000,
        ),
      );
      expect(
        (removed as WorkerErrorFrame).code,
        WorkerIssueCode.modelNotSupported,
      );
      final readOnly = await exchange(
        ExecuteRequest(
          sessionPolicy: WorkerSessionPolicy.stateless,
          requestId: 'readonly',
          assignmentId: 'assignment-readonly',
          prompt: 'write',
          timeoutMs: 10000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(readOnly, isA<WorkerResult>());
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'all combined Gemini pairs invoke exact native slugs without separate effort',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('native-model-');
      final provider = File('${root.path}/provider.dart');
      await provider.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (args.contains('--version')) { stdout.writeln('1.3.3'); return; }
  if (args.contains('models')) {
    if (File('${Platform.script.toFilePath()}.offline').existsSync()) { stderr.writeln('temporary discovery failure'); exit(2); }
    for (final version in ['3.8','3.7','3.6','3.1']) {
      for (final effort in version == '3.1' ? ['low','high'] : ['low','medium','high']) {
        stdout.writeln('gemini-$version-${version == '3.1' ? 'pro' : 'flash'}-$effort\tGemini $version $effort');
      }
    }
    return;
  }
  final input = await stdin.transform(utf8.decoder).join();
  if (input.contains("reject-model")) { stderr.writeln("unsupported model"); exit(2); }
  final model = args[args.indexOf('--model') + 1];
  stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response':'$model|${args.contains('--effort')}','conversation_id':'fixture'}}));
}
''');
      final profile =
          jsonDecode(
                await File(
                  '$repository/docs/profile-templates/gemini-antigravity-runtime-catalog.v1.json',
                ).readAsString(),
              )
              as Map;
      final tool = profile['providerTool'] as Map;
      tool['executableCandidates'] = ['dart'];
      (tool['discovery'] as Map)['standardLocations'] = <String>[];
      (tool['versionProbe'] as Map)['arguments'] = [
        'run',
        provider.path,
        '--version',
      ];
      (profile['probe'] as Map)['passive'] = {'checks': [], 'configChecks': []};
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
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '$repository/engines/cli_worker/bin/conclave_cli_worker.dart',
          '--profile',
          profileFile.path,
          '--engine-version',
          '1.2.0',
          '--state-directory',
          '${root.path}/state',
        ],
        workingDirectory: repository,
        environment: {
          ...Platform.environment,
          'PATH':
              '${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH'] ?? ''}',
        },
      );
      final stderrDrain = process.stderr.drain<void>();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await stderrDrain;
        await root.delete(recursive: true);
      });
      Future<WorkerFrame> exchange(WorkerFrame request) async {
        process.stdin.writeln(request.encode());
        await process.stdin.flush();
        while (await lines.moveNext().timeout(const Duration(seconds: 20))) {
          final response = decodeWorkerFrame(lines.current);
          if (response.requestId == request.requestId &&
              response is! WorkerProgress)
            return response;
        }
        throw StateError('No response');
      }

      expect(
        await exchange(
          InitializeRequest(
            requestId: 'init',
            workerTypeId: 'gemini',
            expectedEngineVersion: '1.2.0',
            profileDefinitionId: 'gemini-antigravity',
            profileReleaseVersion: '1',
            profileDigest: sha256.convert(bytes).toString(),
          ),
        ),
        isA<InitializeResult>(),
      );
      final probe =
          await exchange(
                ProbeRequest(requestId: 'probe', mode: WorkerProbeMode.passive),
              )
              as ProbeResult;
      expect(probe.modelCatalog!.schemaVersion, 2);

      expect(probe.modelCatalog!.models.length, 4);
      final changedCatalog = await exchange(
        ExecuteRequest(
          requestId: 'changed-catalog',
          assignmentId: 'assignment',
          prompt: 'echo',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'high',
          catalogRevision: 'b' * 64,
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
        ),
      );
      expect(changedCatalog, isA<WorkerErrorFrame>());
      expect(
        (changedCatalog as WorkerErrorFrame).message,
        contains('catalog changed'),
      );
      for (final model in probe.modelCatalog!.models) {
        final missing = await exchange(
          ExecuteRequest(
            requestId: 'missing-${model.id}',
            assignmentId: 'assignment',
            prompt: 'echo',
            model: model.id,
            sessionPolicy: WorkerSessionPolicy.stateless,
            timeoutMs: 10000,
            executionPolicy: WorkerExecutionPolicy.providerDefault,
          ),
        );
        expect(missing, isA<WorkerErrorFrame>());
        for (final effort in model.supportedReasoningEfforts) {
          final result = await exchange(
            ExecuteRequest(
              requestId: '${model.id}-$effort',
              assignmentId: 'assignment',
              prompt: 'echo',
              model: model.id,
              reasoningEffort: effort,
              sessionPolicy: WorkerSessionPolicy.stateless,
              timeoutMs: 10000,
              executionPolicy: WorkerExecutionPolicy.providerDefault,
            ),
          );
          expect(result, isA<WorkerResult>());
          expect((result as WorkerResult).output, '${model.id}-$effort|false');
          final invocationKey = sha256
              .convert(utf8.encode('${model.id}-$effort'))
              .toString();
          final audit =
              jsonDecode(
                    await File(
                      '${root.path}/state/execution-selections/$invocationKey.json',
                    ).readAsString(),
                  )
                  as Map;
          expect(audit['modelId'], model.id);
          expect(audit['effort'], effort);
          expect(audit['resolvedNativeModelId'], '${model.id}-$effort');
          expect(audit['profileDigest'], sha256.convert(bytes).toString());
          expect(audit['catalogRevision'], matches(RegExp(r'^[a-f0-9]{64}$')));
          final observation =
              jsonDecode(
                    await File(
                      '${root.path}/state/execution-selections/$invocationKey.completion.json',
                    ).readAsString(),
                  )
                  as Map;
          expect(observation['acceptedModelId'], isNull);
          expect(observation['selectionObservation'], 'unavailable');
        }
      }
      final rejected = await exchange(
        ExecuteRequest(
          requestId: 'reject',
          assignmentId: 'assignment',
          prompt: 'reject-model',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'high',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(rejected, isA<WorkerErrorFrame>());
      final refreshed =
          await exchange(
                ProbeRequest(
                  requestId: 'refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      final family = refreshed.modelCatalog!.models.firstWhere(
        (m) => m.id == 'gemini-3.8-flash',
      );
      expect(family.status, 'verified');
      expect(family.supportedReasoningEfforts, ['low', 'medium']);
      expect(family.variantStatuses['high'], 'unavailable');
      expect(
        family
            .toJson(schemaVersion: 2, includeNativeId: false)
            .containsKey('variantStatuses'),
        isFalse,
      );
      final offline = File('${provider.path}.offline');
      await offline.writeAsString('offline');
      final staleProbe =
          await exchange(
                ProbeRequest(
                  requestId: 'stale-refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(staleProbe.modelCatalog!.stale, isTrue);
      expect(
        staleProbe.modelCatalog!.catalogRevision,
        refreshed.modelCatalog!.catalogRevision,
      );
      await offline.delete();
      final recovery =
          await exchange(
                ProbeRequest(
                  requestId: 'recovered-refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(recovery.modelCatalog!.stale, isFalse);
      expect(
        recovery.modelCatalog!.catalogRevision,
        staleProbe.modelCatalog!.catalogRevision,
      );
    },
  );
}

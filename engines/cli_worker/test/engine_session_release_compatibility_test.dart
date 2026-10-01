import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'durable sessions resume only across declared Profile format compatibility',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp(
        'engine-session-release-compatibility-',
      );
      final stateDirectory = await Directory('${root.path}/state').create();
      final providerHome = await Directory(
        '${root.path}/provider-home',
      ).create();
      addTearDown(() => root.delete(recursive: true));

      Future<WorkerResult> executeRelease({
        required int releaseVersion,
        required String sessionFormatId,
        required List<String> compatibleFormatIds,
        required String requestId,
        required String prompt,
      }) async {
        final profile =
            jsonDecode(
                  await File(
                    '$repository/packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
                  ).readAsString(),
                )
                as Map<String, Object?>;
        profile['releaseVersion'] = releaseVersion;
        final session = profile['session']! as Map<String, Object?>;
        session['formatId'] = sessionFormatId;
        session['compatibleFormatIds'] = compatibleFormatIds;
        final provider = profile['providerTool']! as Map<String, Object?>;
        const providerScript =
            'workers/fixture_cli/tool/antigravity_profile_provider.dart';
        provider['executableCandidates'] = ['dart'];
        (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
            <String>[];
        (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
          'run',
          providerScript,
          '--version',
        ];
        provider['supportedVersions'] = [
          {'min': '0.0.0', 'maxExclusive': '2.0.0'},
        ];
        final execution = profile['execution']! as Map<String, Object?>;
        execution['arguments'] = [
          'run',
          providerScript,
          ...(execution['arguments']! as List<Object?>),
        ];
        final profileBytes = utf8.encode(jsonEncode(profile));
        final profileFile = File('${root.path}/profile-$releaseVersion.json')
          ..writeAsBytesSync(profileBytes);
        final process = await Process.start(
          Platform.resolvedExecutable,
          [
            '$repository/engines/cli_worker/bin/conclave_cli_worker.dart',
            '--profile',
            profileFile.path,
            '--engine-version',
            '1.0.0',
            '--state-directory',
            stateDirectory.path,
          ],
          workingDirectory: repository,
          environment: {
            ...Platform.environment,
            'PATH':
                '${File(Platform.resolvedExecutable).parent.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
            'HOME': providerHome.path,
            'USERPROFILE': providerHome.path,
            'ProgramFiles': root.path,
            'TMP': root.path,
            'TEMP': root.path,
            'TMPDIR': root.path,
            'LANG': 'en_US.UTF-8',
            'LC_ALL': 'en_US.UTF-8',
            'SSL_CERT_FILE': '${root.path}/ca.pem',
            'SSL_CERT_DIR': '${root.path}/certs',
            'AGY_ADC_AUTH': 'agy-fixture-adc',
            'GEMINI_API_KEY': 'gemini-fixture-key',
            'GOOGLE_API_KEY': 'google-fixture-key',
            'GOOGLE_APPLICATION_CREDENTIALS': '/fixture/credentials.json',
            'GOOGLE_CLOUD_PROJECT': 'fixture-project',
            'GOOGLE_CLOUD_LOCATION': 'fixture-region',
            'GOOGLE_GEMINI_BASE_URL': 'https://fixture.invalid',
          },
          runInShell: false,
        );
        final lines = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        final engineStderr = StringBuffer();
        final stderrTask = process.stderr
            .transform(utf8.decoder)
            .listen(engineStderr.write);

        Future<WorkerFrame> exchange(WorkerFrame request) async {
          process.stdin.writeln(request.encode());
          await process.stdin.flush();
          while (await lines.moveNext().timeout(const Duration(seconds: 35))) {
            final frame = decodeWorkerFrame(lines.current);
            if (frame.requestId == request.requestId &&
                (frame is InitializeResult ||
                    frame is WorkerResult ||
                    frame is WorkerErrorFrame)) {
              return frame;
            }
          }
          throw TimeoutException('Engine did not return ${request.requestId}');
        }

        try {
          final initialized = await exchange(
            InitializeRequest(
              requestId: '$requestId-init',
              workerTypeId: 'gemini',
              expectedEngineVersion: '1.0.0',
              profileDefinitionId: 'gemini-antigravity',
              profileReleaseVersion: '$releaseVersion',
              profileDigest: sha256.convert(profileBytes).toString(),
            ),
          );
          expect(initialized, isA<InitializeResult>());
          final result = await exchange(
            ExecuteRequest(
              requestId: requestId,
              assignmentId: requestId,
              prompt: prompt,
              timeoutMs: 10000,
              sessionPolicy: WorkerSessionPolicy.durableSession,
              sessionKey: 'direct-and-work-session',
            ),
          );
          expect(
            result,
            isA<WorkerResult>(),
            reason: '${result.toJson()} stderr=$engineStderr',
          );
          return result as WorkerResult;
        } finally {
          await process.stdin.close();
          await process.exitCode.timeout(const Duration(seconds: 10));
          await lines.cancel();
          await stderrTask.cancel();
        }
      }

      final first = await executeRelease(
        releaseVersion: 1,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: const ['antigravity-conversation-v1'],
        requestId: 'release-1-start',
        prompt: 'Start durable',
      );
      expect(first.output, 'Gemini answer');

      final compatible = await executeRelease(
        releaseVersion: 2,
        sessionFormatId: 'antigravity-conversation-v2',
        compatibleFormatIds: const [
          'antigravity-conversation-v1',
          'antigravity-conversation-v2',
        ],
        requestId: 'release-2-resume',
        prompt: 'Continue durable',
      );
      expect(compatible.output, 'Gemini answer');
      final compatibleStateFile = stateDirectory
          .listSync()
          .whereType<File>()
          .singleWhere(
            (file) => file.uri.pathSegments.last.startsWith('session-'),
          );
      final compatibleState =
          jsonDecode(await compatibleStateFile.readAsString()) as Map;
      expect(compatibleState['profileReleaseVersion'], 2);
      expect(compatibleState['sessionFormatId'], 'antigravity-conversation-v2');

      final incompatible = await executeRelease(
        releaseVersion: 3,
        sessionFormatId: 'antigravity-conversation-v3',
        compatibleFormatIds: const ['antigravity-conversation-v3'],
        requestId: 'release-3-fresh-session',
        prompt: 'Continue after incompatible upgrade',
      );
      expect(incompatible.output, 'Gemini answer');
      final sessionFiles = stateDirectory.listSync().whereType<File>().where(
        (file) => file.uri.pathSegments.last.startsWith('session-'),
      );
      expect(sessionFiles, hasLength(1));
      expect(
        jsonDecode(await sessionFiles.single.readAsString())['sessionId'],
        'fixture-conversation-3',
      );
    },
  );
}

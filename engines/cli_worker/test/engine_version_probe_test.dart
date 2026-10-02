import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  final repository = Directory.current.parent.parent;

  test('provider compatibility uses complete SemVer precedence', () {
    expect(semanticVersionInRange('1.2.3+build.4', '1.2.3', '2.0.0'), isTrue);
    expect(semanticVersionInRange('1.2.3-alpha.2', '1.2.3', '2.0.0'), isFalse);
    expect(semanticVersionInRange('1.9.0-rc.1', '1.2.3', '1.9.0'), isTrue);
    expect(semanticVersionInRange('1.9.0', '1.2.3', '1.9.0'), isFalse);
    expect(
      compareSemanticVersions('1.0.0-alpha.10', '1.0.0-alpha.2'),
      greaterThan(0),
    );
  });

  test(
    'probe returns the extracted version even when its range rejects it',
    () async {
      final profile =
          jsonDecode(
                await File(
                  '${repository.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final provider = profile['providerTool']! as Map<String, Object?>;
      provider['executableCandidates'] = ['dart'];
      provider['supportedVersions'] = [
        {'min': '99.0.0', 'maxExclusive': '100.0.0'},
      ];
      (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
          <String>[];
      (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
        'run',
        'workers/fixture_cli/tool/fixture_provider.dart',
        '--version',
      ];
      final passive =
          (profile['probe']! as Map<String, Object?>)['passive']!
              as Map<String, Object?>;
      passive['checks'] = [
        {
          'id': 'must-not-run',
          'arguments': ['--version'],
          'timeoutMs': 10000,
          'successExitCodes': [0],
          'failureIssueCode': WorkerIssueCode.providerFailure,
        },
      ];
      final profileBytes = utf8.encode(jsonEncode(profile));
      final temp = await Directory.systemTemp.createTemp(
        'engine-version-probe-',
      );
      final profileFile = File('${temp.path}/profile.json')
        ..writeAsBytesSync(profileBytes);
      final stateDirectory = await Directory('${temp.path}/state').create();
      final enginePath =
          '${repository.path}/engines/cli_worker/bin/conclave_cli_worker.dart';
      final dartDirectory = File(Platform.resolvedExecutable).parent.path;
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          enginePath,
          '--profile',
          profileFile.path,
          '--engine-version',
          '1.0.0',
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: repository.path,
        environment: {
          ...Platform.environment,
          'PATH':
              '$dartDirectory${Platform.isWindows ? ';' : ':'}'
              '${Platform.environment['PATH'] ?? ''}',
        },
        runInShell: false,
      );
      final lines = StreamIterator<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await temp.delete(recursive: true);
      });

      process.stdin.writeln(
        InitializeRequest(
          requestId: 'version-init',
          workerTypeId: 'fixture-worker',
          expectedEngineVersion: '1.0.0',
          profileDefinitionId: 'fixture-cli',
          profileReleaseVersion: '1',
          profileDigest: sha256.convert(profileBytes).toString(),
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());

      process.stdin.writeln(
        ProbeRequest(
          requestId: 'version-probe',
          mode: WorkerProbeMode.passive,
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 20)),
        isTrue,
      );
      final result = decodeWorkerFrame(lines.current) as ProbeResult;
      expect(result.ready, isFalse);
      expect(result.issueCode, WorkerIssueCode.unsupportedProviderToolVersion);
      expect(result.providerToolVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
      expect(
        result.checks.any((check) => check.code == 'must_not_run'),
        isFalse,
      );
    },
  );
}

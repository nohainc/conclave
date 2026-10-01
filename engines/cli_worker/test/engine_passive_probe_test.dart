import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Codex passive readiness checks login status without a model request',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp(
        'conclave-codex-passive-probe-',
      );
      final profile =
          jsonDecode(
                await File(
                  '$repository/packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final providerPath = '${root.path}/fake_provider.dart';
      final authFailurePath = '${root.path}/auth-failure';
      await File(providerPath).writeAsString('''
import 'dart:io';
void main(List<String> args) {
  File(Platform.environment['PROBE_LOG']!).writeAsStringSync(
    '\${args.join(' ')}\\n',
    mode: FileMode.append,
  );
  if (args.length == 1 && args.single == '--version') {
    stdout.writeln('0.180.0');
    return;
  }
  if (args.length == 2 && args[0] == 'login' && args[1] == 'status') {
    if (File(r'$authFailurePath').existsSync()) exitCode = 1;
    return;
  }
  stdout.writeln('This would be a model request.');
}
''');
      final environment = profile['environment']! as Map<String, Object?>;
      (environment['passthrough']! as List<Object?>).add('PROBE_LOG');
      final provider = profile['providerTool']! as Map<String, Object?>;
      provider['executableCandidates'] = ['dart'];
      (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
          <String>[];
      (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
        'run',
        providerPath,
        '--version',
      ];
      final passive =
          (profile['probe']! as Map<String, Object?>)['passive']!
              as Map<String, Object?>;
      passive['checks'] = [
        {
          'id': 'authentication',
          'arguments': ['run', providerPath, 'login', 'status'],
          'timeoutMs': 10000,
          'successExitCodes': [0],
          'failureIssueCode': 'provider_authentication_required',
        },
      ];
      final profileBytes = utf8.encode(jsonEncode(profile));
      final profileFile = File('${root.path}/profile.json')
        ..writeAsBytesSync(profileBytes);
      final stateDirectory = await Directory('${root.path}/state').create();
      final logPath = '${root.path}/provider.log';
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
              '${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH'] ?? ''}',
          'PROBE_LOG': logPath,
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
        await root.delete(recursive: true);
      });

      process.stdin.writeln(
        InitializeRequest(
          requestId: 'codex-passive-init',
          workerTypeId: 'chatgpt',
          expectedEngineVersion: '1.0.0',
          profileDefinitionId: 'chatgpt-codex',
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
          requestId: 'codex-passive-probe',
          mode: WorkerProbeMode.passive,
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 20)),
        isTrue,
      );
      final result = decodeWorkerFrame(lines.current) as ProbeResult;
      expect(result.ready, isTrue, reason: '${result.toJson()}');
      expect(result.issueCode, isNull);
      await File(authFailurePath).writeAsString('logged out');
      process.stdin.writeln(
        ProbeRequest(
          requestId: 'codex-passive-logged-out',
          mode: WorkerProbeMode.passive,
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 20)),
        isTrue,
      );
      final loggedOut = decodeWorkerFrame(lines.current) as ProbeResult;
      expect(loggedOut.ready, isFalse);
      expect(
        loggedOut.issueCode,
        WorkerIssueCode.providerAuthenticationRequired,
      );
      expect(await File(logPath).readAsLines(), [
        '--version',
        'login status',
        '--version',
        'login status',
      ]);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    },
  );

  test('Gemini passive readiness is bounded and never invokes a model', () async {
    final repository = Directory.current.parent.parent.path;
    final root = await Directory.systemTemp.createTemp(
      'conclave-passive-probe-',
    );
    final home = await Directory('${root.path}/home').create();
    final profile =
        jsonDecode(
              await File(
                '$repository/packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final providerPath = '${root.path}/fake_provider.dart';
    await File(providerPath).writeAsString('''
import 'dart:io';
void main(List<String> args) {
  File(Platform.environment['PROBE_LOG']!).writeAsStringSync(
    '\${args.join(' ')}\\n',
    mode: FileMode.append,
  );
  if (args.length == 1 && args.single == '--version') {
    stdout.writeln('1.2.14');
    return;
  }
  if (args.length == 2 && args[0] == 'login' && args[1] == 'status') return;
  stdout.writeln('This would be a model request.');
}
''');
    final logPath = '${root.path}/provider.log';
    final environment = profile['environment']! as Map<String, Object?>;
    (environment['passthrough']! as List<Object?>).add('PROBE_LOG');
    final provider = profile['providerTool']! as Map<String, Object?>;
    provider['executableCandidates'] = ['dart'];
    (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
        <String>[];
    (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
      'run',
      providerPath,
      '--version',
    ];
    final profileBytes = utf8.encode(jsonEncode(profile));
    final profileFile = File('${root.path}/profile.json')
      ..writeAsBytesSync(profileBytes);
    final stateDirectory = await Directory('${root.path}/state').create();
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
        'HOME': home.path,
        'PATH':
            '${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH'] ?? ''}',
        'PROBE_LOG': logPath,
      }..remove('GEMINI_API_KEY'),
      runInShell: false,
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
        requestId: 'passive-init',
        workerTypeId: 'gemini',
        expectedEngineVersion: '1.0.0',
        profileDefinitionId: 'gemini-antigravity',
        profileReleaseVersion: '1',
        profileDigest: sha256.convert(profileBytes).toString(),
      ).encode(),
    );
    await process.stdin.flush();
    expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());

    final settings = '${home.path}/.gemini/antigravity-cli/settings.json';
    Future<ProbeResult> probe(String requestId) async {
      process.stdin.writeln(
        ProbeRequest(
          requestId: requestId,
          mode: WorkerProbeMode.passive,
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 20)),
        isTrue,
      );
      return decodeWorkerFrame(lines.current) as ProbeResult;
    }

    final missingSettings = await probe('missing-settings');
    expect(missingSettings.ready, isTrue);
    expect(missingSettings.issueCode, isNull);
    expect(
      missingSettings.checks.any(
        (check) =>
            check.code == 'gemini_provider_config' &&
            check.status == ProbeCheckStatus.warning,
      ),
      isTrue,
    );

    await File(
      settings,
    ).create(recursive: true).then((file) => file.writeAsString('{}'));
    final noProviderOverride = await probe('no-provider-override');
    expect(noProviderOverride.ready, isTrue);
    expect(noProviderOverride.issueCode, isNull);

    await File(settings).writeAsString('{"modelProvider":"other"}');
    final unsupportedProvider = await probe('unsupported-provider');
    expect(unsupportedProvider.ready, isFalse);
    expect(unsupportedProvider.issueCode, WorkerIssueCode.providerFailure);

    await File(settings).writeAsString('{"modelProvider":"gemini"}');
    final missingKey = await probe('missing-api-key');
    expect(missingKey.ready, isFalse);
    expect(
      missingKey.issueCode,
      WorkerIssueCode.providerAuthenticationRequired,
    );
    expect(await File(logPath).readAsLines(), [
      '--version',
      '--version',
      '--version',
      '--version',
    ]);
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
  });
}

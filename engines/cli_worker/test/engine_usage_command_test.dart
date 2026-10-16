import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Claude starter usage command returns the provider report verbatim',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('claude-usage-');
      final profile =
          jsonDecode(
                await File(
                  '$repository/apps/profile_lab/assets/profiles/claude.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final logPath = '${root.path}/calls.jsonl';
      final providerPath = '${root.path}/provider.dart';
      await File(providerPath).writeAsString('''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  File(r'$logPath').writeAsStringSync(
    jsonEncode(args) + '\\n', mode: FileMode.append,
  );
  stdout.writeln('\\u001b[1mCurrent session: 6% used\\u001b[0m');
  stdout.writeln('Current week (all models): 16% used');
}
''');
      // Replace only executable resolution/version transport; retain the
      // starter's model and probe declarations to catch unsupported discovery.
      final provider = profile['providerTool']! as Map<String, Object?>;
      provider['executableCandidates'] = ['dart'];
      (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
          <String>[];
      final usage = profile['usage']! as Map<String, Object?>;
      // The starter declares the real Claude arguments; run them through the
      // fixture provider while keeping the declared `-p /usage` suffix.
      expect(usage['arguments'], ['-p', '/usage']);
      usage['arguments'] = ['run', providerPath, '-p', '/usage'];
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
          requestId: 'claude-init',
          workerTypeId: 'claude',
          expectedEngineVersion: '1.0.0',
          profileDefinitionId: 'claude-code',
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
      process.stdin.writeln(UsageRequest(requestId: 'claude-usage').encode());
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 30)),
        isTrue,
      );
      final result = decodeWorkerFrame(lines.current) as UsageResult;
      expect(result.exitCode, 0);
      expect(
        result.output,
        'Current session: 6% used\nCurrent week (all models): 16% used\n',
      );
      expect(result.truncated, isFalse);
      expect(await File(logPath).readAsLines(), [
        jsonEncode(['-p', '/usage']),
      ]);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    },
  );
}

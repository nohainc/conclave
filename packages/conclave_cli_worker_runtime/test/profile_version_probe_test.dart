import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

void main() {
  final repository = Directory.current.parent.parent;

  Future<EngineProfile> loadProfile() async {
    final source = File(
      '${repository.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
    );
    final profile =
        jsonDecode(await source.readAsString()) as Map<String, Object?>;
    final provider = Map<String, Object?>.from(profile['providerTool']! as Map)
      ..['supportedVersions'] = [
        {'min': '1.2.3', 'maxExclusive': '1.3.0'},
      ];
    profile['providerTool'] = provider;
    return EngineProfile.parse(utf8.encode(jsonEncode(profile)));
  }

  test(
    'runs configured arguments and extracts from the configured stream',
    () async {
      final base = await loadProfile();
      final profileJson = Map<String, Object?>.from(base.json);
      final provider = Map<String, Object?>.from(
        profileJson['providerTool']! as Map,
      );
      final versionProbe =
          Map<String, Object?>.from(provider['versionProbe']! as Map)
            ..['arguments'] = [
              'run',
              '${Directory.current.path}/test/fixtures/profile_version_probe_provider.dart',
              'info',
              '--version',
            ]
            ..['source'] = 'stderr';
      profileJson['providerTool'] = {...provider, 'versionProbe': versionProbe};
      final profile = EngineProfile.parse(utf8.encode(jsonEncode(profileJson)));

      final result = await ProfileVersionProbe.run(
        profile: profile,
        executable: Platform.resolvedExecutable,
        commandRunner: const CliCommandRunner(maxOutputBytes: 64 * 1024),
        environment: Platform.environment,
        workingDirectory: Directory.current.path,
        context: ProfileVersionProbe.buildContext(
          profile: profile,
          workingDirectory: Directory.current.path,
          homeDirectory: Platform.environment['HOME'] ?? Directory.current.path,
          workerStateDirectory: Directory.systemTemp.path,
        ),
      );

      expect(result.exitCode, 0);
      expect(result.version, '1.2.3');
      expect(result.supported, isTrue);
    },
  );

  test('uses the configured timeout', () async {
    final base = await loadProfile();
    final profileJson = Map<String, Object?>.from(base.json);
    final provider = Map<String, Object?>.from(
      profileJson['providerTool']! as Map,
    );
    final versionProbe = Map<String, Object?>.from(provider['versionProbe']! as Map)
      ..['arguments'] = [
        'run',
        '${Directory.current.path}/test/fixtures/profile_version_probe_provider.dart',
        'slow',
      ]
      ..['timeoutMs'] = 100;
    profileJson['providerTool'] = {...provider, 'versionProbe': versionProbe};
    final profile = EngineProfile.parse(utf8.encode(jsonEncode(profileJson)));

    await expectLater(
      ProfileVersionProbe.run(
        profile: profile,
        executable: Platform.resolvedExecutable,
        commandRunner: const CliCommandRunner(maxOutputBytes: 64 * 1024),
        environment: Platform.environment,
        workingDirectory: Directory.current.path,
        context: ProfileVersionProbe.buildContext(
          profile: profile,
          workingDirectory: Directory.current.path,
          homeDirectory: Platform.environment['HOME'] ?? Directory.current.path,
          workerStateDirectory: Directory.systemTemp.path,
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}

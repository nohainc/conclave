import 'dart:io';

import 'package:syntila_profile_lab/profile_lab_test_sandbox.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/repository_root.dart';
import 'support/worker_profile_fixture.dart';

void main() {
  test(
    'Profile Lab runs the V9 test ladder through the bundled Engine binary',
    () async {
      final repository = repositoryRoot;
      final root =
          await Directory.systemTemp.createTemp('phase11-profile-lab-');
      addTearDown(() => root.delete(recursive: true));

      final providerDirectory = Directory('${root.path}/provider-bin')
        ..createSync(recursive: true);
      final provider = File(
        '${providerDirectory.path}/phase11-provider'
        '${Platform.isWindows ? '.bat' : ''}',
      );
      await _writeProvider(provider);

      final profile = _phase11Profile();
      final candidate = LocalDraftProfileCandidate.fromProfileMap(profile);
      final engine = File(
        '$repository/apps/profile_lab/assets/engines/'
        'syntila_cli_worker_engine${Platform.isWindows ? '.exe' : ''}',
      );
      expect(engine.existsSync(), isTrue);
      expect(engine.statSync().mode & 0x49, isNonZero);

      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: Directory('${root.path}/sandbox')..createSync(),
        engineExecutable: engine,
        environmentOverrides: {
          'PATH': '${providerDirectory.path}${Platform.isWindows ? ';' : ':'}'
              '${Platform.environment['PATH'] ?? ''}',
          'HOME': root.path,
        },
      );
      final result = await sandbox.executeTestLadder(candidate: candidate);
      expect(result.overallResult, 'pass',
          reason:
              result.stages.map((stage) => stage.toJson()).toList().toString());
      expect(
        result.stages.map((stage) => stage.stageId),
        containsAll(<String>[
          'schema',
          'executable_discovery',
          'cli_version',
          'passive_probe',
          'usage_check',
        ]),
      );
      expect(result.publicationEvidence, isNotNull);
      expect(
        result.publicationEvidence!.candidateDigest,
        candidate.payloadDigest,
      );
      expect(result.publicationEvidence!.providerToolVersion, '1.2.3');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Map<String, Object?> _phase11Profile() {
  return buildTestWorkerProfile(
    profileDefinitionId: 'phase11-profile-lab-worker',
    logicalWorkerTypeId: 'phase11-worker',
    providerToolName: 'Phase 11 Provider',
    executableCandidates: ['phase11-provider'],
    supportedVersions: [
      {'min': '1.2.3', 'maxExclusive': '1.3.0'},
    ],
    probe: {
      'passive': {
        'checks': [
          {
            'id': 'phase11-auth',
            'arguments': ['--version'],
            'timeoutMs': 5000,
            'successExitCodes': [0],
            'failureIssueCode': 'provider_authentication_required',
          },
        ],
        'configChecks': [],
      },
      'live': {
        'timeoutMs': 10000,
        'expectedFinalText': {'kind': 'exact', 'value': 'OK'},
      },
    },
    execution: {
      'arguments': ['run', '{{prompt}}'],
      'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
      'output': {'mode': 'single_json'},
      'events': [
        {
          'when': [],
          'actions': [
            {'type': 'set_final_text', 'selector': r'$.text'},
            {'type': 'mark_success'},
          ],
        },
      ],
    },
    session: {
      'supported': true,
      'formatId': 'phase11-session-v1',
      'compatibleFormatIds': ['phase11-session-v1'],
      'extract': r'$.sessionId',
      'resumeArguments': [],
      'requireObservedIdMatch': false,
    },
    model: {
      'supported': true,
      'arguments': ['--model', '{{model}}'],
      'allowlist': ['phase11-model'],
      'unknownModelPolicy': 'profile_allowlist',
    },
    sandbox: {
      'mappings': {
        'restricted': ['--sandbox', 'workspace-write'],
        'provider_default': [],
        'full_access': [],
      },
    },
  );
}

Future<void> _writeProvider(File provider) async {
  if (Platform.isWindows) {
    await provider.writeAsString(r'''@echo off
if "%1" == "--version" echo phase11-provider 1.2.3 & exit /b 0
echo {"sessionId":"phase11-session","text":"OK"}
''');
    return;
  }
  await provider.writeAsString(r'''#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "phase11-provider 1.2.3"
  exit 0
fi
case "$*" in
  *cancellation*|*timeout*) sleep 30 ;;
esac
case "$*" in
  *acceptance-write.txt*) printf 'syntila-profile-lab-write-verified\n' > acceptance-write.txt ;;
esac
printf '{"sessionId":"phase11-session","text":"OK"}\n'
''');
  await Process.run('chmod', ['700', provider.path]);
}

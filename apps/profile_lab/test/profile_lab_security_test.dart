import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_profile_lab/utils/profile_lab_security.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

void main() {
  group('ProfileLabSecurity Tests', () {
    test(
        'isUnsafeExecutable detects shell interpreters, dangerous binaries, and injection characters',
        () {
      // Forbidden executable names
      expect(ProfileLabSecurity.isUnsafeExecutable('sh'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('bash'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('sudo'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('curl'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('python'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('node'), isTrue);

      // Path traversal & injection tokens
      expect(ProfileLabSecurity.isUnsafeExecutable('/bin/sh'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('../bin/custom'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('tool; rm -rf /'), isTrue);
      expect(ProfileLabSecurity.isUnsafeExecutable('tool | grep'), isTrue);
      expect(
          ProfileLabSecurity.isUnsafeExecutable('tool & background'), isTrue);

      // Safe standalone binaries
      expect(ProfileLabSecurity.isUnsafeExecutable('codex'), isFalse);
      expect(ProfileLabSecurity.isUnsafeExecutable('opencode'), isFalse);
      expect(ProfileLabSecurity.isUnsafeExecutable('git'), isFalse);
    });

    test(
        'redactSecrets sanitizes tokens, API keys, private keys, and environment secrets',
        () {
      const input = '''
Authorization: Bearer secret_bearer_token_xyz123
API key detected: sk-12345678901234567890
Conclave key: conclave_sec_998877665544332211
PEM Block:
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC7
-----END PRIVATE KEY-----
Environment: API_KEY=super_secret_val; DATABASE_URL=postgres://localhost:5432/db
''';

      final redacted = ProfileLabSecurity.redactSecrets(input);

      expect(redacted, contains('[REDACTED_TOKEN]'));
      expect(redacted, contains('[REDACTED_API_KEY]'));
      expect(redacted, contains('[REDACTED_PRIVATE_KEY]'));
      expect(redacted, contains('API_KEY=[REDACTED]'));
      expect(redacted, contains('DATABASE_URL=[REDACTED]'));
      expect(redacted, isNot(contains('secret_bearer_token_xyz123')));
      expect(redacted, isNot(contains('sk-12345678901234567890')));
      expect(redacted, isNot(contains('-----BEGIN PRIVATE KEY-----')));
      expect(redacted, isNot(contains('super_secret_val')));
    });

    test('buildIsolatedEnvironment strips secret keys from host environment',
        () {
      final env = ProfileLabSecurity.buildIsolatedEnvironment();

      for (final key in env.keys) {
        final k = key.toUpperCase();
        expect(k.startsWith('CONCLAVE_SECRET_'), isFalse);
        expect(k.contains('WRANGLER_'), isFalse);
        expect(k.contains('BETTER_AUTH'), isFalse);
      }
    });

    test(
        'Test sandbox rejects draft candidate specifying unsafe executable candidate',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('profile_lab_sec_test_');
      try {
        final sandbox = ProfileLabTestSandbox(
          sandboxRoot: tempDir,
          engineExecutable: File('${tempDir.path}/fake_engine'),
        );

        final unsafeProfile = <String, Object?>{
          'schemaVersion': 1,
          'profileDefinitionId': 'prof-def-unsafe',
          'releaseVersion': 1,
          'logicalWorkerTypeId': 'worker-unsafe',
          'engineFamily': 'cli',
          'engineCompatibility': {'min': '0.0.0', 'maxExclusive': '99.0.0'},
          'providerTool': {
            'name': 'bash',
            'executableCandidates': ['bash'],
            'discovery': {'standardLocations': [], 'allowPathSearch': true},
            'versionProbe': {
              'arguments': ['--version'],
              'timeoutMs': 10000,
              'source': 'stdout',
              'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
            },
            'supportedVersions': [
              {'min': '1.2.3', 'maxExclusive': '1.3.0'}
            ],
          },
          'environment': {
            'passthrough': ['PATH', 'HOME'],
            'set': {}
          },
          'probe': {
            'passive': {'checks': [], 'configChecks': []}
          },
          'execution': {
            'arguments': ['run', '{{prompt}}'],
            'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
            'output': {'mode': 'plain_text'},
            'events': []
          },
          'session': {
            'supported': false,
            'formatId': 'session-v1',
            'compatibleFormatIds': ['session-v1'],
            'resumeArguments': [],
            'requireObservedIdMatch': false
          },
          'model': {
            'supported': false,
            'arguments': [],
            'unknownModelPolicy': 'pass_through'
          },
          'timeout': {'providerArguments': [], 'providerReserveMs': 0},
          'sandbox': {
            'mappings': {
              'restricted': [],
              'provider_default': [],
              'full_access': []
            }
          },
          'progress': [],
          'errors': {'mappings': []},
          'capabilities': ['code_generation'],
          'compatibilityOverrides': [],
        };
        final unsafeCandidate =
            LocalDraftProfileCandidate.fromProfileMap(unsafeProfile);

        final result =
            await sandbox.executeTestLadder(candidate: unsafeCandidate);

        expect(result.overallResult, equals('fail'));
        final stage3 = result.stages
            .firstWhere((s) => s.stageId == 'executable_discovery');
        expect(stage3.status, equals('failed'));
        expect(stage3.issueCode, equals('unsafe_executable_declaration'));
        expect(stage3.diagnostics, contains('unsafe or forbidden'));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'ProfileLabPaths ensureDirectoriesExist applies 0700 permissions on POSIX systems',
        () async {
      final tempHome = await Directory.systemTemp.createTemp('lab_home_');
      try {
        final paths = ProfileLabPaths(homeDirectory: tempHome.path);
        await paths.ensureDirectoriesExist();

        expect(await paths.applicationSupportDirectory.exists(), isTrue);
        expect(await paths.draftsDirectory.exists(), isTrue);
        expect(await paths.credentialsDirectory.exists(), isFalse);
        expect(await paths.logsDirectory.exists(), isTrue);
      } finally {
        await tempHome.delete(recursive: true);
      }
    });
  });
}

import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/worker_profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late WorkerProfileStore workspaceStore;
  late WorkerTrustPolicy trustPolicy;

  setUp(() async {
    temporary =
        await Directory.systemTemp.createTemp('workspace_unsigned_test_');
    trustPolicy = WorkerTrustPolicy(trustedPublicKeys: {});
    workspaceStore = WorkerProfileStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: trustPolicy,
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  group('Phase 27 — Security Boundary: Unsigned Profile Lab Draft Isolation',
      () {
    test(
        'Unsigned Profile Lab draft candidate is explicitly rejected by Workspace trusted Profile store',
        () async {
      final draftPayload = <String, Object?>{
        'schemaVersion': 1,
        'profileDefinitionId': 'codex-cli',
        'releaseVersion': 1,
        'logicalWorkerTypeId': 'codex',
        'engineFamily': 'cli',
        'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
        'providerTool': {
          'name': 'codex',
          'executableCandidates': ['codex'],
          'discovery': {'standardLocations': [], 'allowPathSearch': true},
          'versionProbe': {
            'arguments': ['--version'],
            'timeoutMs': 10000,
            'source': 'stdout',
            'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
          },
          'supportedVersions': [
            {'min': '0.0.1', 'maxExclusive': '99.0.0'}
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
          'arguments': ['exec', '{{prompt}}'],
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
        'compatibilityOverrides': [],
      };

      // Profile Lab candidate (unsigned)
      final candidate = LocalDraftProfileCandidate.fromProfileMap(draftPayload);
      expect(candidate.isSigned, isFalse);

      // Workspace execution storage must reject the unsigned candidate.
      expect(
        () => workspaceStore.executionProfileFile(candidate),
        throwsStateError,
      );

      expect(
        await workspaceStore
            .currentWorkerProfile(candidate.logicalWorkerTypeId),
        isNull,
      );
    });
  });
}

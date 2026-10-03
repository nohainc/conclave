import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late ToolProfileReleaseStore workspaceStore;
  late WorkerTrustPolicy trustPolicy;

  setUp(() async {
    temporary =
        await Directory.systemTemp.createTemp('workspace_unsigned_test_');
    trustPolicy = WorkerTrustPolicy(trustedPublicKeys: {});
    workspaceStore = ToolProfileReleaseStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: trustPolicy,
      retentionLimit: 2,
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
        'capabilities': ['code_generation'],
        'compatibilityOverrides': [],
      };

      // Profile Lab candidate (unsigned)
      final candidate = LocalDraftProfileCandidate.fromProfileMap(draftPayload);
      expect(candidate.isSigned, isFalse);

      final unsignedReleaseMap = <String, Object?>{
        'profileDefinitionId': candidate.profileDefinitionId,
        'workerTypeId': candidate.logicalWorkerTypeId,
        'displayName': 'Unsigned Lab Draft',
        'providerToolName': candidate.providerToolName,
        'channel': 'testing',
        'releaseVersion': candidate.releaseVersion,
        'profile': candidate.profile,
        'schemaVersion': 1,
        'engineFamily': 'cli',
        'payloadDigest': candidate.payloadDigest,
        // Notice: signature is intentionally omitted or invalid
      };

      // Workspace store must reject the unsigned release input
      expect(
        () async => await workspaceStore.installRelease(
          releaseInput: unsignedReleaseMap,
          expectedWorkerTypeId: candidate.logicalWorkerTypeId,
        ),
        throwsA(isA<Exception>()),
      );

      // Verify the profile was never written to disk or activated in Workspace store
      final installedVersions =
          await workspaceStore.installedVersions(candidate.profileDefinitionId);
      expect(installedVersions, isEmpty);

      final activeRelease =
          await workspaceStore.activeRelease(candidate.profileDefinitionId);
      expect(activeRelease, isNull);
    });
  });
}

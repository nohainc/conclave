import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

Map<String, Object?> validProfileMap({
  String profileDefinitionId = 'chatgpt-codex',
  int releaseVersion = 10,
  String logicalWorkerTypeId = 'chatgpt',
  String providerToolName = 'codex',
}) =>
    {
      'schemaVersion': 1,
      'profileDefinitionId': profileDefinitionId,
      'releaseVersion': releaseVersion,
      'logicalWorkerTypeId': logicalWorkerTypeId,
      'engineFamily': 'cli',
      'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
      'providerTool': {
        'name': providerToolName,
        'executableCandidates': [providerToolName],
        'discovery': {'standardLocations': [], 'allowPathSearch': true},
        'versionProbe': {
          'arguments': ['--version'],
          'timeoutMs': 10000,
          'source': 'stdout',
          'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
        },
        'supportedVersions': [
          {'min': '0.1.0', 'maxExclusive': '1.0.0'}
        ],
      },
      'environment': {
        'passthrough': ['PATH', 'HOME'],
        'set': {}
      },
      'probe': {
        'passive': {
          'checks': [
            {
              'id': 'auth',
              'arguments': ['probe'],
              'timeoutMs': 5000,
              'successExitCodes': [0],
              'failureIssueCode': 'provider_authentication_required'
            }
          ],
          'configChecks': []
        }
      },
      'execution': {
        'arguments': ['run', '{{prompt}}'],
        'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
        'output': {'mode': 'plain_text'},
        'events': []
      },
      'session': {
        'supported': false,
        'formatId': 'fixture-session-v1',
        'compatibleFormatIds': ['fixture-session-v1'],
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
      'errors': {
        'mappings': [
          {
            'evidence': {'kind': 'exit_code', 'value': 2},
            'issueCode': 'provider_failure'
          }
        ]
      },
      'capabilities': ['text'],
      'compatibilityOverrides': []
    };

void main() {
  group('Tool Profile Release & Candidate Primitives', () {
    test(
        'LocalDraftProfileCandidate computes canonical digest and identifies as unsigned',
        () {
      final sampleProfile = validProfileMap();

      final candidate =
          LocalDraftProfileCandidate.fromProfileMap(sampleProfile);
      expect(candidate.isSigned, isFalse);
      expect(candidate.profileDefinitionId, 'chatgpt-codex');
      expect(candidate.releaseVersion, 10);
      expect(candidate.logicalWorkerTypeId, 'chatgpt');
      expect(candidate.providerToolName, 'codex');
      expect(candidate.payloadDigest.length, 64);
    });

    test('ToolProfileReleaseIdentity equality and string representation', () {
      const id1 = ToolProfileReleaseIdentity(
        profileDefinitionId: 'chatgpt-codex',
        releaseVersion: 12,
      );
      const id2 = ToolProfileReleaseIdentity(
        profileDefinitionId: 'chatgpt-codex',
        releaseVersion: 12,
      );
      const id3 = ToolProfileReleaseIdentity(
        profileDefinitionId: 'chatgpt-codex',
        releaseVersion: 13,
      );

      expect(id1, equals(id2));
      expect(id1.hashCode, equals(id2.hashCode));
      expect(id1, isNot(equals(id3)));
      expect(id1.toString(), 'chatgpt-codex@12');
    });

    test('ToolProfileCompatibility checks engine and provider version bounds',
        () {
      final sampleProfile = validProfileMap();

      final profile =
          EngineProfile.parse(utf8.encode(canonicalJson(sampleProfile)));

      expect(ToolProfileCompatibility.isEngineCompatible(profile, '1.2.0'),
          isTrue);
      expect(ToolProfileCompatibility.isEngineCompatible(profile, '2.0.0'),
          isFalse);
      expect(ToolProfileCompatibility.isEngineCompatible(profile, '0.9.0'),
          isFalse);

      expect(ToolProfileCompatibility.isProviderCompatible(profile, '0.5.2'),
          isTrue);
      expect(ToolProfileCompatibility.isProviderCompatible(profile, '1.0.0'),
          isFalse);
      expect(
          ToolProfileCompatibility.isProviderCompatible(profile, null), isTrue);
    });

    test(
        'WorkerTrustPolicy verifies valid Ed25519 signature and honors revocations',
        () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final pubKeyBase64 = base64.encode(publicKey.bytes);

      const publisher = 'conclave';
      const keyId = 'key-1';
      final policy = WorkerTrustPolicy(
        trustedPublicKeys: {
          publisher: {keyId: pubKeyBase64}
        },
      );

      const message = 'conclave-tool-profile-release-v1\ntest-signing-message';
      final signature =
          await algorithm.sign(utf8.encode(message), keyPair: keyPair);
      final sigBase64 = base64.encode(signature.bytes);

      final valid = await policy.verifyToolProfileRelease(
        publisher: publisher,
        signingKeyId: keyId,
        digest: 'sha256:abc',
        releaseId: 'chatgpt-codex@1',
        signature: sigBase64,
        message: message,
      );
      expect(valid, isTrue);

      // Test revocation of digest
      policy.updateRevocations(digests: {'sha256:abc'});
      final revoked = await policy.verifyToolProfileRelease(
        publisher: publisher,
        signingKeyId: keyId,
        digest: 'sha256:abc',
        releaseId: 'chatgpt-codex@1',
        signature: sigBase64,
        message: message,
      );
      expect(revoked, isFalse);
    });
  });
}

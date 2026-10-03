import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/utils/profile_lab_model_proposals.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('discovers model options only from trusted current Stable Profiles',
      () async {
    final signedRelease = await _createSignedRelease();
    final api = _SignedReleaseApi(signedRelease);
    final publicKey = await signedRelease.keyPair.extractPublicKey();
    final trustPolicy = WorkerTrustPolicy(trustedPublicKeys: {
      'conclave': {'test-profile-key': base64.encode(publicKey.bytes)},
    });

    final options = await const ProfileLabModelProposalService()
        .loadAvailableModels(apiClient: api, trustPolicy: trustPolicy);

    expect(options.map((option) => option.model).toList(),
        ['model-fast', 'model-safe']);
    expect(options.every((option) => option.release.isSigned), isTrue);
    expect(options.first.modelIdentifier,
        'model-worker/model-profile@2#model-fast');
  });

  test('current Cloud key revocation removes otherwise valid model Profiles',
      () async {
    final signedRelease = await _createSignedRelease();
    final api = _SignedReleaseApi(
      signedRelease,
      revokedKeyIds: const ['test-profile-key'],
    );
    final publicKey = await signedRelease.keyPair.extractPublicKey();
    final trustPolicy = WorkerTrustPolicy(trustedPublicKeys: {
      'conclave': {'test-profile-key': base64.encode(publicKey.bytes)},
    });

    final options = await const ProfileLabModelProposalService()
        .loadAvailableModels(apiClient: api, trustPolicy: trustPolicy);

    expect(options, isEmpty);
  });
}

class _SignedReleaseApi extends ProfileAdminApiClient {
  _SignedReleaseApi(
    this.signedRelease, {
    this.revokedKeyIds = const [],
  }) : super(baseUrl: 'http://127.0.0.1:1');

  final _SignedRelease signedRelease;
  final List<String> revokedKeyIds;

  @override
  Future<ProfileLabReleaseTrustReadModel> fetchReleaseTrust() async =>
      ProfileLabReleaseTrustReadModel.fromJson({
        'revokedKeyIds': revokedKeyIds,
        'revokedToolProfiles': <Map<String, Object?>>[],
      });

  @override
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async => [
        ProfileLabWorkerReadModel.fromJson({
          'workerTypeId': 'model-worker',
          'profileDefinitionId': 'model-profile',
          'displayName': 'Model Worker',
          'providerToolName': 'fixture-provider',
          'releaseStage': 'stable',
        }),
      ];

  @override
  Future<List<ProfileLabChannelPointerReadModel>> fetchChannelPointers(
          [String? profileDefinitionId]) async =>
      [
        ProfileLabChannelPointerReadModel.fromJson({
          'profileDefinitionId': 'model-profile',
          'channel': 'stable',
          'releaseVersion': 2,
        }),
      ];

  @override
  Future<ProfileLabReleaseReadModel> fetchRelease(
          String profileDefinitionId, int releaseVersion) async =>
      ProfileLabReleaseReadModel.fromJson(signedRelease.envelope);
}

class _SignedRelease {
  const _SignedRelease(this.envelope, this.keyPair);

  final Map<String, Object?> envelope;
  final SimpleKeyPair keyPair;
}

Future<_SignedRelease> _createSignedRelease() async {
  final repositoryRoot = Directory.current.parent.parent;
  final fixtureFile = File(
    '${repositoryRoot.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
  );
  final profile = Map<String, Object?>.from(
    jsonDecode(await fixtureFile.readAsString()) as Map,
  );
  profile['profileDefinitionId'] = 'model-profile';
  profile['releaseVersion'] = 2;
  profile['logicalWorkerTypeId'] = 'model-worker';
  profile['model'] = {
    'supported': true,
    'arguments': ['--model', '{{model}}'],
    'allowlist': ['model-safe', 'model-fast'],
    'unknownModelPolicy': 'profile_allowlist',
  };
  final digest = sha256.convert(utf8.encode(canonicalJson(profile))).toString();
  const publisher = 'conclave';
  const keyId = 'test-profile-key';
  final keyPair = await Ed25519().newKeyPair();
  final message = toolProfileReleaseSigningMessage(
    publisher: publisher,
    signingKeyId: keyId,
    payloadDigest: digest,
    profile: profile,
  );
  final signature = await Ed25519().sign(
    utf8.encode(message),
    keyPair: keyPair,
  );
  final providerToolName =
      (profile['providerTool'] as Map<String, Object?>)['name'] as String;
  return _SignedRelease(
    {
      'profileDefinitionId': 'model-profile',
      'workerTypeId': 'model-worker',
      'releaseVersion': 2,
      'lifecycleState': 'stable',
      'channel': 'stable',
      'providerToolName': providerToolName,
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
      'profile': profile,
      'payloadDigest': digest,
      'signature': base64.encode(signature.bytes),
      'signingKeyId': keyId,
      'publisher': publisher,
      'publishedAt': DateTime.utc(2026).toIso8601String(),
    },
    keyPair,
  );
}

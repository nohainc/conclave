import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Profile Admin read models', () {
    test('access diagnostics separate permission from signer readiness', () {
      final access = ProfileLabAccessReadModel.fromJson({
        'permissions': {'profilesAdmin': true, 'releaseManager': true},
        'signer': {
          'ready': false,
          'issues': ['private_key_missing']
        }
      });
      expect(access.profilesAdmin, isTrue);
      expect(access.releaseManager, isTrue);
      expect(access.signerReady, isFalse);
      expect(access.signerIssues, ['private_key_missing']);
      expect(ProfileLabAccessReadModel.fromJson({}).profilesAdmin, isFalse);
    });
    test('release exposes lifecycle identity and preserves open Profile data',
        () {
      final release = ProfileLabReleaseReadModel.fromJson({
        'profileDefinitionId': 'custom-worker',
        'releaseVersion': 7,
        'lifecycleState': 'testing',
        'payloadDigest': 'digest-7',
        'profile': {
          'schemaVersion': 1,
          'providerTool': {'name': 'future-provider'},
        },
        'futureCloudField': true,
      });

      expect(release.profileDefinitionId, 'custom-worker');
      expect(release.releaseVersion, 7);
      expect(release.lifecycleState, 'testing');
      expect(release.profile?['providerTool'], {'name': 'future-provider'});
      expect(release.toJson()['futureCloudField'], isTrue);
    });

    test('worker catalog fields are typed and capabilities are immutable', () {
      final worker = ProfileLabWorkerReadModel.fromJson({
        'workerTypeId': 'new-worker',
        'profileDefinitionId': 'new-worker-profile',
        'displayName': 'New Worker',
        'providerToolName': 'new-cli',
        'releaseStage': 'draft',
        'capabilities': ['code_generation'],
        'sortOrder': 4,
      });

      expect(worker.workerTypeId, 'new-worker');
      expect(worker.providerToolName, 'new-cli');
      expect(worker.capabilities, ['code_generation']);
      expect(() => worker.capabilities.add('mutate'), throwsUnsupportedError);
    });

    test('signing preflight keeps a typed readiness result and issue list', () {
      final preflight = ProfileLabSigningPreflightReadModel.fromJson({
        'ready': false,
        'publisher': 'conclave',
        'signingKeyId': 'profile-key-v2',
        'issues': ['trust root mismatch'],
      });

      expect(preflight.ready, isFalse);
      expect(preflight.signingKeyId, 'profile-key-v2');
      expect(preflight.issues, ['trust root mismatch']);
    });
  });
}

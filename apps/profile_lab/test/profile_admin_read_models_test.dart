import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Profile Admin read models', () {
    test('access diagnostics separate permission from signer readiness', () {
      final access = ProfileLabAccessReadModel.fromJson({
        'permissions': {'profilesAdmin': true, 'issueSupport': true},
        'signer': {
          'ready': false,
          'issues': ['private_key_missing']
        }
      });
      expect(access.profilesAdmin, isTrue);
      expect(access.issueSupport, isTrue);
      expect(access.signerReady, isFalse);
      expect(access.signerIssues, ['private_key_missing']);
      expect(ProfileLabAccessReadModel.fromJson({}).profilesAdmin, isFalse);
    });
    test('worker catalog fields are typed without capability metadata', () {
      final worker = ProfileLabWorkerReadModel.fromJson({
        'workerTypeId': 'new-worker',
        'profileDefinitionId': 'new-worker-profile',
        'displayName': 'New Worker',
        'providerToolName': 'new-cli',
        'currentRevision': 7,
        'currentDigest': 'digest-7',
        'sortOrder': 4,
      });

      expect(worker.workerTypeId, 'new-worker');
      expect(worker.providerToolName, 'new-cli');
      expect(worker.currentRevision, 7);
      expect(worker.currentDigest, 'digest-7');
      expect(worker.toJson().containsKey('capabilities'), isFalse);
    });

    test('audit events preserve diagnostic identity and unknown fields', () {
      final event = ProfileLabAuditEventReadModel.fromJson({
        'id': 'event-1',
        'action': 'profile_published',
        'actor': 'operator',
        'createdAt': '2026-10-12T10:00:00Z',
        'futureField': true,
      });
      expect(event.action, 'profile_published');
      expect(event.toJson()['futureField'], isTrue);
    });
  });
}

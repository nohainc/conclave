import 'package:test/test.dart';

import 'package:conclave_host/credential_profiles.dart';
import 'package:conclave_host/secure_credentials.dart';

class MemoryCredentialStore implements SecureCredentialStore {
  final values = <String, String>{};
  final writes = <String>[];

  @override
  String? readSync(String key) => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

CredentialProfile profile({
  required String id,
  required String ownerId,
  CredentialSharingPolicy sharingPolicy = CredentialSharingPolicy.privateOnly,
}) =>
    CredentialProfile(
      id: id,
      workspaceId: 'workspace-1',
      ownerType: CredentialOwnerType.user,
      ownerId: ownerId,
      workerId: 'codex',
      hostId: 'host-1',
      displayName: 'Codex $ownerId',
      authType: CredentialAuthType.apiKey,
      status: CredentialProfileStatus.setupRequired,
      sharingPolicy: sharingPolicy,
    );

void main() {
  test('keeps two users isolated on one Host and Worker', () async {
    final backing = MemoryCredentialStore();
    final profiles = CredentialProfileStore(hostId: 'host-1', store: backing);
    final alice = profile(id: 'alice-codex', ownerId: 'alice');
    final bob = profile(id: 'bob-codex', ownerId: 'bob');

    final readyAlice = await profiles.saveApiKey(alice, 'alice-secret');
    final readyBob = await profiles.completeCliLogin(bob, 'bob-secret');

    expect(await profiles.read(readyAlice), 'alice-secret');
    expect(await profiles.read(readyBob), 'bob-secret');
    expect(backing.values.keys,
        contains('credential-profile/host-1/codex/alice-codex'));
    expect(backing.values.keys,
        contains('credential-profile/host-1/codex/bob-codex'));
    expect(readyAlice.status, CredentialProfileStatus.ready);
    expect(readyBob.authType, CredentialAuthType.cliLogin);
  });

  test('supports an explicitly shared profile without sharing storage keys',
      () async {
    final backing = MemoryCredentialStore();
    final profiles = CredentialProfileStore(hostId: 'host-1', store: backing);
    final shared = profile(
      id: 'workspace-codex',
      ownerId: 'workspace-1',
      sharingPolicy: CredentialSharingPolicy.workspaceCapable,
    ).copyWith();

    final ready = await profiles.save(shared, 'workspace-secret');
    expect(ready.toCloudMetadata()['sharingPolicy'], 'workspace_capable');
    expect(await profiles.read(ready), 'workspace-secret');
    expect(backing.values, hasLength(1));
  });

  test('clear and revoke remove the local secret', () async {
    final backing = MemoryCredentialStore();
    final profiles = CredentialProfileStore(hostId: 'host-1', store: backing);
    final saved =
        await profiles.save(profile(id: 'codex', ownerId: 'alice'), 'secret');

    final cleared = await profiles.clear(saved);
    expect(cleared.status, CredentialProfileStatus.setupRequired);
    expect(await profiles.read(cleared), isNull);

    await profiles.save(cleared, 'secret-again');
    final revoked = await profiles.revoke(cleared);
    expect(revoked.status, CredentialProfileStatus.revoked);
    expect(await profiles.read(revoked), isNull);
  });

  test('rejects a profile belonging to another Host', () async {
    final profiles = CredentialProfileStore(
      hostId: 'host-1',
      store: MemoryCredentialStore(),
    );
    expect(
      () => profiles.beginAuthentication(
          profile(id: 'wrong', ownerId: 'alice').copyWith()),
      returnsNormally,
    );
    final wrongHost = CredentialProfile(
      id: 'wrong-host',
      workspaceId: 'workspace-1',
      ownerType: CredentialOwnerType.user,
      ownerId: 'alice',
      workerId: 'codex',
      hostId: 'host-2',
      displayName: 'Wrong Host',
      authType: CredentialAuthType.apiKey,
      status: CredentialProfileStatus.setupRequired,
      sharingPolicy: CredentialSharingPolicy.privateOnly,
    );
    expect(() => profiles.beginAuthentication(wrongHost), throwsStateError);
  });

  test('Cloud metadata and logs never contain the raw secret', () async {
    final backing = MemoryCredentialStore();
    final profiles = CredentialProfileStore(hostId: 'host-1', store: backing);
    final saved = await profiles.save(
        profile(id: 'redacted', ownerId: 'alice'), 'super-secret');
    final metadata = saved.toCloudMetadata();
    expect(metadata.values, isNot(contains('super-secret')));
    expect(metadata.keys, isNot(contains('secret')));
    expect(metadata['secretLocation'], 'host_secure_store');
    expect(
      metadata['secretReference'],
      'credential-profile/host-1/codex/redacted',
    );
  });
}

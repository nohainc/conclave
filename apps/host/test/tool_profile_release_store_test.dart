import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/tool_profile_release_store.dart';
import 'package:conclave_host/tool_profile_catalog.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Ed25519ReleaseFixture signing;
  late Directory temporary;
  late ToolProfileReleaseStore store;
  late Map<String, Object?> profile;

  setUp(() async {
    signing = await Ed25519ReleaseFixture.create();
    temporary =
        await Directory.systemTemp.createTemp('conclave-profile-store-');
    store = ToolProfileReleaseStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: signing.trustPolicy,
      retentionLimit: 2,
    );
    profile = jsonDecode(
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<Map<String, Object?>> makeRelease(
    int version, {
    String channel = 'stable',
  }) async {
    final releaseProfile =
        jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
    releaseProfile['releaseVersion'] = version;
    final release = <String, Object?>{
      'profileDefinitionId': releaseProfile['profileDefinitionId'],
      'workerTypeId': releaseProfile['logicalWorkerTypeId'],
      'displayName': 'Fixture CLI',
      'providerToolName':
          (releaseProfile['providerTool']! as Map<String, Object?>)['name'],
      'channel': channel,
      'releaseVersion': version,
      'profile': releaseProfile,
      'schemaVersion': releaseProfile['schemaVersion'],
      'engineFamily': releaseProfile['engineFamily'],
      'engineCompatibility': releaseProfile['engineCompatibility'],
    };
    await signing.signToolProfileRelease(release);
    return release;
  }

  test('verifies schema and caches a candidate until explicit activation',
      () async {
    final release = await makeRelease(1);
    final admitted = await store.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'fixture-worker',
    );
    final path = store.profileFile('fixture-cli', 1);
    expect(admitted.payloadDigest, release['payloadDigest']);
    expect(await path.exists(), isTrue);
    expect(
      jsonDecode(await path.readAsString()),
      equals(release['profile']),
    );
    expect((await store.releaseState('fixture-cli')).activeVersion, isNull);
    expect(await store.activeRelease('fixture-cli'), isNull);
    await store.activateVersion('fixture-cli', 1);
    expect((await store.releaseState('fixture-cli')).activeVersion, 1);
    expect((await store.activeRelease('fixture-cli'))?.releaseVersion, 1);

    final altered = await makeRelease(2);
    (altered['profile']! as Map<String, Object?>)['unsupported'] = true;
    await signing.signToolProfileRelease(altered);
    await expectLater(
      store.installRelease(
        releaseInput: altered,
        expectedWorkerTypeId: 'fixture-worker',
      ),
      throwsFormatException,
    );
  });

  test('tracks last-known-good and enforces bounded retention', () async {
    for (final version in [1, 2, 3]) {
      await store.installRelease(
        releaseInput: await makeRelease(version),
        expectedWorkerTypeId: 'fixture-worker',
      );
      await store.activateVersion('fixture-cli', version);
    }
    final state = await store.releaseState('fixture-cli');
    expect(state.activeVersion, 3);
    expect(state.lastKnownGoodVersion, 2);
    expect(await store.installedVersions('fixture-cli'), [3, 2]);
    expect(await store.profileFile('fixture-cli', 1).exists(), isFalse);
    await store.rollbackToLastKnownGood(
      'fixture-cli',
      candidateValidator: (_) async => true,
    );
    final rolledBack = await store.releaseState('fixture-cli');
    expect(rolledBack.activeVersion, 2);
    expect(rolledBack.lastKnownGoodVersion, 3);
  });

  test('rollback only switches after candidate validation succeeds', () async {
    for (final version in [1, 2]) {
      await store.installRelease(
        releaseInput: await makeRelease(version),
        expectedWorkerTypeId: 'fixture-worker',
      );
      await store.activateVersion('fixture-cli', version);
    }

    await expectLater(
      store.rollbackToLastKnownGood(
        'fixture-cli',
        candidateValidator: (_) async => false,
      ),
      throwsStateError,
    );
    expect((await store.releaseState('fixture-cli')).activeVersion, 2);
    expect((await store.releaseState('fixture-cli')).lastKnownGoodVersion, 1);

    final candidate = await store.rollbackToLastKnownGood(
      'fixture-cli',
      candidateValidator: (release) async => release.releaseVersion == 1,
    );
    expect(candidate.releaseVersion, 1);
    expect((await store.releaseState('fixture-cli')).activeVersion, 1);
    expect((await store.releaseState('fixture-cli')).lastKnownGoodVersion, 2);
  });

  test('refreshes trusted lifecycle metadata when a release is promoted',
      () async {
    final release = await makeRelease(1);
    release['channel'] = 'beta';
    await store.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'fixture-worker',
    );
    expect(await store.currentStableRelease('fixture-cli'), isNull);

    release['channel'] = 'stable';
    await store.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'fixture-worker',
    );
    await store.activateVersion('fixture-cli', 1, selectAsStable: true);
    expect(
        (await store.currentStableRelease('fixture-cli'))?.releaseVersion, 1);
    expect((await store.activeRelease('fixture-cli'))?.channel, 'stable');
    expect(
      jsonDecode(await store.profileFile('fixture-cli', 1).readAsString()),
      equals(release['profile']),
    );
  });

  test('activates Cloud-selected testing channel without moving stable pointer',
      () async {
    final stable = await makeRelease(1);
    await store.installRelease(
      releaseInput: stable,
      expectedWorkerTypeId: 'fixture-worker',
    );
    await store.activateVersion('fixture-cli', 1, selectAsStable: true);
    final testing = await makeRelease(2, channel: 'testing');
    await store.installRelease(
      releaseInput: testing,
      expectedWorkerTypeId: 'fixture-worker',
    );

    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      trustRefresher: () async {},
      listLoader: (workerTypeId, _) async => ToolProfileCatalogResult(
        channel: 'testing',
        releases: [testing],
      ),
      candidateValidator: (_, __) async => true,
    );
    try {
      await catalog.syncWorkerProfiles('fixture-worker');
      final state = await store.releaseState('fixture-cli');
      expect(state.selectedChannel, 'testing');
      expect(state.activeVersion, 2);
      expect(state.stableVersion, 1);
      expect(state.lastKnownGoodVersion, 1);
    } finally {
      catalog.close();
    }
  });

  test('syncs and caches the approved logical Worker catalog', () async {
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      trustRefresher: () async {},
      workerCatalogLoader: () async => [
        {
          'workerTypeId': 'fixture-worker',
          'displayName': 'Fixture Worker',
          'description': 'approved fixture',
          'profileDefinitionId': 'fixture-cli',
          'providerToolName': 'fixture',
          'engineFamily': 'cli',
          'visibilityState': 'visible',
          'releaseStage': 'testing',
          'capabilities': ['text', 'workstream_read'],
          'sortOrder': 5,
        },
      ],
    );
    try {
      final entries = await catalog.syncCatalog();
      expect(entries.single.workerTypeId, 'fixture-worker');
      expect(
          catalog.profileDefinitionForWorker('fixture-worker'), 'fixture-cli');
      final registry = LocalConfiguredWorkerRegistry(
        dataDirectory: Directory('${temporary.path}/workspace'),
        workspaceId: 'workspace-fixture',
      );
      final configured = await registry.create(
        name: entries.single.displayName,
        workerTypeId: entries.single.workerTypeId,
        approvedCatalogEntry: entries.single,
        authStrategy: 'browser_auth',
      );
      expect(configured.workerTypeId, 'fixture-worker');
      catalog.close();

      final restarted = ToolProfileCatalogClient(
        cloudUri: Uri.https('cloud.example', '/'),
        store: store,
        trustPolicy: signing.trustPolicy,
        trustRefresher: () async {},
      );
      expect(
          (await restarted.loadCatalog()).single.displayName, 'Fixture Worker');
      restarted.close();
    } finally {
      catalog.close();
    }
  });

  test('rejects unknown catalog capabilities and oversized catalog responses',
      () async {
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [
        {
          'workerTypeId': 'fixture-worker',
          'displayName': 'Fixture',
          'description': '',
          'profileDefinitionId': 'fixture-cli',
          'providerToolName': 'fixture',
          'engineFamily': 'cli',
          'visibilityState': 'visible',
          'releaseStage': 'stable',
          'capabilities': ['execute_shell'],
          'sortOrder': 1,
        },
      ],
    );
    try {
      await expectLater(catalog.syncCatalog(), throwsFormatException);
    } finally {
      catalog.close();
    }
  });

  test('persists revocations and does not promote an unprobed LKG release',
      () async {
    for (final version in [1, 2]) {
      await store.installRelease(
        releaseInput: await makeRelease(version),
        expectedWorkerTypeId: 'fixture-worker',
      );
      await store.activateVersion('fixture-cli', version);
    }
    signing.trustPolicy.updateRevocations(
      releaseIds: {'fixture-cli@2'},
      digests: {((await makeRelease(2))['payloadDigest']! as String)},
    );
    await store.persistRevocations();

    final policyAfterRestart = WorkerTrustPolicy(
      trustedPublicKeys: signing.trustPolicy.trustedPublicKeys,
    );
    final restarted = ToolProfileReleaseStore(
      profilesRoot: store.profilesRoot,
      trustPolicy: policyAfterRestart,
      retentionLimit: 2,
    );
    await restarted.restoreRevocations();
    final affected = await restarted.reconcileRevocations();
    expect(affected, {'fixture-worker'});
    expect(await restarted.installedVersions('fixture-cli'), [1]);
    final state = await restarted.releaseState('fixture-cli');
    // Revocation immediately clears active eligibility; recovery must probe
    // the remaining LKG before selecting it.
    expect(state.activeVersion, isNull);
    expect(state.lastKnownGoodVersion, 1);
  });

  test('rejects modified cached bytes on read', () async {
    await store.installRelease(
      releaseInput: await makeRelease(1),
      expectedWorkerTypeId: 'fixture-worker',
    );
    await store.activateVersion('fixture-cli', 1);
    await store
        .profileFile('fixture-cli', 1)
        .writeAsString('{"tampered":true}');
    expect(await store.activeRelease('fixture-cli'), isNull);
    expect(await store.installedVersions('fixture-cli'), isEmpty);
  });

  test('keeps releases from not-yet-delivered keys cached but inactive',
      () async {
    await store.installRelease(
      releaseInput: await makeRelease(1),
      expectedWorkerTypeId: 'fixture-worker',
    );
    await store.activateVersion('fixture-cli', 1);
    final workspaceWithoutKey = ToolProfileReleaseStore(
      profilesRoot: store.profilesRoot,
      trustPolicy: WorkerTrustPolicy(),
      retentionLimit: 2,
    );
    await workspaceWithoutKey.reconcileRevocations();
    expect(await workspaceWithoutKey.installedVersions('fixture-cli'), [1]);
    expect(
        (await workspaceWithoutKey.releaseState('fixture-cli')).activeVersion,
        isNull);
    expect(await workspaceWithoutKey.activeRelease('fixture-cli'), isNull);
  });

  test('fetches Cloud revocations and the catalog before caching releases',
      () async {
    final release = await makeRelease(1);
    var trustRefreshed = false;
    var releases = <Object?>[release];
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      trustRefresher: () async {
        trustRefreshed = true;
      },
      listLoader: (workerTypeId, channel) async {
        expect(trustRefreshed, isTrue);
        expect(workerTypeId, 'fixture-worker');
        expect(channel, 'stable');
        return ToolProfileCatalogResult(
          channel: channel,
          releases: releases,
        );
      },
      candidateValidator: (candidate, file) async {
        expect(await file.exists(), isTrue);
        if (candidate.releaseVersion == 3) {
          final state = await store.releaseState('fixture-cli');
          expect(state.activeVersion, 2);
          expect(state.lastKnownGoodVersion, 1);
          return false;
        }
        return true;
      },
    );
    try {
      final results = await catalog.syncWorkerProfiles('fixture-worker');
      expect(results, hasLength(1));
      expect(trustRefreshed, isTrue);
      expect((await store.releaseState('fixture-cli')).activeVersion, 1);
      expect(await store.profileFile('fixture-cli', 1).exists(), isTrue);
      final release2 = await makeRelease(2);
      releases = [release2];
      await catalog.syncWorkerProfiles('fixture-worker');
      final afterAcceptedCandidate = await store.releaseState('fixture-cli');
      expect(afterAcceptedCandidate.activeVersion, 2);
      expect(afterAcceptedCandidate.lastKnownGoodVersion, 1);
      final release3 = await makeRelease(3);
      releases = [release3];
      await catalog.syncWorkerProfiles('fixture-worker');
      final afterFailedCandidate = await store.releaseState('fixture-cli');
      expect(afterFailedCandidate.activeVersion, 2);
      expect(afterFailedCandidate.lastKnownGoodVersion, 1);
      expect(afterFailedCandidate.stableVersion, 2);
      expect(await store.profileFile('fixture-cli', 3).exists(), isFalse);
      releases = [];
      await catalog.syncWorkerProfiles('fixture-worker');
      expect((await store.releaseState('fixture-cli')).activeVersion, isNull);
      expect(await store.profileFile('fixture-cli', 1).exists(), isTrue);
    } finally {
      catalog.close();
    }
  });
}

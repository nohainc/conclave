import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show
        WorkerProfileSnapshotAdmission,
        canonicalJson,
        workerProfileSigningMessage;
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/worker_trust_policy.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';
import 'support/worker_profile_snapshot_fixture.dart';

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

  test('syncs the current V9 Profile without channel selection', () async {
    final candidateProfile =
        jsonDecode(jsonEncode(profile)) as Map<String, Object?>
          ..['logicalWorkerTypeId'] = 'fixture-worker'
          ..['releaseVersion'] = 2;
    final candidate = await workerProfileSnapshotFixture(
      signing: signing,
      profile: candidateProfile,
      workerTypeId: 'fixture-worker',
      revision: 2,
    );
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      trustRefresher: () async {},
      currentProfileLoader: (_) async => candidate,
      candidateValidator: (_, __) async => true,
    );
    try {
      await catalog.syncWorkerProfiles('fixture-worker');
      expect(
        (await store.currentWorkerProfile('fixture-worker'))?.revision,
        2,
      );
    } finally {
      catalog.close();
    }
  });

  test('syncs and caches a new Cloud Worker descriptor generically', () async {
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      trustRefresher: () async {},
      workerCatalogLoader: () async => [
        {
          'workerTypeId': 'claude',
          'displayName': 'Claude',
          'description': 'Claude Code CLI integration',
          'profileDefinitionId': 'claude-code',
          'providerToolName': 'claude',
          'engineFamily': 'cli',
          'visibilityState': 'visible',
          'releaseStage': 'testing',
          'sortOrder': 5,
        },
      ],
    );
    try {
      final entries = await catalog.syncCatalog();
      expect(entries.single.workerTypeId, 'claude');
      expect(catalog.profileDefinitionForWorker('claude'), 'claude-code');
      final registry = LocalWorkerRegistry(
        dataDirectory: Directory('${temporary.path}/workspace'),
        workspaceId: 'workspace-fixture',
      );
      final worker = await registry.create(catalogEntry: entries.single);
      expect(worker.workerTypeId, 'claude');
      catalog.close();

      final restarted = ToolProfileCatalogClient(
        cloudUri: Uri.https('cloud.example', '/'),
        store: store,
        trustPolicy: signing.trustPolicy,
        trustRefresher: () async {},
      );
      expect((await restarted.loadCatalog()).single.displayName, 'Claude');
      restarted.close();
    } finally {
      catalog.close();
    }
  });

  test('loads the canonical Cloud Worker catalog endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Uri requestUri;
    late String authorization;
    server.listen((request) async {
      requestUri = request.uri;
      authorization = request.headers.value(HttpHeaders.authorizationHeader)!;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'channel': 'beta',
        'workers': [
          {
            'workerTypeId': 'claude',
            'displayName': 'Claude',
            'description': 'Claude Code CLI integration',
            'profileDefinitionId': 'claude-code',
            'providerToolName': 'claude',
            'engineFamily': 'cli',
            'visibilityState': 'visible',
            'releaseStage': 'beta',
            'sortOrder': 5,
          },
        ],
      }));
      await request.response.close();
    });

    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.parse('http://${server.address.address}:${server.port}'),
      workspaceRuntimeId: 'runtime-1',
      authToken: 'runtime-token',
      store: store,
      trustPolicy: signing.trustPolicy,
    );
    try {
      expect((await catalog.syncCatalog()).single.displayName, 'Claude');
      expect(requestUri.path, '/api/workspace-runtime/workers/catalog');
      expect(requestUri.queryParameters, {'workspaceRuntimeId': 'runtime-1'});
      expect(authorization, 'Bearer runtime-token');
    } finally {
      catalog.close();
      await server.close(force: true);
    }
  });

  test('fetches only a locally verified V9 current Worker Profile', () async {
    final currentProfile =
        jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
    currentProfile['logicalWorkerTypeId'] = 'fixture-worker';
    final digest =
        sha256.convert(utf8.encode(canonicalJson(currentProfile))).toString();
    const revision = 4;
    final message = workerProfileSigningMessage(
      publisher: fixturePublisher,
      signingKeyId: fixtureKeyId,
      workerTypeId: 'fixture-worker',
      revision: revision,
      schemaVersion: currentProfile['schemaVersion']! as int,
      payloadDigest: digest,
    );
    final signature = base64.encode(
      (await Ed25519().sign(utf8.encode(message), keyPair: signing.pair)).bytes,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Uri requestUri;
    server.listen((request) async {
      requestUri = request.uri;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'workerTypeId': 'fixture-worker',
        'schemaVersion': currentProfile['schemaVersion'],
        'profile': currentProfile,
        'revision': revision,
        'digest': digest,
        'signature': signature,
        'signingKeyId': fixtureKeyId,
        'publisher': fixturePublisher,
        'verified': true,
      }));
      await request.response.close();
    });

    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.parse('http://${server.address.address}:${server.port}'),
      workspaceRuntimeId: 'runtime-1',
      authToken: 'runtime-token',
      store: store,
      trustPolicy: signing.trustPolicy,
    );
    try {
      final admitted =
          await catalog.fetchCurrentWorkerProfile('fixture-worker');
      expect(admitted.revision, revision);
      expect(admitted.payloadDigest, digest);
      expect(requestUri.path, '/api/workers/fixture-worker/profile');
      expect(requestUri.queryParameters, {'workspaceRuntimeId': 'runtime-1'});
    } finally {
      catalog.close();
      await server.close(force: true);
    }
  });

  test('loads the human catalog endpoint while runtime is disconnected',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late Uri requestUri;
    late String authorization;
    server.listen((request) async {
      requestUri = request.uri;
      authorization = request.headers.value(HttpHeaders.authorizationHeader)!;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'workers': [
          {
            'workerTypeId': 'claude',
            'displayName': 'Claude',
            'description': 'Claude Code CLI integration',
            'profileDefinitionId': 'claude-code',
            'providerToolName': 'claude',
            'engineFamily': 'cli',
            'visibilityState': 'visible',
            'releaseStage': 'stable',
            'sortOrder': 5,
          },
        ],
      }));
      await request.response.close();
    });

    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.parse('http://${server.address.address}:${server.port}'),
      humanAuthToken: 'human-token',
      store: store,
      trustPolicy: signing.trustPolicy,
    );
    try {
      expect((await catalog.syncCatalog()).single.displayName, 'Claude');
      expect(requestUri.path, '/api/workers/catalog');
      expect(requestUri.queryParameters, isEmpty);
      expect(authorization, 'Bearer human-token');
    } finally {
      catalog.close();
      await server.close(force: true);
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

  test('reports cached releases whose signing key is not trusted', () async {
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

    final issues =
        await workspaceWithoutKey.untrustedReleaseTrustIssues('fixture-cli');
    expect(issues, hasLength(1));
    expect(issues.single.publisher, fixturePublisher);
    expect(issues.single.signingKeyId, fixtureKeyId);
    expect(issues.single.releaseVersions, [1]);
  });

  test('refreshes trust before syncing and preserves the active V9 Profile',
      () async {
    Future<WorkerProfileSnapshotAdmission> makeSnapshot(int revision) async {
      final snapshotProfile =
          jsonDecode(jsonEncode(profile)) as Map<String, Object?>
            ..['logicalWorkerTypeId'] = 'fixture-worker'
            ..['releaseVersion'] = revision;
      return workerProfileSnapshotFixture(
        signing: signing,
        profile: snapshotProfile,
        workerTypeId: 'fixture-worker',
        revision: revision,
      );
    }

    var candidate = await makeSnapshot(1);
    var trustRefreshed = false;
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.https('cloud.example', '/'),
      store: store,
      trustPolicy: signing.trustPolicy,
      trustRefresher: () async {
        trustRefreshed = true;
      },
      currentProfileLoader: (workerTypeId) async {
        expect(trustRefreshed, isTrue);
        expect(workerTypeId, 'fixture-worker');
        return candidate;
      },
      candidateValidator: (candidate, file) async {
        expect(await file.exists(), isTrue);
        return candidate.revision != 3;
      },
    );
    try {
      final results = await catalog.syncWorkerProfiles('fixture-worker');
      expect(results, hasLength(1));
      expect(trustRefreshed, isTrue);
      expect(
        (await store.currentWorkerProfile('fixture-worker'))?.revision,
        1,
      );
      candidate = await makeSnapshot(2);
      await catalog.syncWorkerProfiles('fixture-worker');
      expect(
        (await store.currentWorkerProfile('fixture-worker'))?.revision,
        2,
      );
      candidate = await makeSnapshot(3);
      await catalog.syncWorkerProfiles('fixture-worker');
      expect(
        (await store.currentWorkerProfile('fixture-worker'))?.revision,
        2,
      );
    } finally {
      catalog.close();
    }
  });
}

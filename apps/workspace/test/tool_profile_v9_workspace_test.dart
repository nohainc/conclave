import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show
        WorkerProfileSnapshotAdmission,
        canonicalJson,
        workerProfileSigningMessage;
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/worker_profile_store.dart';
import 'package:conclave_workspace/tool_profile_resolver.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Ed25519ReleaseFixture signing;
  late Directory temporary;
  late WorkerProfileStore store;
  late Map<String, Object?> profile;

  setUp(() async {
    signing = await Ed25519ReleaseFixture.create();
    temporary = await Directory.systemTemp.createTemp('conclave-profile-v9-');
    store = WorkerProfileStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: signing.trustPolicy,
    );
    profile = jsonDecode(
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
  });

  tearDown(() => temporary.delete(recursive: true));

  Future<WorkerProfileSnapshotAdmission> snapshot(int revision) async {
    final payload = jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
    final digest =
        sha256.convert(utf8.encode(canonicalJson(payload))).toString();
    final message = workerProfileSigningMessage(
      publisher: fixturePublisher,
      signingKeyId: fixtureKeyId,
      workerTypeId: 'fixture-worker',
      revision: revision,
      schemaVersion: payload['schemaVersion']! as int,
      payloadDigest: digest,
    );
    final signature = base64.encode(
      (await Ed25519().sign(utf8.encode(message), keyPair: signing.pair)).bytes,
    );
    return WorkerProfileSnapshotAdmission(
      profile: payload,
      workerTypeId: 'fixture-worker',
      revision: revision,
      payloadDigest: digest,
      signature: signature,
      signingKeyId: fixtureKeyId,
      publisher: fixturePublisher,
    );
  }

  test('keeps only current and one last-known-good V9 snapshot', () async {
    final first = await store.stageWorkerProfile(await snapshot(1));
    await store.activateWorkerProfile(first);
    final second = await store.stageWorkerProfile(await snapshot(2));
    await store.activateWorkerProfile(second);

    expect((await store.currentWorkerProfile('fixture-worker'))?.revision, 2);
    expect(
      (await store.lastKnownGoodWorkerProfile('fixture-worker'))?.revision,
      1,
    );
    final files = <String>{};
    await for (final entity in store
        .workerProfileDirectory('fixture-worker')
        .list(followLinks: false)) {
      if (entity is File) {
        files.add(entity.path.split(Platform.pathSeparator).last);
      }
    }
    expect(
      files,
      containsAll(<String>{
        'current.json',
        'current-profile.json',
        'last-known-good.json',
        'last-known-good-profile.json',
      }),
    );
  });

  test('revoked current snapshot cannot fall through to last-known-good',
      () async {
    final first = await store.stageWorkerProfile(await snapshot(1));
    await store.activateWorkerProfile(first);
    final second = await store.stageWorkerProfile(await snapshot(2));
    await store.activateWorkerProfile(second);
    signing.trustPolicy.updateRevocations(digests: {second.payloadDigest});

    final resolution = await ToolProfileResolver(store).resolveForWorker(
      logicalWorkerTypeId: 'fixture-worker',
      profileDefinitionId: 'fixture-cli',
      engineVersion: '1.5.0',
    );
    expect(resolution.release, isNull);
    expect(resolution.reason, ToolProfileUnavailableReason.noEligibleRelease);
  });

  test('catalog V9 sync publishes the fetched current snapshot directly',
      () async {
    final candidate = await snapshot(1);
    var validated = 0;
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.parse('https://cloud.example'),
      store: store,
      trustPolicy: signing.trustPolicy,
      currentProfileLoader: (_) async => candidate,
      candidateValidator: (value, file) async {
        validated++;
        return value is WorkerProfileSnapshotAdmission && await file.exists();
      },
      trustRefresher: () async {},
    );
    addTearDown(catalog.close);

    final result = await catalog.syncWorkerProfiles('fixture-worker');

    expect(validated, 1);
    expect(result.single, isA<WorkerProfileSnapshotAdmission>());
    expect((await store.currentWorkerProfile('fixture-worker'))?.revision, 1);
  });

  test('migrates the approved legacy stable snapshot into V9 cache', () async {
    final legacyDefinition = Directory(
      '${store.profilesRoot.path}${Platform.pathSeparator}fixture-cli',
    );
    final legacyRelease = Directory(
      '${legacyDefinition.path}${Platform.pathSeparator}1',
    );
    await legacyRelease.create(recursive: true);
    final legacy = <String, Object?>{
      'profileDefinitionId': 'fixture-cli',
      'workerTypeId': 'fixture-worker',
      'displayName': 'Fixture CLI',
      'providerToolName': 'Fixture CLI',
      'channel': 'stable',
      'releaseVersion': 1,
      'profile': profile,
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
    };
    await signing.signToolProfileRelease(legacy);
    await File(
            '${legacyDefinition.path}${Platform.pathSeparator}release-state.json')
        .writeAsString(canonicalJson({
      'schemaVersion': 1,
      'activeVersion': 1,
      'stableVersion': 1,
      'selectedChannel': 'stable',
    }));
    await File('${legacyRelease.path}${Platform.pathSeparator}release.json')
        .writeAsString(canonicalJson(legacy));
    await File('${legacyRelease.path}${Platform.pathSeparator}profile.json')
        .writeAsString(canonicalJson(profile));

    final migrated = await store.currentWorkerProfile('fixture-worker');

    expect(migrated?.revision, 1);
    expect(await legacyDefinition.exists(), isFalse,
        reason:
            'Legacy per-release cache must not remain active after migration.');
    final migratedSnapshot = File(
      '${store.workerProfileDirectory('fixture-worker').path}'
      '${Platform.pathSeparator}current.json',
    );
    expect(jsonDecode(await migratedSnapshot.readAsString())['signatureDomain'],
        'conclave-tool-profile-release-v1');
  });

  test('keeps an immutable execution snapshot across activation', () async {
    final first = await snapshot(1);
    await store.activateWorkerProfile(await store.stageWorkerProfile(first));
    final pinned = await store.executionProfileFile(first);

    final second = await snapshot(2);
    await store.activateWorkerProfile(await store.stageWorkerProfile(second));

    expect(await pinned.readAsString(), canonicalJson(first.profile));
    expect(
      pinned.path,
      contains('${Platform.pathSeparator}revisions${Platform.pathSeparator}'),
    );
    expect((await store.currentWorkerProfile('fixture-worker'))?.revision, 2);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show WorkerProfileSnapshotAdmission, WorkerTrustPolicy, canonicalJson;
import 'package:crypto/crypto.dart';
import 'package:conclave_workspace/worker_profile_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late WorkerProfileStore store;
  late Map<String, Object?> profile;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('conclave-profile-v9-');
    store = WorkerProfileStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: WorkerTrustPolicy(),
    );
    profile = jsonDecode(
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
  });

  tearDown(() => temporary.delete(recursive: true));

  Future<WorkerProfileSnapshotAdmission> snapshot(int revision) async {
    final payload = jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
    payload['logicalWorkerTypeId'] = 'fixture-worker';
    payload['releaseVersion'] = revision;
    final digest =
        sha256.convert(utf8.encode(canonicalJson(payload))).toString();
    return WorkerProfileSnapshotAdmission(
      profile: payload,
      workerTypeId: 'fixture-worker',
      revision: revision,
      payloadDigest: digest,
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
    store.trustPolicy.updateRevocations(digests: {second.payloadDigest});

    await expectLater(
      store.currentWorkerProfile('fixture-worker'),
      throwsA(isA<WorkerProfileRevokedException>()),
    );
    expect(
      (await store.lastKnownGoodWorkerProfile('fixture-worker'))?.revision,
      1,
    );
  });

  test('migrates a legacy stable snapshot without signing metadata', () async {
    final legacyDefinition = Directory(
      '${store.profilesRoot.path}${Platform.pathSeparator}fixture-cli',
    );
    final legacyRelease = Directory(
      '${legacyDefinition.path}${Platform.pathSeparator}1',
    );
    await legacyRelease.create(recursive: true);
    final legacyProfile = {
      ...profile,
      'logicalWorkerTypeId': 'fixture-worker',
    };
    final legacy = <String, Object?>{
      'profileDefinitionId': 'fixture-cli',
      'workerTypeId': 'fixture-worker',
      'providerToolName':
          (legacyProfile['providerTool'] as Map)['name'],
      'channel': 'stable',
      'releaseVersion': 1,
      'payloadDigest': sha256
          .convert(utf8.encode(canonicalJson(legacyProfile)))
          .toString(),
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
      'profile': legacyProfile,
    };
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

    final migrated = await store.currentWorkerProfile('fixture-worker');

    expect(migrated?.revision, 1);
    expect(await legacyDefinition.exists(), isFalse);
    final migratedSnapshot = File(
      '${store.workerProfileDirectory('fixture-worker').path}'
      '${Platform.pathSeparator}current.json',
    );
    final decoded = jsonDecode(await migratedSnapshot.readAsString()) as Map;
    expect(decoded.keys, isNot(contains('signature')));
    expect(decoded.keys, isNot(contains('signingKeyId')));
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

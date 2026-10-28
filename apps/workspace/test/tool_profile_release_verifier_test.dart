import 'dart:convert';

import 'package:syntila_tool_profile_v1/tool_profile_v1.dart'
    show
        ToolProfileReleaseVerifier,
        WorkerProfileSnapshotVerifier,
        canonicalJson;
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/worker_profile_fixture.dart';

void main() {
  late Map<String, Object?> profile;
  late Map<String, Object?> release;
  late String workerTypeId;

  setUp(() {
    profile = buildTestWorkerProfile();
    workerTypeId = profile['logicalWorkerTypeId']! as String;
    final providerTool = profile['providerTool']! as Map<String, Object?>;
    release = {
      'profileDefinitionId': profile['profileDefinitionId'],
      'workerTypeId': workerTypeId,
      'releaseVersion': profile['releaseVersion'],
      'channel': 'stable',
      'providerToolName': providerTool['name'],
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
      'profile': profile,
      'payloadDigest':
          sha256.convert(utf8.encode(canonicalJson(profile))).toString(),
    };
  });

  test('admits an intact legacy envelope by digest and identity', () async {
    final admitted = await ToolProfileReleaseVerifier.verify(
      input: release,
      expectedWorkerTypeId: workerTypeId,
    );
    expect(admitted.payloadDigest, release['payloadDigest']);
    expect(admitted.providerToolName, release['providerToolName']);
    expect(
      () => (admitted.profile['providerTool']! as Map)['name'] = 'tampered',
      throwsUnsupportedError,
    );
  });

  test('rejects payload mutation even when envelope metadata is unchanged',
      () async {
    final altered = jsonDecode(jsonEncode(release)) as Map<String, Object?>;
    final alteredProfile = altered['profile']! as Map<String, Object?>;
    (alteredProfile['providerTool']! as Map<String, Object?>)['name'] =
        'changed-cli';
    await expectLater(
      ToolProfileReleaseVerifier.verify(
        input: altered,
        expectedWorkerTypeId: workerTypeId,
      ),
      throwsA(anything),
    );
  });

  test('rejects altered identity and compatibility metadata', () async {
    for (final field in [
      'profileDefinitionId',
      'workerTypeId',
      'releaseVersion',
      'providerToolName',
      'engineCompatibility',
    ]) {
      final altered = jsonDecode(jsonEncode(release)) as Map<String, Object?>;
      altered[field] = switch (field) {
        'releaseVersion' => 9,
        'engineCompatibility' => {'min': '99.0.0', 'maxExclusive': '100.0.0'},
        _ => 'altered-value',
      };
      await expectLater(
        ToolProfileReleaseVerifier.verify(
          input: altered,
          expectedWorkerTypeId: workerTypeId,
        ),
        throwsA(anything),
      );
    }
  });

  test('allows lifecycle metadata to remain outside the Profile payload',
      () async {
    final promoted = jsonDecode(jsonEncode(release)) as Map<String, Object?>;
    promoted['channel'] = 'beta';
    final admitted = await ToolProfileReleaseVerifier.verify(
      input: promoted,
      expectedWorkerTypeId: workerTypeId,
    );
    expect(admitted.channel, 'beta');
  });

  test('admits an intact unsigned V9 current Worker Profile snapshot',
      () async {
    final snapshot = <String, Object?>{
      'workerTypeId': workerTypeId,
      'schemaVersion': profile['schemaVersion'],
      'profile': profile,
      'revision': 7,
      'digest': release['payloadDigest'],
    };
    final admitted = await WorkerProfileSnapshotVerifier.verify(
      input: snapshot,
      expectedWorkerTypeId: workerTypeId,
    );
    expect(admitted.revision, 7);
    expect(admitted.payloadDigest, release['payloadDigest']);
  });

  test('rejects a V9 snapshot after payload mutation', () async {
    final snapshot = <String, Object?>{
      'workerTypeId': workerTypeId,
      'schemaVersion': profile['schemaVersion'],
      'profile': jsonDecode(jsonEncode(profile)),
      'revision': 1,
      'digest': release['payloadDigest'],
    };
    (snapshot['profile']! as Map<String, Object?>)['releaseVersion'] = 99;
    await expectLater(
      WorkerProfileSnapshotVerifier.verify(
        input: snapshot,
        expectedWorkerTypeId: workerTypeId,
      ),
      throwsA(anything),
    );
  });
}

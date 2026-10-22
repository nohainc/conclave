import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show WorkerProfileSnapshotAdmission, WorkerTrustPolicy, canonicalJson;
import 'package:conclave_workspace/worker_launch_plan.dart';
import 'package:conclave_workspace/worker_profile_store.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/worker_profile_fixture.dart';

const _engineVersion = '1.3.0';
const _workerType = 'fixture-worker';
const _definition = 'fixture-cli';

void main() {
  late Directory temporary;
  late WorkerProfileStore store;
  late WorkerLaunchPlanCache cache;
  late Map<String, Object?> profile;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('conclave-launch-plan-');
    store = WorkerProfileStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: WorkerTrustPolicy(),
    );
    cache = WorkerLaunchPlanCache(store: store, engineVersion: _engineVersion);
    profile = buildTestWorkerProfile();
  });

  tearDown(() => temporary.delete(recursive: true));

  Future<WorkerProfileSnapshotAdmission> activate(int revision) async {
    final payload = jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
    payload['logicalWorkerTypeId'] = _workerType;
    payload['releaseVersion'] = revision;
    final digest =
        sha256.convert(utf8.encode(canonicalJson(payload))).toString();
    final staged = await store.stageWorkerProfile(
      WorkerProfileSnapshotAdmission(
        profile: payload,
        workerTypeId: _workerType,
        revision: revision,
        payloadDigest: digest,
      ),
    );
    final activated = await store.activateWorkerProfile(staged);
    // File timestamps have finite resolution; make the change observable.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return activated;
  }

  Future<WorkerLaunchPlanResult> resolve({String? provider = '0.3.1'}) =>
      cache.resolve(
        workerTypeId: _workerType,
        profileDefinitionId: _definition,
        providerCliVersion: provider,
      );

  test('prepares a plan once and answers later lookups from memory', () async {
    await activate(1);
    final first = await resolve();
    expect(first.isReady, isTrue);
    expect(first.fromCache, isFalse);
    expect(first.plan!.profileRevision, 1);
    expect(await first.plan!.profileFile.exists(), isTrue);

    final second = await resolve();
    expect(second.fromCache, isTrue);
    expect(identical(second.plan, first.plan), isTrue);
    expect(cache.missCount, 1);
    expect(cache.hitCount, 1);
  });

  test('concurrent lookups share one preparation', () async {
    await activate(1);
    final results = await Future.wait([resolve(), resolve(), resolve()]);
    expect(results.every((result) => result.isReady), isTrue);
    expect(cache.missCount, 1);
  });

  test('a newer Profile is picked up without changing a pinned plan', () async {
    await activate(1);
    final pinned = (await resolve()).plan!;

    await activate(2);
    final current = (await resolve()).plan!;

    expect(current.profileRevision, 2);
    expect(current.profileDigest, isNot(pinned.profileDigest));
    // The admitted plan is immutable: it still names revision 1 and its
    // immutable execution file is still on disk.
    expect(pinned.profileRevision, 1);
    expect(await pinned.profileFile.exists(), isTrue);
  });

  test('a revocation is noticed on the next lookup', () async {
    final active = await activate(1);
    expect((await resolve()).isReady, isTrue);

    store.trustPolicy.updateRevocations(digests: {active.payloadDigest});

    final result = await resolve();
    expect(result.isReady, isFalse);
    expect(result.unavailable, WorkerLaunchUnavailable.noProfile);
    expect(result.fromCache, isFalse);
  });

  test('any installed provider CLI version can launch the Profile', () async {
    await activate(1);
    final result = await resolve(provider: '9.9.9');
    expect(result.isReady, isTrue);
    expect(result.plan!.providerCliVersion, '9.9.9');
  });

  test('reports a missing Profile promptly instead of fetching one', () async {
    final stopwatch = Stopwatch()..start();
    final result = await resolve();
    stopwatch.stop();
    expect(result.unavailable, WorkerLaunchUnavailable.noProfile);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('a different provider version is a different cache entry', () async {
    await activate(1);
    expect((await resolve(provider: '0.3.1')).isReady, isTrue);
    expect((await resolve(provider: '0.3.2')).isReady, isTrue);
    expect(cache.missCount, 2);
  });
}

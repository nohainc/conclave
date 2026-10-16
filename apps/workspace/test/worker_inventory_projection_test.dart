import 'dart:convert';
import 'dart:io';

import 'package:conclave_protocol/worker_descriptor.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show canonicalJson;
import 'package:conclave_workspace/worker_inventory_projection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/worker_profile_fixture.dart';

void main() {
  late Directory directory;
  late LocalWorkerRegistry registry;

  const descriptor = WorkerDescriptor(
    workerTypeId: 'fixture-worker',
    displayName: 'Fixture CLI',
    description: 'Inventory projection fixture',
    profileDefinitionId: 'fixture-cli',
    providerToolName: 'fixture-provider',
    engineFamily: 'cli',
    visibilityState: 'visible',
    releaseStage: 'testing',
    sortOrder: 1,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('worker-inventory-');
    registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-fixture',
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('reports a catalog Worker without an eligible Profile as non-ready',
      () async {
    final worker = await registry.create(catalogEntry: descriptor);
    final readyWorker = await registry.update(
      worker.id,
      (current) => current.copyWith(
        status: LocalWorkerStatus.ready,
        readinessState: WorkerReadinessState.ready,
        toolVersion: '0.3.0',
      ),
    );

    final inventory = spaceWorkerInventory(
      worker: readyWorker,
      descriptor: descriptor,
      eligibleProfile: null,
      engineVersion: '1.0.0',
      lastSeenAt: '2026-10-03T12:00:00.000Z',
    );

    expect(inventory['readinessState'], 'worker_runtime_unavailable');
    expect(inventory['readinessIssueCode'], 'tool_profile_unavailable');
    expect(inventory['profileDefinitionId'], 'fixture-cli');
    expect(inventory['profileReleaseVersion'], isNull);
  });

  test('reports Ready only with a signed eligible Profile and Engine',
      () async {
    final profile = buildTestWorkerProfile(releaseVersion: 1);
    final release = <String, Object?>{
      'profileDefinitionId': 'fixture-cli',
      'workerTypeId': 'fixture-worker',
      'displayName': 'Fixture CLI',
      'providerToolName': 'Fixture CLI',
      'channel': 'testing',
      'releaseVersion': 1,
      'profile': profile,
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
      'payloadDigest':
          sha256.convert(utf8.encode(canonicalJson(profile))).toString(),
    };
    final eligibleProfile = await ToolProfileReleaseVerifier.verify(
      input: release,
      expectedWorkerTypeId: 'fixture-worker',
    );
    final worker = await registry.create(catalogEntry: descriptor);
    final readyWorker = await registry.update(
      worker.id,
      (current) => current.copyWith(
        status: LocalWorkerStatus.ready,
        readinessState: WorkerReadinessState.ready,
        toolVersion: '0.3.0',
      ),
    );

    final inventory = spaceWorkerInventory(
      worker: readyWorker,
      descriptor: descriptor,
      eligibleProfile: eligibleProfile,
      engineVersion: '1.0.0',
      lastSeenAt: '2026-10-03T12:00:00.000Z',
    );

    expect(inventory['readinessState'], 'ready');
    expect(inventory['profileReleaseVersion'], 1);
    expect(inventory['engineVersion'], '1.0.0');
  });

  test('a missing Engine also forces a non-ready inventory projection',
      () async {
    final worker = await registry.create(catalogEntry: descriptor);
    final readyWorker = await registry.update(
      worker.id,
      (current) => current.copyWith(
        status: LocalWorkerStatus.ready,
        readinessState: WorkerReadinessState.ready,
      ),
    );

    final inventory = spaceWorkerInventory(
      worker: readyWorker,
      descriptor: descriptor,
      eligibleProfile: null,
      engineVersion: null,
      lastSeenAt: '2026-10-03T12:00:00.000Z',
    );

    expect(inventory['readinessState'], 'worker_runtime_unavailable');
    expect(inventory['readinessIssueCode'], 'cli_worker_engine_unavailable');
    expect(inventory['engineVersion'], isNull);
  });
}

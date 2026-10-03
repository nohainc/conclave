import 'dart:convert';
import 'dart:io';

import 'package:conclave_protocol/worker_descriptor.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:conclave_workspace/worker_inventory_projection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ed25519_release_fixture.dart';

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
    capabilities: ['text', 'workstream_read'],
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

    final inventory = projectWorkerInventory(
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
    expect(inventory['capabilities'], isEmpty);
  });

  test('reports Ready only with a signed eligible Profile and Engine',
      () async {
    final signing = await Ed25519ReleaseFixture.create();
    final profile = jsonDecode(
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
    profile['releaseVersion'] = 1;
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
    };
    await signing.signToolProfileRelease(release);
    final eligibleProfile = await ToolProfileReleaseVerifier.verify(
      input: release,
      trustPolicy: signing.trustPolicy,
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

    final inventory = projectWorkerInventory(
      worker: readyWorker,
      descriptor: descriptor,
      eligibleProfile: eligibleProfile,
      engineVersion: '1.0.0',
      lastSeenAt: '2026-10-03T12:00:00.000Z',
    );

    expect(inventory['readinessState'], 'ready');
    expect(inventory['profileReleaseVersion'], 1);
    expect(inventory['engineVersion'], '1.0.0');
    expect(inventory['capabilities'],
        ['authorized_context_read', 'text', 'workstream_read']);
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

    final inventory = projectWorkerInventory(
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

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/worker_inventory_projection.dart';
import 'support/logical_worker_catalog_fixture.dart';

void main() {
  test('discovery survives registry restart without enabling a disabled Worker',
      () async {
    final dir = await Directory.systemTemp.createTemp('worker-models-');
    addTearDown(() => dir.delete(recursive: true));
    final registry =
        LocalWorkerRegistry(dataDirectory: dir, workspaceId: 'workspace-1');
    final worker = await registry.create(
        catalogEntry: logicalWorkerCatalogFixture('gemini'));
    final catalog = DiscoveredModelCatalog(
        profileDigest: 'a' * 64,
        providerToolVersion: '1.3.3',
        discoveredAt: '2026-10-11T00:00:00Z',
        models: [
          DiscoveredModel(id: 'gemini-example-low', name: 'Example (Low)')
        ]);
    await registry.update(
        worker.id,
        (w) => w.copyWith(
            modelCatalog: catalog,
            activationState: LocalWorkerActivationState.disabled,
            lastLiveTestProfileDigest: catalog.profileDigest,
            lastLiveTestToolVersion: catalog.providerToolVersion));
    final restored = (await LocalWorkerRegistry(
                dataDirectory: dir, workspaceId: 'workspace-1')
            .list())
        .single;
    expect(restored.modelCatalog!.toJson(), catalog.toJson());
    expect(restored.activationState, LocalWorkerActivationState.disabled);
    expect(restored.lastLiveTestProfileDigest, catalog.profileDigest);
  });
  test(
      'passive discovery is not authentication, and live evidence is identity bound',
      () async {
    final profile = LocalDraftProfileCandidate.fromProfileMap(Map<String,
        Object?>.from(jsonDecode(await File(
            '../../packages/tool-profile/test/fixtures/gemini-antigravity.v2.json')
        .readAsString()) as Map));
    final worker = LocalWorker(
        id: 'worker-1',
        workspaceId: 'workspace-1',
        workerTypeId: 'gemini',
        localPermissions: [],
        localConcurrencyLimit: 1,
        status: LocalWorkerStatus.needsAttention,
        revision: 1,
        createdAt: 'now',
        updatedAt: 'now');
    final probe = ProbeResult(
        requestId: 'probe',
        mode: WorkerProbeMode.passive,
        ready: true,
        providerToolName: 'AGY',
        providerToolVersion: '1.3.3',
        checks: []);
    expect(
        profileProbeReadiness(
            worker, profile, probe, LocalWorkerProbeMode.passive),
        WorkerReadinessState.notProbed);
    final tested = worker.copyWith(
        lastLiveTestPassed: true,
        lastLiveTestProfileDigest: profile.payloadDigest,
        lastLiveTestToolVersion: '1.3.3');
    expect(
        profileProbeReadiness(
            tested, profile, probe, LocalWorkerProbeMode.passive),
        WorkerReadinessState.ready);
    expect(
        profileProbeReadiness(
            tested.copyWith(lastLiveTestToolVersion: '1.2.16'),
            profile,
            probe,
            LocalWorkerProbeMode.passive),
        WorkerReadinessState.notProbed);
    expect(
        profileProbeReadiness(
            tested.copyWith(lastLiveTestProfileDigest: 'b' * 64),
            profile,
            probe,
            LocalWorkerProbeMode.passive),
        WorkerReadinessState.notProbed);
    expect(
        profileProbeReadiness(
            worker, profile, probe, LocalWorkerProbeMode.live),
        WorkerReadinessState.ready);
    final catalog = DiscoveredModelCatalog(
        profileDigest: profile.payloadDigest,
        providerToolVersion: '1.3.3',
        discoveredAt: '2026-10-11T00:00:00Z',
        models: [
          DiscoveredModel(id: 'gemini-example-low', name: 'Example (Low)')
        ]);
    final inventory = spaceWorkerInventory(
        worker: tested.copyWith(toolVersion: '1.3.3', modelCatalog: catalog),
        descriptor: logicalWorkerCatalogFixture('gemini'),
        eligibleProfile: profile,
        engineVersion: '1.1.0',
        lastSeenAt: '2026-10-11T00:00:00Z');
    expect(inventory['modelCatalog'], catalog.toJson());
    expect(inventory['capabilities'], isNot(contains('thread_read')));
    final stale = spaceWorkerInventory(
        worker: tested.copyWith(toolVersion: '1.2.16', modelCatalog: catalog),
        descriptor: logicalWorkerCatalogFixture('gemini'),
        eligibleProfile: profile,
        engineVersion: '1.1.0',
        lastSeenAt: '2026-10-11T00:00:00Z');
    expect(stale.containsKey('modelCatalog'), isFalse);
  });
}

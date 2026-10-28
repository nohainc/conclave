import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'support/logical_worker_catalog_fixture.dart';

DiscoveredModelCatalog catalog(
        {String digest = 'a',
        String version = '1.3.3',
        String time = '2026-10-11T00:00:00Z'}) =>
    DiscoveredModelCatalog(
        schemaVersion: 2,
        profileDigest: digest * 64,
        providerToolVersion: version,
        discoveredAt: time,
        models: [
          DiscoveredModel(
              id: 'family',
              name: 'Family',
              selectionMode: 'combined',
              supportedReasoningEfforts: ['low'],
              nativeId: 'private-native')
        ]);

Future<LocalWorkerRegistry> registry() async {
  final root = await Directory.systemTemp.createTemp('capability-lifecycle-');
  addTearDown(() => root.delete(recursive: true));
  return LocalWorkerRegistry(dataDirectory: root, workspaceId: 'workspace');
}

void main() {
  test(
      'headless startup and background polling discover both workers without management UI',
      () async {
    final store = await registry();
    for (final type in ['chatgpt', 'gemini']) {
      await store.create(catalogEntry: logicalWorkerCatalogFixture(type));
    }
    final types = <String>{};
    final repeated = Completer<void>();
    var count = 0;
    final monitor = WorkerReadinessMonitor(
        registry: store,
        refreshInterval: const Duration(milliseconds: 20),
        assessWorker: (worker) async {
          types.add(worker.workerTypeId);
          count++;
          if (count >= 4 && !repeated.isCompleted) repeated.complete();
          return WorkerReadinessAssessment(WorkerReadinessState.ready,
              modelCatalog: catalog(),
              profileDigest: 'a' * 64,
              toolVersion: '1.3.3');
        });
    await monitor.start();
    await repeated.future.timeout(const Duration(seconds: 3));
    await monitor.dispose();
    expect(types, {'chatgpt', 'gemini'});
    final restored = await LocalWorkerRegistry(
            dataDirectory: store.dataDirectory, workspaceId: 'workspace')
        .list();
    expect(restored.every((w) => w.modelCatalog != null), isTrue);
    final stopped = count;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(count, stopped);
  });

  test('deduplicates identical scopes and queues different worker refreshes',
      () async {
    final store = await registry();
    for (final type in ['chatgpt', 'gemini']) {
      await store.create(catalogEntry: logicalWorkerCatalogFixture(type));
    }
    final entered = Completer<void>(), release = Completer<void>();
    final calls = <String>[];
    final monitor = WorkerReadinessMonitor(
        registry: store,
        assessWorker: (worker) async {
          calls.add(worker.workerTypeId);
          if (calls.length == 1) {
            entered.complete();
            await release.future;
          }
          return const WorkerReadinessAssessment(WorkerReadinessState.ready);
        });
    final a = monitor.checkNow(workerTypeId: 'chatgpt');
    await entered.future;
    final duplicate = monitor.checkNow(workerTypeId: 'chatgpt');
    final b = monitor.checkNow(workerTypeId: 'gemini');
    final duplicateB = monitor.checkNow(workerTypeId: 'gemini');
    release.complete();
    await Future.wait([a, duplicate, b, duplicateB])
        .timeout(const Duration(seconds: 3));
    expect(calls, ['chatgpt', 'gemini']);
    await monitor.dispose();
  });

  test(
      'last good catalogs become stale, recover without new revision, and invalidate binding changes',
      () async {
    final store = await registry();
    final worker =
        await store.create(catalogEntry: logicalWorkerCatalogFixture('gemini'));
    var assessment = WorkerReadinessAssessment(WorkerReadinessState.ready,
        modelCatalog: catalog(), profileDigest: 'a' * 64, toolVersion: '1.3.3');
    final monitor = WorkerReadinessMonitor(
        registry: store, assessWorker: (_) async => assessment);
    await monitor.checkNow();
    final original = (await store.find(worker.id))!.modelCatalog!;
    assessment = const WorkerReadinessAssessment(
        WorkerReadinessState.testFailed,
        issueCode: 'provider_failure');
    await monitor.checkNow();
    final stale = (await store.find(worker.id))!.modelCatalog!;
    expect(stale.stale, isTrue);
    expect(stale.catalogRevision, original.catalogRevision);
    expect(stale.toJson()['stale'], isTrue);
    assessment = WorkerReadinessAssessment(WorkerReadinessState.ready,
        modelCatalog: catalog(time: '2026-10-11T01:00:00Z'),
        profileDigest: 'a' * 64,
        toolVersion: '1.3.3');
    await monitor.checkNow();
    expect((await store.find(worker.id))!.modelCatalog!.stale, isFalse);
    expect((await store.find(worker.id))!.modelCatalog!.catalogRevision,
        original.catalogRevision);
    final recoveredAt =
        (await store.find(worker.id))!.modelCatalog!.discoveredAt;
    assessment = WorkerReadinessAssessment(WorkerReadinessState.ready,
        modelCatalog: catalog(time: '2026-10-11T02:00:00Z'),
        profileDigest: 'a' * 64,
        toolVersion: '1.3.3');
    await monitor.checkNow();
    expect(
        (await store.find(worker.id))!.modelCatalog!.discoveredAt, recoveredAt);
    assessment = WorkerReadinessAssessment(WorkerReadinessState.testFailed,
        toolVersion: '1.3.4', profileDigest: 'a' * 64);
    await monitor.checkNow();
    expect((await store.find(worker.id))!.modelCatalog, isNull);
    assessment = WorkerReadinessAssessment(WorkerReadinessState.ready,
        modelCatalog: catalog(version: '1.3.4'),
        toolVersion: '1.3.4',
        profileDigest: 'a' * 64);
    await monitor.checkNow();
    assessment = WorkerReadinessAssessment(WorkerReadinessState.testFailed,
        toolVersion: '1.3.4', profileDigest: 'b' * 64);
    await monitor.checkNow();
    expect((await store.find(worker.id))!.modelCatalog, isNull);
    await monitor.dispose();
  });
  test('multiple queued scopes drain without self-wait or simultaneous probes',
      () async {
    final store = await registry();
    for (final type in ['chatgpt', 'gemini']) {
      await store.create(catalogEntry: logicalWorkerCatalogFixture(type));
    }
    final entered = Completer<void>(), release = Completer<void>();
    var active = 0, maximum = 0, calls = 0;
    final monitor = WorkerReadinessMonitor(
        registry: store,
        assessWorker: (worker) async {
          active++;
          if (active > maximum) maximum = active;
          calls++;
          if (calls == 1) {
            entered.complete();
            await release.future;
          }
          await Future<void>.delayed(Duration.zero);
          active--;
          return const WorkerReadinessAssessment(WorkerReadinessState.ready);
        });
    final first = monitor.checkNow(workerTypeId: 'chatgpt');
    await entered.future;
    final second = monitor.checkNow(workerTypeId: 'gemini');
    final all = monitor.checkNow(includeDisabled: true);
    release.complete();
    await Future.wait([first, second, all]).timeout(const Duration(seconds: 3));
    expect(maximum, 1);
    expect(calls, 4);
    await monitor.dispose();
  });
}

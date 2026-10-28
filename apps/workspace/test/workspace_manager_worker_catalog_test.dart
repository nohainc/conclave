import 'dart:io';

import 'package:test/test.dart';
import 'package:syntila_workspace/workspace_manager_worker_catalog.dart';
import 'package:syntila_workspace/worker_check_progress.dart';
import 'package:syntila_workspace/workspace_manager_ipc.dart';

void main() {
  test('per-Worker updates send one scoped command without a full refresh',
      () async {
    final requests = <(String, Map<String, Object?>)>[];
    final catalog =
        IpcWorkspaceWorkerCatalog((command, {payload = const {}}) async {
      requests.add((command, payload));
      return {'descriptors': [], 'views': [], 'localRegistryLoaded': true};
    });
    addTearDown(catalog.dispose);
    await catalog.refreshWorker('gemini');
    expect(requests, hasLength(1));
    expect(requests.single.$1, 'workers.refreshWorker');
    expect(requests.single.$2, {'workerTypeId': 'gemini'});
    expect(catalog.snapshot.localRegistryLoaded, isTrue);
  });

  test(
      'an old service gets an actionable update error without refreshing all Workers',
      () async {
    var calls = 0;
    final catalog =
        IpcWorkspaceWorkerCatalog((command, {payload = const {}}) async {
      calls++;
      throw const WorkspaceManagerProtocolException(
          'unsupported_command', 'old service');
    });
    addTearDown(catalog.dispose);
    await expectLater(
        catalog.refreshWorker('gemini'),
        throwsA(isA<WorkspaceManagerProtocolException>()
            .having((e) => e.code, 'code', 'service_update_required')
            .having((e) => e.message, 'recovery',
                contains('after active work finishes'))));
    expect(calls, 1);
  });

  test('Worker catalog refresh and activation are forwarded over IPC',
      () async {
    final commands = <(String, Map<String, Object?>)>[];
    final catalog =
        IpcWorkspaceWorkerCatalog((command, {payload = const {}}) async {
      commands.add((command, payload));
      if (command == 'workers.getCatalogSnapshot') {
        return {
          'descriptors': [
            {
              'workerTypeId': 'chatgpt',
              'displayName': 'ChatGPT',
              'description': 'ChatGPT worker',
              'engineFamily': 'cli',
              'profileDefinitionId': 'chatgpt-cli',
              'providerToolName': 'Codex CLI',
              'releaseStage': 'stable',
              'visibilityState': 'visible',
              'sortOrder': 1,
            }
          ],
          'views': const [],
          'catalogConfirmed': true,
          'localRegistryLoaded': true,
        };
      }
      return null;
    });

    await catalog.refresh();
    expect(catalog.entryForWorker('chatgpt')?.displayName, 'ChatGPT');
    expect(catalog.snapshot.localRegistryLoaded, isTrue);

    await catalog.setEnabled('worker-1', false);
    expect(commands.map((entry) => entry.$1), [
      'workers.getCatalogSnapshot',
      'workers.disableWorker',
      'workers.getCatalogSnapshot',
    ]);
    expect(commands[1].$2, {'workerId': 'worker-1'});
    catalog.dispose();
  });
  test('IPC progress is decoded but never restored from the display cache',
      () async {
    final root =
        await Directory.systemTemp.createTemp('worker-progress-cache-');
    addTearDown(() => root.delete(recursive: true));
    final cache = File('${root.path}/catalog.json');
    final catalog = IpcWorkspaceWorkerCatalog(
        (_, {payload = const {}}) async => null,
        cacheFile: cache);
    catalog.acceptSnapshot({
      'checks': {
        'chatgpt': const WorkerCheckProgress(
                mode: 'live',
                phase: WorkerCheckPhase.probe,
                outcome: WorkerCheckOutcome.running,
                startedAt: '2026-10-19T12:00:00Z')
            .toJson(),
        'future-worker': {'schemaVersion': 99},
      }
    });
    expect(catalog.snapshot.checks['chatgpt']!.phase, WorkerCheckPhase.probe);
    expect(catalog.snapshot.checks, hasLength(1));
    final restored = IpcWorkspaceWorkerCatalog(
        (_, {payload = const {}}) async => null,
        cacheFile: cache);
    expect(restored.snapshot.checks, isEmpty);
    restored.dispose();
    catalog.dispose();
  });

  test('last service catalog is restored without issuing commands', () async {
    final root = await Directory.systemTemp.createTemp('worker-display-cache-');
    addTearDown(() => root.delete(recursive: true));
    final cache = File('${root.path}/catalog.json');
    final catalog = IpcWorkspaceWorkerCatalog(
        (_, {payload = const {}}) async => null,
        cacheFile: cache);
    catalog.acceptSnapshot({
      'descriptors': [],
      'views': [],
      'catalogConfirmed': true,
      'localRegistryLoaded': true,
    });
    catalog.dispose();
    var requests = 0;
    final restored = IpcWorkspaceWorkerCatalog((_, {payload = const {}}) async {
      requests++;
      return null;
    }, cacheFile: cache);
    expect(restored.snapshot.catalogConfirmed, isTrue);
    expect(restored.snapshot.localRegistryLoaded, isTrue);
    expect(requests, 0);
    restored.dispose();
  });
}

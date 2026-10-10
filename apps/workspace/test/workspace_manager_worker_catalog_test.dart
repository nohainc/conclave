import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_workspace/workspace_manager_worker_catalog.dart';

void main() {
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
              'capabilities': ['text'],
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

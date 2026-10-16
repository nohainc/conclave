import 'dart:io';

import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:test/test.dart';

void main() {
  test('local Worker setup has a stable identity before Cloud registration',
      () async {
    final dataDirectory =
        await Directory.systemTemp.createTemp('workspace-local-identity-');
    addTearDown(() => dataDirectory.delete(recursive: true));

    final identityStore = LocalWorkspaceIdentityStore(dataDirectory);
    final localId = await identityStore.getOrCreate();
    final registry = LocalWorkerRegistry(
      dataDirectory: dataDirectory,
      workspaceId: localId,
    );
    final worker = await registry.create(
      catalogEntry: WorkerDescriptor(
        workerTypeId: 'chatgpt',
        displayName: 'ChatGPT',
        description: '',
        profileDefinitionId: 'chatgpt-codex',
        providerToolName: 'codex',
        engineFamily: 'cli',
        visibilityState: 'visible',
        releaseStage: 'testing',
        sortOrder: 0,
      ),
    );

    expect(worker.workspaceId, startsWith('local-'));
    expect(await identityStore.getOrCreate(initialIdentity: 'cloud-workspace'),
        localId);
    expect((await registry.find(worker.id))?.workspaceId, localId);

    // If local-workspace-id was cleared or overwritten during an account release
    // and re-claim while configured-workers.json was preserved, getOrCreate
    // reconciles back to the preserved Worker records' workspaceId so startup
    // does not fail with LocalWorkerRegistryCorrupt.
    await identityStore.file.writeAsString('ws-new-cloud-id', flush: true);
    final reconciledId =
        await identityStore.getOrCreate(initialIdentity: 'ws-new-cloud-id');
    expect(reconciledId, localId);
    final reloadedRegistry = LocalWorkerRegistry(
      dataDirectory: dataDirectory,
      workspaceId: reconciledId,
    );
    expect((await reloadedRegistry.list()).single.id, worker.id);
  });
}

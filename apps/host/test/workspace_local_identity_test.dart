import 'dart:io';

import 'package:conclave_host/local_worker_registry.dart';
import 'package:conclave_host/host_configuration.dart';
import 'package:conclave_host/tool_profile_catalog.dart';
import 'package:test/test.dart';

void main() {
  test('local Worker setup has a stable identity before Cloud pairing',
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
      catalogEntry: LogicalWorkerCatalogEntry(
        workerTypeId: 'chatgpt',
        displayName: 'ChatGPT',
        description: '',
        profileDefinitionId: 'chatgpt-codex',
        providerToolName: 'codex',
        engineFamily: 'cli',
        releaseStage: 'testing',
        capabilities: const ['text'],
        sortOrder: 0,
      ),
    );

    expect(worker.workspaceId, startsWith('local-'));
    expect(await identityStore.getOrCreate(initialIdentity: 'cloud-workspace'),
        localId);
    expect((await registry.find(worker.id))?.workspaceId, localId);
  });
}

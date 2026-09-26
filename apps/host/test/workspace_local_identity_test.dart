import 'dart:io';

import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/host_configuration.dart';
import 'package:test/test.dart';

void main() {
  test('local Worker setup has a stable identity before Cloud pairing',
      () async {
    final dataDirectory =
        await Directory.systemTemp.createTemp('workspace-local-identity-');
    addTearDown(() => dataDirectory.delete(recursive: true));

    final identityStore = LocalWorkspaceIdentityStore(dataDirectory);
    final localId = await identityStore.getOrCreate();
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: dataDirectory,
      workspaceId: localId,
    );
    final worker = await registry.create(
      name: 'Personal Codex',
      workerTypeId: 'codex',
      authStrategy: 'browser_auth',
      credentialStatus: LocalWorkerCredentialStatus.notRequired,
    );

    expect(worker.workspaceId, startsWith('local-'));
    expect(await identityStore.getOrCreate(initialIdentity: 'cloud-workspace'),
        localId);
    expect((await registry.find(worker.id))?.workspaceId, localId);
  });
}

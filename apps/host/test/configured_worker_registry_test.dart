import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/configured_worker_registry.dart';

void main() {
  late Directory directory;
  late LocalConfiguredWorkerRegistry registry;
  var id = 0;
  var instant = DateTime.utc(2026, 9, 26);

  setUp(() async {
    id = 0;
    directory =
        await Directory.systemTemp.createTemp('conclave-worker-registry-');
    registry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      clock: () => instant,
      idGenerator: () => 'worker-${id++}',
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
      'creates local Workers, enforces local name uniqueness, and increments revisions',
      () async {
    final created = await registry.create(
      name: 'Codex Personal',
      workerTypeId: 'codex',
      authStrategy: 'browser_auth',
    );
    expect(created.revision, 1);
    final updated = await registry.update(
      created.id,
      (worker) => worker.copyWith(name: 'Codex Work'),
    );
    expect(updated.id, created.id);
    expect(updated.revision, 2);
    await registry.create(
        name: 'Gemini', workerTypeId: 'gemini-api', authStrategy: 'api_key');
    await expectLater(
      registry.create(
          name: 'codex work',
          workerTypeId: 'codex',
          authStrategy: 'browser_auth'),
      throwsArgumentError,
    );
  });

  test(
      'persists only an opaque secure-store reference and backup omits that reference',
      () async {
    final worker = await registry.create(
      name: 'OpenAI API Work',
      workerTypeId: 'openai-api',
      authStrategy: 'api_key',
      credentialRef: 'worker-credential/worker-0',
      credentialStatus: LocalWorkerCredentialStatus.ready,
      status: LocalWorkerStatus.ready,
    );
    expect(worker.credentialRef, 'worker-credential/worker-0');
    final persisted = await File(
            '${directory.path}${Platform.pathSeparator}configured-workers.json')
        .readAsString();
    expect(persisted, contains('credentialRef'));
    expect(persisted, isNot(contains('api_key_value')));
    final backup = await registry.exportBackup();
    expect(backup, isNot(contains('worker-credential/worker-0')));
    expect(backup, contains('needsAuthentication'));
  });

  test('detects registry corruption and does not silently replace it',
      () async {
    await registry.create(
        name: 'Codex', workerTypeId: 'codex', authStrategy: 'browser_auth');
    final file = File(
        '${directory.path}${Platform.pathSeparator}configured-workers.json');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    decoded['workers'][0]['name'] = 'tampered';
    await file.writeAsString(jsonEncode(decoded));
    await expectLater(
        registry.list(), throwsA(isA<LocalWorkerRegistryCorrupt>()));
  });

  test('migrates the earlier registry schema without Cloud owner identity',
      () async {
    final worker = {
      'id': 'worker-old',
      'workspaceId': 'workspace-1',
      'ownerUserId': 'old-cloud-owner',
      'name': 'Codex',
      'workerTypeId': 'codex',
      'authStrategy': 'browser_auth',
      'credentialRef': null,
      'defaultModel': null,
      'allowedModels': <String>[],
      'localPermissions': <String>[],
      'localConcurrencyLimit': 1,
      'adapterVersionPolicy': null,
      'status': LocalWorkerStatus.needsAttention.name,
      'credentialStatus': LocalWorkerCredentialStatus.needsAuthentication.name,
      'revision': 1,
      'createdAt': '2026-09-26T00:00:00.000Z',
      'updatedAt': '2026-09-26T00:00:00.000Z',
    };
    final content = jsonEncode({
      'schemaVersion': 1,
      'workers': [worker]
    });
    final checksum = sha256.convert(utf8.encode(content)).toString();
    final file = File(
        '${directory.path}${Platform.pathSeparator}configured-workers.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'workers': [worker],
      'checksum': checksum,
    }));

    expect((await registry.list()).single.id, 'worker-old');
    final migrated =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(migrated['schemaVersion'], 4);
    expect(migrated['workers'][0].containsKey('ownerUserId'), isFalse);
  });

  test(
      'keeps adapter configuration local and rejects embedded endpoint credentials',
      () async {
    final worker = await registry.create(
      name: 'Local model',
      workerTypeId: 'ollama',
      authStrategy: 'local_endpoint',
      credentialStatus: LocalWorkerCredentialStatus.notRequired,
      adapterConfig: const {'endpointUrl': 'http://localhost:11434'},
    );
    expect(worker.adapterConfig['endpointUrl'], 'http://localhost:11434');
    await expectLater(
      registry.create(
        name: 'Unsafe endpoint',
        workerTypeId: 'ollama',
        authStrategy: 'local_endpoint',
        credentialStatus: LocalWorkerCredentialStatus.notRequired,
        adapterConfig: const {
          'endpointUrl': 'http://user:password@localhost:11434',
        },
      ),
      throwsArgumentError,
    );
  });

  test('disable and remove are local lifecycle operations', () async {
    final worker = await registry.create(
        name: 'Codex', workerTypeId: 'codex', authStrategy: 'browser_auth');
    await registry.disable(worker.id);
    expect((await registry.list()).single.status, LocalWorkerStatus.disabled);
    await registry.remove(worker.id);
    expect(await registry.list(), isEmpty);
    final tombstone = (await registry.list(includeRemoved: true)).single;
    expect(tombstone.status, LocalWorkerStatus.removed);
    expect(tombstone.revision, worker.revision + 2);
    expect(tombstone.credentialRef, isNull);
    final replacement = await registry.create(
      name: 'Codex',
      workerTypeId: 'codex',
      authStrategy: 'browser_auth',
    );
    expect(replacement.id, isNot(worker.id));
  });
}

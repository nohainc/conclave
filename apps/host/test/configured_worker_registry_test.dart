import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/configured_worker_registry.dart';

void main() {
  late Directory directory;
  late LocalConfiguredWorkerRegistry registry;
  var id = 0;
  var instant = DateTime.utc(2026, 9, 30);

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

  test('persists fixed product slot identity and local operational state',
      () async {
    final worker = await registry.create(
      name: 'Ignored alias',
      workerTypeId: 'codex',
      authStrategy: 'browser_auth',
      localPermissions: const ['workspace_read'],
      localConcurrencyLimit: 2,
    );
    await registry.update(
      worker.id,
      (current) => current.copyWith(
        toolName: 'Codex CLI',
        toolPath: '/Users/test/.local/bin/codex',
        toolVersion: '1.2.3',
        readinessState: WorkerReadinessState.ready,
        lastPassiveProbeAt: '2026-09-30T12:00:00.000Z',
        lastLiveTestAt: '2026-09-30T12:01:00.000Z',
        lastLiveTestPassed: true,
      ),
    );

    final document = jsonDecode(
      await File('${directory.path}/configured-workers.json').readAsString(),
    ) as Map<String, dynamic>;
    final record = (document['workers'] as List).single as Map;
    expect(document['schemaVersion'], 17);
    expect(record['workerId'], worker.id);
    expect(record['productWorkerTypeId'], 'chatgpt');
    expect(record['activationState'], 'enabled');
    expect(record['localConcurrencyLimit'], 2);
    expect(record['localPermissions'], ['workspace_read']);
    expect(record['readinessState'], 'ready');
    expect(record['providerToolName'], 'Codex CLI');
    expect(record['providerToolVersion'], '1.2.3');
    expect(record['providerToolPath'], '/Users/test/.local/bin/codex');
    for (final obsolete in [
      'name',
      'authStrategy',
      'credentialRef',
      'defaultModel',
      'allowedModels',
      'adapterConfig',
      'adapterVersionPolicy',
      'status',
      'credentialStatus',
    ]) {
      expect(record.containsKey(obsolete), isFalse, reason: obsolete);
    }
    expect((await registry.list()).single.toolPath,
        '/Users/test/.local/bin/codex');
  });

  test('rejects legacy and unknown fields in the current schema', () async {
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
    );
    expect(
      () => LocalConfiguredWorker.fromJson({
        ...worker.toJson(),
        'defaultModel': 'gpt-test',
      }),
      throwsFormatException,
    );
    expect(
      () => LocalConfiguredWorker.fromJson({
        ...worker.toJson(),
        'providerToolPath': 'relative/codex',
      }),
      throwsFormatException,
    );
  });

  test('keeps one stable slot per first-party product type', () async {
    final chatgpt = await registry.create(
      name: 'Custom name',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
    );
    expect(chatgpt.name, 'ChatGPT');
    expect(chatgpt.workerTypeId, 'chatgpt');
    await registry.create(
      name: 'Gemini',
      workerTypeId: 'gemini',
      authStrategy: 'browser_auth',
    );
    await expectLater(
      registry.create(
        name: 'Duplicate',
        workerTypeId: 'chatgpt',
        authStrategy: 'browser_auth',
      ),
      throwsArgumentError,
    );
    await expectLater(
      registry.create(
        name: 'Unsupported',
        workerTypeId: 'claude',
        authStrategy: 'browser_auth',
      ),
      throwsArgumentError,
    );
  });

  test('schema 17 resets legacy fields and preserves fixed slot IDs', () async {
    final oldRecords = [
      _legacyRecord(id: 'stable-chatgpt', type: 'codex'),
      _legacyRecord(
        id: 'duplicate-chatgpt',
        type: 'chatgpt',
        model: 'gpt-test',
      ),
      _legacyRecord(id: 'stable-gemini', type: 'antigravity'),
      _legacyRecord(id: 'old-claude', type: 'claude'),
    ];
    final file = File('${directory.path}/configured-workers.json');
    await file.writeAsString(_legacyDocument(16, oldRecords));
    final cleanedIds = <String>[];
    final removedCredentialReferences = <String>[];
    final migratingRegistry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      clock: () => instant,
      idGenerator: () => 'unused',
      onWorkerRemoving: (workerId) async => cleanedIds.add(workerId),
      onLegacyCredentialReference: (reference) async =>
          removedCredentialReferences.add(reference),
    );

    final workers = await migratingRegistry.list();
    expect(workers.map((worker) => worker.id),
        ['duplicate-chatgpt', 'stable-gemini']);
    expect(workers.map((worker) => worker.workerTypeId), ['chatgpt', 'gemini']);
    expect(workers.first.readinessIssueCode, 'worker_reconfigured');
    expect(workers.first.readinessState, WorkerReadinessState.testFailed);
    expect(workers.first.localPermissions, ['workspace_read']);
    expect(cleanedIds, containsAll(['stable-chatgpt', 'old-claude']));
    expect(
      removedCredentialReferences,
      containsAll([
        'worker-credential/stable-chatgpt',
        'worker-credential/duplicate-chatgpt',
        'worker-credential/stable-gemini',
        'worker-credential/old-claude',
      ]),
    );

    final document = jsonDecode(await file.readAsString()) as Map;
    expect(document['schemaVersion'], 17);
    final savedRecords = document['workers'] as List;
    expect(savedRecords.every((record) => record is Map), isTrue);
    expect(savedRecords.first, isNot(contains('defaultModel')));
    expect(savedRecords.first, isNot(contains('adapterConfig')));
  });

  test('removal disables a slot without creating a legacy tombstone', () async {
    final worker = await registry.create(
      name: 'Gemini',
      workerTypeId: 'gemini',
      authStrategy: 'browser_auth',
    );
    await registry.remove(worker.id);

    final restored = (await registry.list()).single;
    expect(restored.activationState, LocalWorkerActivationState.disabled);
    expect(restored.readinessIssueCode, 'worker_reconfigured');
    final saved = jsonDecode(
      await File('${directory.path}/configured-workers.json').readAsString(),
    ) as Map;
    expect((saved['workers'] as List).single, isNot(contains('status')));
  });

  test('backup uses the clean schema and excludes provider secrets', () async {
    await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
      credentialRef: 'must-not-persist',
    );
    final backup = jsonDecode(await registry.exportBackup()) as Map;
    expect(backup['schemaVersion'], 17);
    expect(jsonEncode(backup), isNot(contains('credentialRef')));
    expect(jsonEncode(backup), isNot(contains('authStrategy')));
  });
}

Map<String, Object?> _legacyRecord({
  required String id,
  required String type,
  String? model,
}) =>
    {
      'id': id,
      'workspaceId': 'workspace-1',
      'name': 'Legacy $type',
      'workerTypeId': type,
      'authStrategy': 'browser_auth',
      'credentialRef': 'worker-credential/$id',
      'defaultModel': model,
      'adapterConfig': <String, Object?>{'legacy': true},
      'allowedModels': model == null ? <String>[] : <String>[model],
      'localPermissions': <String>['workspace_read'],
      'localConcurrencyLimit': 2,
      'adapterVersionPolicy': 'latest',
      'status': 'ready',
      'readinessState': 'ready',
      'credentialStatus': 'ready',
      'revision': 4,
      'createdAt': '2026-09-26T00:00:00.000Z',
      'updatedAt': '2026-09-27T00:00:00.000Z',
    };

String _legacyDocument(int schemaVersion, List<Map<String, Object?>> workers) {
  final body = {'schemaVersion': schemaVersion, 'workers': workers};
  return jsonEncode({
    ...body,
    'checksum': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
  });
}

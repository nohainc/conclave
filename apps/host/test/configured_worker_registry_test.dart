import 'dart:async';
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

  test('uses descriptor names and enforces one Worker per type', () async {
    final created = await registry.create(
      name: 'Ignored ChatGPT alias',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
    );
    expect(created.workerTypeId, 'chatgpt');
    expect(created.name, 'ChatGPT');
    expect(created.localConcurrencyLimit, 1);
    expect(created.revision, 1);
    final updated = await registry.update(
      created.id,
      (worker) => worker.copyWith(name: 'Renamed ChatGPT'),
    );
    expect(updated.id, created.id);
    expect(updated.name, 'ChatGPT');
    expect(updated.revision, 2);
    await registry.create(
        name: 'Ignored Gemini alias',
        workerTypeId: 'gemini',
        authStrategy: 'browser_auth');
    await expectLater(
      registry.create(
          name: 'Duplicate ChatGPT',
          workerTypeId: 'chatgpt',
          authStrategy: 'browser_auth'),
      throwsArgumentError,
    );
  });

  test('migrates schema 8 Workers without last live-test fields', () async {
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
    );
    final record = worker.toJson()
      ..remove('lastLiveTestAt')
      ..remove('lastLiveTestPassed');
    final workers = [record];
    final body = {'schemaVersion': 8, 'workers': workers};
    final file = File(
      '${directory.path}${Platform.pathSeparator}configured-workers.json',
    );
    await file.writeAsString(jsonEncode({
      ...body,
      'checksum': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    }));

    final migrated = (await registry.list()).single;

    expect(migrated.lastLiveTestAt, isNull);
    expect(migrated.lastLiveTestPassed, isNull);
    final persisted = jsonDecode(await file.readAsString()) as Map;
    expect(persisted['schemaVersion'], 11);
    expect(persisted['workers'][0]['lastLiveTestAt'], isNull);
  });

  test('canonicalizes schema 9 adapter IDs and advances inventory revision',
      () async {
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
    );
    final record = worker.toJson()
      ..['workerTypeId'] = 'codex'
      ..['name'] = 'Codex'
      ..['revision'] = 7;
    final workers = [record];
    final body = {'schemaVersion': 9, 'workers': workers};
    final file = File(
      '${directory.path}${Platform.pathSeparator}configured-workers.json',
    );
    await file.writeAsString(jsonEncode({
      ...body,
      'checksum': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    }));

    final migrated = (await registry.list()).single;

    expect(migrated.workerTypeId, 'chatgpt');
    expect(migrated.name, 'ChatGPT');
    expect(migrated.revision, 8);
    final persisted = jsonDecode(await file.readAsString()) as Map;
    expect(persisted['schemaVersion'], 11);
  });

  test('migrates schema 10 registry without losing the Worker', () async {
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
    );
    final workers = [worker.toJson()];
    final body = {'schemaVersion': 10, 'workers': workers};
    final file = File(
      '${directory.path}${Platform.pathSeparator}configured-workers.json',
    );
    await file.writeAsString(jsonEncode({
      ...body,
      'checksum': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    }));

    final migrated = (await registry.list()).single;

    expect(migrated.id, worker.id);
    expect(migrated.lastLiveTestDetails, isNull);
    final persisted = jsonDecode(await file.readAsString()) as Map;
    expect(persisted['schemaVersion'], 11);
    expect(persisted['workers'][0]['lastLiveTestDetails'], isNull);
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
    expect(migrated['schemaVersion'], 11);
    expect(migrated['workers'][0].containsKey('ownerUserId'), isFalse);
  });

  test('migrates adapter type IDs and deterministically removes duplicates',
      () async {
    Map<String, Object?> record({
      required String id,
      required String name,
      required String type,
      required String status,
      required String credentialStatus,
      required String createdAt,
      String? defaultModel,
      List<String> allowedModels = const [],
    }) =>
        {
          'id': id,
          'workspaceId': 'workspace-1',
          'name': name,
          'workerTypeId': type,
          'authStrategy': 'browser_auth',
          'credentialRef': null,
          'defaultModel': defaultModel,
          'adapterConfig': <String, Object?>{},
          'allowedModels': allowedModels,
          'localPermissions': <String>[],
          'localConcurrencyLimit': 1,
          'adapterVersionPolicy': null,
          'status': status,
          'credentialStatus': credentialStatus,
          'revision': 1,
          'createdAt': createdAt,
          'updatedAt': createdAt,
        };
    final rawWorkers = [
      record(
        id: 'codex-needs-attention',
        name: 'Codex Personal',
        type: 'codex',
        status: LocalWorkerStatus.needsAttention.name,
        credentialStatus: LocalWorkerCredentialStatus.needsAuthentication.name,
        createdAt: '2026-09-26T00:00:00.000Z',
      ),
      record(
        id: 'codex-ready',
        name: 'Codex Work',
        type: 'codex',
        status: LocalWorkerStatus.ready.name,
        credentialStatus: LocalWorkerCredentialStatus.ready.name,
        createdAt: '2026-09-27T00:00:00.000Z',
        defaultModel: 'old-default',
        allowedModels: ['old-default'],
      ),
      record(
        id: 'antigravity-stable',
        name: 'Antigravity',
        type: 'antigravity',
        status: LocalWorkerStatus.needsAttention.name,
        credentialStatus: LocalWorkerCredentialStatus.needsAuthentication.name,
        createdAt: '2026-09-26T00:00:00.000Z',
      ),
    ];
    final checksumPayload = jsonEncode({
      'schemaVersion': 4,
      'workers': rawWorkers,
    });
    final file = File(
        '${directory.path}${Platform.pathSeparator}configured-workers.json');
    await file.writeAsString(jsonEncode({
      'schemaVersion': 4,
      'workers': rawWorkers,
      'checksum': sha256.convert(utf8.encode(checksumPayload)).toString(),
    }));

    final migrated = await registry.list();
    expect(migrated.map((worker) => worker.workerTypeId).toSet(),
        {'chatgpt', 'gemini'});
    expect(
        migrated.singleWhere((worker) => worker.workerTypeId == 'chatgpt').id,
        'codex-ready');
    final chatgpt =
        migrated.singleWhere((worker) => worker.workerTypeId == 'chatgpt');
    expect(chatgpt.name, 'ChatGPT');
    expect(chatgpt.revision, 2);
    expect(chatgpt.defaultModel, isNull);
    expect(chatgpt.allowedModels, isEmpty);
    final gemini =
        migrated.singleWhere((worker) => worker.workerTypeId == 'gemini');
    expect(gemini.id, 'antigravity-stable');
    expect(gemini.name, 'Gemini');
    expect(gemini.revision, 2);
    final written =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(written['schemaVersion'], 11);
    expect((written['workers'] as List), hasLength(2));
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
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
    );
    expect(replacement.id, worker.id);
    expect(replacement.revision, worker.revision + 3);
    expect((await registry.list(includeRemoved: true)), hasLength(1));
  });

  test('Worker removal awaits cancellation before writing its tombstone',
      () async {
    final cancellationStarted = Completer<void>();
    final allowCancellation = Completer<void>();
    final removingRegistry = LocalConfiguredWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      idGenerator: () => 'worker-cancel-on-remove',
      onWorkerRemoving: (_) async {
        cancellationStarted.complete();
        await allowCancellation.future;
      },
    );
    final worker = await removingRegistry.create(
      name: 'Worker',
      workerTypeId: 'codex',
      authStrategy: 'browser_auth',
      status: LocalWorkerStatus.ready,
      credentialStatus: LocalWorkerCredentialStatus.ready,
    );
    final removal = removingRegistry.remove(worker.id);
    await cancellationStarted.future;
    expect(
        (await File('${directory.path}/configured-workers.json')
            .readAsString()),
        contains('ready'));
    allowCancellation.complete();
    await removal;
    expect((await removingRegistry.find(worker.id))?.status,
        LocalWorkerStatus.removed);
  });

  test('persists only the absolute CLI path and detected version', () async {
    final worker = await registry.create(
      name: 'ChatGPT',
      workerTypeId: 'chatgpt',
      authStrategy: 'browser_auth',
      executablePath: '/opt/homebrew/bin/codex',
      cliVersion: '0.42.0',
    );
    expect(worker.executablePath, '/opt/homebrew/bin/codex');
    expect(worker.cliVersion, '0.42.0');
    final saved = await File(
      '${directory.path}${Platform.pathSeparator}configured-workers.json',
    ).readAsString();
    expect(saved, contains('"executablePath":"/opt/homebrew/bin/codex"'));
    expect(saved, contains('"cliVersion":"0.42.0"'));
    expect(saved, isNot(contains('PATH')));
    expect(saved, isNot(contains('token')));
    await expectLater(
      registry.create(
        name: 'Gemini',
        workerTypeId: 'gemini',
        authStrategy: 'browser_auth',
        executablePath: 'agy',
        cliVersion: '1.0.0',
      ),
      throwsArgumentError,
    );
  });

  test('migrates schema 7 without clearing existing local configuration',
      () async {
    final worker = {
      'id': 'worker-v7',
      'workspaceId': 'workspace-1',
      'name': 'ChatGPT',
      'workerTypeId': 'chatgpt',
      'authStrategy': 'browser_auth',
      'credentialRef': null,
      'defaultModel': 'gpt-test',
      'adapterConfig': <String, Object?>{},
      'allowedModels': <String>['gpt-test'],
      'localPermissions': <String>[],
      'localConcurrencyLimit': 1,
      'adapterVersionPolicy': null,
      'status': LocalWorkerStatus.needsAttention.name,
      'readinessState': WorkerReadinessState.testFailed.wireValue,
      'credentialStatus': LocalWorkerCredentialStatus.needsAuthentication.name,
      'revision': 1,
      'createdAt': '2026-09-26T00:00:00.000Z',
      'updatedAt': '2026-09-26T00:00:00.000Z',
    };
    final content = jsonEncode({
      'schemaVersion': 7,
      'workers': [worker]
    });
    final file = File(
      '${directory.path}${Platform.pathSeparator}configured-workers.json',
    );
    await file.writeAsString(jsonEncode({
      'schemaVersion': 7,
      'workers': [worker],
      'checksum': sha256.convert(utf8.encode(content)).toString(),
    }));
    final migrated = (await registry.list()).single;
    expect(migrated.defaultModel, 'gpt-test');
    expect(migrated.allowedModels, ['gpt-test']);
    expect(migrated.executablePath, isNull);
    final written = jsonDecode(await file.readAsString()) as Map;
    expect(written['schemaVersion'], 11);
  });
}

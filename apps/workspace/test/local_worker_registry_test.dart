import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/local_worker_permissions.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';

import 'support/logical_worker_catalog_fixture.dart';

void main() {
  late Directory directory;
  late LocalWorkerRegistry registry;
  var id = 0;
  var instant = DateTime.utc(2026, 9, 30);

  setUp(() async {
    id = 0;
    directory = await Directory.systemTemp.createTemp(
      'conclave-worker-registry-',
    );
    registry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      clock: () => instant,
      idGenerator: () => 'worker-${id++}',
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('persists only local execution state for a catalog Worker', () async {
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      localPermissions: const ['repository:read'],
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

    final document =
        jsonDecode(
              await File(
                '${directory.path}/configured-workers.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    final record = (document['workers'] as List).single as Map;
    expect(document['schemaVersion'], 19);
    expect(record['workerId'], worker.id);
    expect(record['productWorkerTypeId'], 'chatgpt');
    expect(record['activationState'], 'enabled');
    expect(record['localConcurrencyLimit'], 2);
    expect(record['localPermissions'], [
      'network:use',
      'repository:read',
      'repository:write',
      'shell:execute',
    ]);
    expect(record['fullLocalAccessAuthorized'], isTrue);
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
      'status',
      'credentialStatus',
    ]) {
      expect(record.containsKey(obsolete), isFalse, reason: obsolete);
    }
    expect(
      (await registry.list()).single.toolPath,
      '/Users/test/.local/bin/codex',
    );
  });

  test(
    'every Worker always has full local access and all permissions',
      () async {
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      localPermissions: const ['repository:read', 'shell:execute'],
    );

    expect(worker.fullLocalAccessAuthorized, isTrue);
    expect(worker.localPermissions, containsAll(executionPermissionIds));
    final reloaded = (await registry.find(worker.id))!;
    expect(reloaded.fullLocalAccessAuthorized, isTrue);
    expect(reloaded.localPermissions, containsAll(executionPermissionIds));
    },
  );

  test(
      'reset is performed by the runtime owner and shuts down local Worker instances',
      () async {
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
    );
    final removed = <String>[];
    final ownerRegistry = LocalWorkerRegistry(
      dataDirectory: directory,
      workspaceId: 'workspace-1',
      onWorkerRemoving: (workerId) async => removed.add(workerId),
    );

    await ownerRegistry.reset();

    expect(removed, [worker.id]);
    expect(await ownerRegistry.list(), isEmpty);
    },
  );

  test('rejects legacy and unknown fields in the current schema', () async {
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
    );
    expect(
      () => LocalWorker.fromJson({
        ...worker.toJson(),
        'defaultModel': 'gpt-test',
      }),
      throwsFormatException,
    );
    expect(
      () => LocalWorker.fromJson({
        ...worker.toJson(),
        'providerToolPath': 'relative/codex',
      }),
      throwsFormatException,
    );
  });

  test(
    'parallel slots are one Workspace total stored on every Worker',
      () async {
    final a = await registry.create(
        catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      );
    expect(a.localConcurrencyLimit, 5);
    expect(await registry.parallelSlots(), 5);
    final b = await registry.create(
        catalogEntry: logicalWorkerCatalogFixture('claude'),
      );
    await registry.setParallelSlots(8);
    expect(await registry.parallelSlots(), 8);
    for (final worker in await registry.list()) {
      expect(worker.localConcurrencyLimit, 8);
    }
    expect((await registry.find(a.id))!.revision, a.revision + 1);
    expect((await registry.find(b.id))!.revision, b.revision + 1);
    // A Worker added later joins the same total.
    final c = await registry.create(
        catalogEntry: logicalWorkerCatalogFixture('gemini'),
      );
    expect(c.localConcurrencyLimit, 8);
    expect(() => registry.setParallelSlots(0), throwsArgumentError);
    expect(() => registry.setParallelSlots(11), throwsArgumentError);
    },
  );

  test(
    'configured parallel slots apply before the first Worker exists',
    () async {
      final configured = LocalWorkerRegistry(
        dataDirectory: directory,
        workspaceId: 'workspace-1',
        configuredParallelSlots: 7,
        idGenerator: () => 'configured-worker',
      );

      expect(await configured.parallelSlots(), 7);
      final worker = await configured.create(
        catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      );
      expect(worker.localConcurrencyLimit, 7);
    },
  );

  test('keeps one local Worker instance per logical Worker Type', () async {
    final chatgpt = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
    );
    expect(chatgpt.workerTypeId, 'chatgpt');
    await registry.create(catalogEntry: logicalWorkerCatalogFixture('gemini'));
    await expectLater(
      registry.create(catalogEntry: logicalWorkerCatalogFixture('chatgpt')),
      throwsArgumentError,
    );
  });

  test(
    'creates logical Workers from catalog entries, including future types',
      () async {
    const entry = WorkerDescriptor(
      workerTypeId: 'approved-cli',
      displayName: 'Approved CLI',
      description: 'fixture',
      profileDefinitionId: 'approved-cli-profile',
      providerToolName: 'approved',
      engineFamily: 'cli',
      visibilityState: 'visible',
      releaseStage: 'testing',
      sortOrder: 30,
    );
    final worker = await registry.create(catalogEntry: entry);
    expect(worker.workerTypeId, 'approved-cli');
    expect(
      () => registry.create(
        catalogEntry: const WorkerDescriptor(
          workerTypeId: 'invalid',
          displayName: 'Invalid',
          description: '',
          profileDefinitionId: 'invalid-profile',
          providerToolName: 'invalid',
          engineFamily: 'native',
          visibilityState: 'visible',
          releaseStage: 'testing',
          sortOrder: 1,
        ),
      ),
      throwsArgumentError,
    );
    },
  );

  test(
      'schema reset clears registry but preserves profiles, state, and Work Root',
      () async {
    final oldDocument = jsonEncode({
      'schemaVersion': 17,
      'workers': [
        {
          'workerId': 'old-chatgpt',
          'workspaceId': 'workspace-1',
          'productWorkerTypeId': 'chatgpt',
          'authStrategy': 'browser_auth',
          'localPermissions': ['repository:read'],
          },
      ],
      'checksum': 'legacy-checksum-is-not-interpreted',
    });
    final file = File('${directory.path}/configured-workers.json');
    final preservedFiles = [
      File('${directory.path}/Profiles/worker-catalog.json'),
      File('${directory.path}/Engines/cli_worker/engine'),
      File('${directory.path}/Workers/worker-old/state/session.json'),
      File('${directory.path}/Workers/worker-old/logs/worker.jsonl'),
      File('${directory.path}/Work/thread/notes.txt'),
    ];
    for (final preserved in preservedFiles) {
      await preserved.create(recursive: true);
      await preserved.writeAsString('preserve');
    }
    await file.writeAsString(oldDocument);
    final workers = await registry.list();
    expect(workers, isEmpty);
    final reset = jsonDecode(await file.readAsString()) as Map;
    expect(reset['schemaVersion'], 19);
    expect(reset['workers'], isEmpty);
    for (final preserved in preservedFiles) {
        expect(
          await preserved.readAsString(),
          'preserve',
          reason: preserved.path,
        );
    }
    },
  );

  test('removal deletes the Worker record and its settings', () async {
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('gemini'),
    );
    await registry.remove(worker.id);

    expect(await registry.list(includeRemoved: true), isEmpty);
    final saved =
        jsonDecode(
              await File(
                '${directory.path}/configured-workers.json',
              ).readAsString(),
            )
            as Map;
    expect(saved['workers'], isEmpty);

    final readded = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('gemini'),
    );
    expect(readded.revision, 1);
  });

  test(
    'backup uses current schema and excludes provider configuration',
      () async {
    await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
    );
    final backup = jsonDecode(await registry.exportBackup()) as Map;
    expect(backup['schemaVersion'], 19);
    for (final legacy in [
      'credentialRef',
      'authStrategy',
      'defaultModel',
      'allowedModels',
      'credentialStatus',
    ]) {
      expect(jsonEncode(backup), isNot(contains(legacy)));
    }
    },
  );
}

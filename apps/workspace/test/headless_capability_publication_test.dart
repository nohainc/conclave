import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart'
    show WorkerProfileSnapshotAdmission;
import 'package:test/test.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/worker_profile_store.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'support/ed25519_release_fixture.dart';
import 'support/logical_worker_catalog_fixture.dart';
import 'support/worker_profile_snapshot_fixture.dart';

void main() {
  test('signed Codex and Gemini profiles discover and publish headlessly',
      () async {
    final root =
        await Directory.systemTemp.createTemp('headless-capabilities-');
    addTearDown(() => root.delete(recursive: true));
    final provider = File('${root.path}/provider.dart');
    await provider.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (args.contains('--version')) { stdout.writeln(args.first == 'codex' ? '0.160.0' : '1.3.3'); return; }
  if (args.contains('models')) {
    for (final version in ['3.8','3.7','3.6','3.1']) {
      for (final effort in version == '3.1' ? ['low','high'] : ['low','medium','high']) {
        stdout.writeln('gemini-$version-${version == '3.1' ? 'pro' : 'flash'}-$effort\tGemini $version $effort');
      }
    }
    return;
  }
  if (args.contains('app-server')) {
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final request = jsonDecode(line) as Map;
      final result = request['method'] == 'initialize' ? <String,Object?>{} : {
        'data':[{'id':'gpt-fixture','model':'private-codex-native','displayName':'Codex',
          'supportedReasoningEfforts':[{'reasoningEffort':'ultra'}],'defaultReasoningEffort':'ultra'}], 'nextCursor':null};
      stdout.writeln(jsonEncode({'id':request['id'],'result':result}));
    }
  }
}
''');
    final signing = await Ed25519ReleaseFixture.create();
    final store = WorkerProfileStore(
        profilesRoot: Directory('${root.path}/Profiles'),
        trustPolicy: signing.trustPolicy);
    final profiles = <String, WorkerProfileSnapshotAdmission>{};
    for (final type in ['chatgpt', 'gemini']) {
      final descriptor = logicalWorkerCatalogFixture(type);
      final profile = jsonDecode(await File(
              '../../docs/profile-templates/${descriptor.profileDefinitionId}-runtime-catalog.v1.json')
          .readAsString()) as Map<String, Object?>;
      final tool = profile['providerTool'] as Map;
      // Signed candidates use command names, not absolute paths. Locate Dart through PATH.
      tool['executableCandidates'] = ['dart'];
      (tool['discovery'] as Map)['standardLocations'] = [];
      tool['versionProbe']['arguments'] = [
        'run',
        provider.path,
        type == 'chatgpt' ? 'codex' : 'agy',
        '--version'
      ];
      (profile['probe'] as Map)['passive'] = {'checks': [], 'configChecks': []};
      ((profile['model'] as Map)['discovery'] as Map)['arguments'] = [
        'run',
        provider.path,
        type == 'chatgpt' ? 'codex' : 'agy',
        type == 'chatgpt' ? 'app-server' : 'models'
      ];
      profiles[type] = await workerProfileSnapshotFixture(
        signing: signing,
        profile: profile,
        workerTypeId: type,
        revision: 1,
      );
    }
    final engine = CliWorkerEngineSupervisor(
        engineExecutable:
            File('assets/engines/conclave_cli_worker_engine').absolute.path,
        environmentOverrides: {
          'PATH':
              '${File(_dartExecutable()).parent.path}:${Platform.environment['PATH'] ?? ''}'
        });
    final client = ToolProfileCatalogClient(
        cloudUri: Uri.parse('https://fixture.invalid'),
        store: store,
        trustPolicy: signing.trustPolicy,
        trustRefresher: () async {},
        workerCatalogLoader: () async => [
              for (final type in profiles.keys)
                logicalWorkerCatalogFixture(type).toJson()
            ],
        currentProfileLoader: (type) async => profiles[type]!,
        candidateValidator: (candidate, file) async => true);
    addTearDown(client.close);
    late final LocalWorkerRegistry registry;
    late final WorkerCatalogCoordinator coordinator;
    final published = Completer<List<Map<String, Object?>>>();
    registry = LocalWorkerRegistry(
        dataDirectory: Directory('${root.path}/Registry'),
        workspaceId: 'workspace-headless',
        onChanged: () async {
          final workers = await registry.list();
          if (workers.length != 2 ||
              workers.any((w) => w.modelCatalog == null)) {
            return;
          }
          final inventory = await coordinator.inventoryForWorkers(workers,
              engineVersion: cliWorkerEngineVersion, engineAvailable: true);
          if (!published.isCompleted) published.complete(inventory);
        });
    coordinator = WorkerCatalogCoordinator(
        catalog: client, releaseStore: store, registry: registry);
    addTearDown(coordinator.dispose);
    await coordinator.refresh(force: true);
    for (final type in profiles.keys) {
      expect(coordinator.entryForWorker(type), isNotNull,
          reason: coordinator.snapshot.catalogError);
      expect((await store.currentWorkerProfile(type))?.revision, 1,
          reason: coordinator.snapshot.profiles[type]?.message);
    }
    for (final type in profiles.keys) {
      await registry.create(catalogEntry: logicalWorkerCatalogFixture(type));
    }
    final monitor = WorkerReadinessMonitor(
        registry: registry,
        toolProfileReleaseStore: store,
        workerCatalogCoordinator: coordinator,
        cliWorkerEngineSupervisor: engine,
        workerStateDirectory: (id) => Directory('${root.path}/State/$id'),
        refreshInterval: Duration.zero);
    addTearDown(monitor.dispose);
    await monitor.start();
    await monitor.checkNow(includeDisabled: true);
    for (final worker in await registry.list()) {
      expect(worker.modelCatalog, isNotNull,
          reason:
              '${worker.workerTypeId}: ${worker.readinessIssueCode}, ${worker.toolVersion}, ${worker.lastLiveTestDetails}');
    }
    final inventory =
        await published.future.timeout(const Duration(seconds: 20));
    expect(inventory.length, 2);
    final codex = inventory.firstWhere(
        (w) => w['workerTypeId'] == 'chatgpt')['modelCatalog'] as Map;
    final gemini = inventory.firstWhere(
        (w) => w['workerTypeId'] == 'gemini')['modelCatalog'] as Map;
    expect(codex['models'], hasLength(1));
    expect((codex['models'] as List).single['efforts'], ['ultra']);
    expect(gemini['models'], hasLength(4));
    expect(
        (gemini['models'] as List)
            .fold<int>(0, (sum, m) => sum + (m['efforts'] as List).length),
        11);
    expect(jsonEncode(inventory), isNot(contains('nativeId')));
    expect(jsonEncode(inventory), isNot(contains('private-codex-native')));
    expect(jsonEncode(inventory), isNot(contains(provider.path)));
  }, timeout: const Timeout(Duration(seconds: 30)));
}

String _dartExecutable() {
  final resolved = File(Platform.resolvedExecutable);
  if (!resolved.path.endsWith('flutter_tester')) return resolved.path;
  final cache = resolved.parent.parent.parent.parent;
  return '${cache.path}/dart-sdk/bin/dart';
}

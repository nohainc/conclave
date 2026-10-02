import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/cli_worker_engine_supervisor.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/tool_profile_catalog.dart';
import 'package:conclave_host/tool_profile_release_store.dart';
import 'package:conclave_host/worker_diagnostic_store.dart';
import 'package:conclave_host/worker_readiness.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  test(
    'testing catalog entry executes its signed fixture Profile through the generic Engine',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('third-cli-profile-');
      addTearDown(() => root.delete(recursive: true));

      final signing = await Ed25519ReleaseFixture.create();
      final profileStore = ToolProfileReleaseStore(
        profilesRoot: Directory('${root.path}/Profiles'),
        trustPolicy: signing.trustPolicy,
      );
      final catalog = ToolProfileCatalogClient(
        cloudUri: Uri.https('cloud.example', '/'),
        store: profileStore,
        trustPolicy: signing.trustPolicy,
        trustRefresher: () async {},
        workerCatalogLoader: () async => [
          {
            'workerTypeId': 'fixture-worker',
            'displayName': 'Fixture CLI',
            'description': 'Testing-only generic CLI integration',
            'profileDefinitionId': 'fixture-cli',
            'providerToolName': 'Fixture CLI',
            'engineFamily': 'cli',
            'visibilityState': 'visible',
            'releaseStage': 'testing',
            'capabilities': ['text'],
            'sortOrder': 5,
          },
        ],
      );
      final entry = (await catalog.syncCatalog()).single;
      expect(
          catalog.profileDefinitionForWorker('fixture-worker'), 'fixture-cli');

      final profile = jsonDecode(
        await File(
          '$repository/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
        ).readAsString(),
      ) as Map<String, Object?>;
      final providerDirectory = Directory('${root.path}/provider-bin')
        ..createSync();
      final providerExecutable = File(
        '${providerDirectory.path}/fixture-provider'
        '${Platform.isWindows ? '.exe' : ''}',
      );
      final providerBuild = await Process.run(
        _dartExecutable(),
        [
          'compile',
          'exe',
          '$repository/packages/tool-profile/test/fixtures/fixture_provider.dart',
          '-o',
          providerExecutable.path,
        ],
        workingDirectory: repository,
        runInShell: false,
      );
      expect(providerBuild.exitCode, 0, reason: '${providerBuild.stderr}');
      final release = <String, Object?>{
        'profileDefinitionId': 'fixture-cli',
        'workerTypeId': 'fixture-worker',
        'displayName': 'Fixture CLI',
        'providerToolName': 'Fixture CLI',
        'channel': 'testing',
        'releaseVersion': 1,
        'profile': profile,
        'schemaVersion': profile['schemaVersion'],
        'engineFamily': profile['engineFamily'],
        'engineCompatibility': profile['engineCompatibility'],
      };
      await signing.signToolProfileRelease(release);
      await profileStore.installRelease(
        releaseInput: release,
        expectedWorkerTypeId: 'fixture-worker',
      );
      await profileStore.activateVersion('fixture-cli', 1);
      await profileStore.applyCatalogSelection(
        workerTypeId: 'fixture-worker',
        selectedVersionsByDefinition: const {'fixture-cli': 1},
        selectedChannel: 'testing',
      );
      expect((await profileStore.releaseState('fixture-cli')).activeVersion, 1);
      expect(
        (await profileStore.activeRelease('fixture-cli'))?.channel,
        'testing',
      );

      final registry = LocalConfiguredWorkerRegistry(
        dataDirectory: Directory('${root.path}/Registry'),
        workspaceId: 'workspace-third-cli',
        idGenerator: () => 'fixture-worker-local',
      );
      final worker = await registry.create(catalogEntry: entry);
      final bundledEngine = File(
        '$repository/apps/host/assets/engines/'
        'conclave_cli_worker_engine${Platform.isWindows ? '.exe' : ''}',
      );
      final dartDirectory = File(Platform.resolvedExecutable).parent.path;
      final inheritedPath = Platform.environment['PATH'] ?? '';
      final engine = CliWorkerEngineSupervisor(
        engineExecutable:
            bundledEngine.existsSync() ? bundledEngine.path : _dartExecutable(),
        engineArgumentsPrefix: bundledEngine.existsSync()
            ? const []
            : ['$repository/engines/cli_worker/bin/conclave_cli_worker.dart'],
        environmentOverrides: {
          'PATH': '${providerDirectory.path}${Platform.isWindows ? ';' : ':'}'
              '$dartDirectory${Platform.isWindows ? ';' : ':'}$inheritedPath',
          'HOME': root.path,
        },
      );
      final diagnostics = WorkerDiagnosticStore(
        directory: Directory('${root.path}/Diagnostics'),
      );
      final monitor = WorkerReadinessMonitor(
        registry: registry,
        toolProfileReleaseStore: profileStore,
        toolProfileCatalog: catalog,
        cliWorkerEngineSupervisor: engine,
        workerStateDirectory: (workerId) =>
            Directory('${root.path}/Workers/$workerId/state'),
        profileDiagnosticStoreForWorker: (_) => diagnostics,
      );

      await monitor.checkNow(workerTypeId: 'fixture-worker');
      final probed = (await registry.find(worker.id))!;
      expect(
        probed.readinessState,
        WorkerReadinessState.ready,
        reason: '${probed.readinessIssueCode}: ${probed.lastLiveTestDetails}',
      );
      expect(probed.toolVersion, '0.3.0');

      await monitor.checkNow(
        mode: LocalWorkerProbeMode.live,
        workerTypeId: 'fixture-worker',
      );
      final tested = (await registry.find(worker.id))!;
      expect(tested.lastLiveTestPassed, isTrue,
          reason:
              '${tested.lastLiveTestIssueCode}: ${tested.lastLiveTestDetails}');
      expect(tested.lastLiveTestAt, isNotNull);
      expect(tested.toolName, 'Fixture CLI');
      expect(tested.toolVersion, '0.3.0');

      final diagnostic = jsonDecode(
        (await diagnostics.currentFile.readAsLines()).last,
      ) as Map<String, Object?>;
      expect(diagnostic['workerTypeId'], 'fixture-worker');
      expect(diagnostic['profileDefinitionId'], 'fixture-cli');
      expect(diagnostic['profileReleaseVersion'], 1);
      await monitor.dispose();
      catalog.close();
    },
  );
}

String _dartExecutable() {
  final resolved = File(Platform.resolvedExecutable);
  if (!resolved.path.endsWith('flutter_tester')) return resolved.path;
  final cacheDirectory = resolved.parent.parent.parent.parent;
  final dart = File('${cacheDirectory.path}/dart-sdk/bin/dart');
  if (!dart.existsSync()) {
    throw StateError('Could not locate the Flutter-bundled Dart executable.');
  }
  return dart.path;
}

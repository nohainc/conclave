import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/cli_worker_engine_supervisor.dart';
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/tool_profile_catalog.dart';
import 'package:syntila_workspace/worker_profile_store.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'package:syntila_workspace/worker_catalog_coordinator.dart';
import 'package:syntila_workspace/worker_diagnostic_store.dart';

import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';
import 'support/logical_worker_catalog_fixture.dart';
import 'support/repository_root.dart';
import 'support/worker_profile_snapshot_fixture.dart';

void main() {
  for (final testCase in _readinessCases) {
    test(testCase.description, () async {
      final repository = repositoryRoot;
      final root = await Directory.systemTemp.createTemp(
        'profile-${testCase.workerTypeId}-live-',
      );
      addTearDown(() => root.delete(recursive: true));
      final signing = await Ed25519ReleaseFixture.create();
      final profileStore = WorkerProfileStore(
        profilesRoot: Directory('${root.path}/Profiles'),
        trustPolicy: signing.trustPolicy,
      );
      final profile = jsonDecode(
        await File('$repository/${testCase.fixturePath}').readAsString(),
      ) as Map<String, Object?>;
      final providerScript = await testCase.prepareProviderScript(
        repository: repository,
        root: root,
      );
      _applyCommonFixtureProviderOverrides(profile, providerScript);
      testCase.applyProviderSpecificOverrides(profile, providerScript);

      final first = await workerProfileSnapshotFixture(
        signing: signing,
        profile: profile,
        workerTypeId: testCase.workerTypeId,
        revision: 1,
      );
      await profileStore.activateWorkerProfile(
        await profileStore.stageWorkerProfile(first),
      );
      if (testCase.verifyRollbackAndDiagnostics) {
        final candidateProfile =
            jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
        candidateProfile['releaseVersion'] = 2;
        final second = await workerProfileSnapshotFixture(
          signing: signing,
          profile: candidateProfile,
          workerTypeId: testCase.workerTypeId,
          revision: 2,
        );
        await profileStore.activateWorkerProfile(
          await profileStore.stageWorkerProfile(second),
        );
      }

      final registry = LocalWorkerRegistry(
        dataDirectory: Directory('${root.path}/Registry'),
        workspaceId: 'workspace-${testCase.workerTypeId}-profile-live',
        idGenerator: () => 'disabled-${testCase.workerTypeId}',
      );
      final worker = await registry.create(
        catalogEntry: logicalWorkerCatalogFixture(testCase.workerTypeId),
        status: LocalWorkerStatus.disabled,
      );
      final catalog = ToolProfileCatalogClient(
        cloudUri: Uri.parse('https://catalog.test'),
        store: profileStore,
        trustPolicy: signing.trustPolicy,
        workerCatalogLoader: () async => [
          logicalWorkerCatalogFixture(testCase.workerTypeId).toJson(),
        ],
      );
      await catalog.syncCatalog();
      addTearDown(catalog.close);
      final bundledEngine = File(
        '$repository/apps/workspace/assets/engines/'
        'syntila-agent${Platform.isWindows ? '.exe' : ''}',
      );
      final engine = CliWorkerEngineSupervisor(
        engineExecutable: bundledEngine.existsSync()
            ? bundledEngine.path
            : Platform.environment['DART_EXECUTABLE'] ??
                Platform.resolvedExecutable,
        engineArgumentsPrefix: bundledEngine.existsSync()
            ? const []
            : ['$repository/engines/cli_worker/bin/syntila_cli_worker.dart'],
        environmentOverrides: {'HOME': root.path},
      );
      final profileDiagnostics = WorkerDiagnosticStore(
        directory: Directory('${root.path}/Diagnostics'),
      );
      final coordinator = WorkerCatalogCoordinator(
        catalog: catalog,
        releaseStore: profileStore,
        registry: registry,
      );
      final monitor = WorkerReadinessMonitor(
        registry: registry,
        toolProfileReleaseStore: profileStore,
        workerCatalogCoordinator: coordinator,
        cliWorkerEngineSupervisor: engine,
        workerStateDirectory: (workerId) =>
            Directory('${root.path}/Workers/$workerId/state'),
        profileDiagnosticStoreForWorker: (_) => profileDiagnostics,
      );
      addTearDown(monitor.dispose);

      if (testCase.verifyRollbackAndDiagnostics) {
        expect(
          await monitor.rollbackToolProfile(testCase.workerTypeId),
          isTrue,
        );
        expect(
          (await profileStore.currentWorkerProfile(testCase.workerTypeId))
              ?.revision,
          1,
        );
        expect(
          (await profileStore.lastKnownGoodWorkerProfile(testCase.workerTypeId))
              ?.revision,
          2,
        );
        expect(
          (await registry.find(worker.id))!.lastLiveTestAt,
          isNull,
          reason: 'Profile rollback must use only a passive probe.',
        );
      }

      await monitor.checkNow(
        mode: LocalWorkerProbeMode.live,
        workerTypeId: testCase.workerTypeId,
      );

      final tested = (await registry.find(worker.id))!;
      expect(
        tested.lastLiveTestPassed,
        isTrue,
        reason:
            '${tested.lastLiveTestIssueCode}: ${tested.lastLiveTestDetails} '
            'version=${tested.toolVersion}',
      );
      expect(tested.lastLiveTestAt, isNotNull);
      expect(tested.toolVersion, '0.3.0');
      expect(tested.activationState, LocalWorkerActivationState.disabled);
      expect(tested.status, LocalWorkerStatus.disabled);

      if (testCase.verifyRollbackAndDiagnostics) {
        final diagnostic = jsonDecode(
          (await profileDiagnostics.currentFile.readAsLines()).last,
        ) as Map<String, Object?>;
        expect(diagnostic['workspaceVersion'], isNotNull);
        expect(diagnostic['engineVersion'], isNotNull);
        expect(diagnostic['workerTypeId'], testCase.workerTypeId);
        expect(
          diagnostic['profileDefinitionId'],
          testCase.profileDefinitionId,
        );
        expect(diagnostic['profileReleaseVersion'], 1);
        expect(diagnostic['profileResolutionSource'], 'active');
        expect(diagnostic['probeStage'], 'live');
        expect(diagnostic['providerToolName'], isNotNull);
        expect(diagnostic['providerToolVersion'], '0.3.0');
        expect(diagnostic['durationMs'], isA<int>());
        expect(diagnostic['failureLayer'], isNull);
        expect(jsonEncode(diagnostic), isNot(contains('profilePayload')));
      }
    });
  }
}

void _applyCommonFixtureProviderOverrides(
  Map<String, Object?> profile,
  String providerScript,
) {
  final provider = profile['providerTool']! as Map<String, Object?>;
  provider['executableCandidates'] = ['dart'];
  (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
      <String>[];
  (provider['versionProbe']! as Map<String, Object?>)
    ..['arguments'] = ['run', providerScript, '--version']
    ..['timeoutMs'] = 10000;
  provider['supportedVersions'] = [
    {'min': '0.0.0', 'maxExclusive': '1.0.0'},
  ];
  // Live readiness is the Profile's usage command.
  profile['usage'] = {
    'arguments': ['run', providerScript, 'usage'],
    'timeoutMs': 60000,
  };
  profile['environment'] = {
    'passthrough': ['PATH', 'HOME'],
    'set': <String, String>{},
  };
  (profile['probe']! as Map<String, Object?>)['passive']!
      as Map<String, Object?>
    ..['checks'] = <Object?>[]
    ..['configChecks'] = <Object?>[];
}

final class _ProviderReadinessCase {
  const _ProviderReadinessCase({
    required this.description,
    required this.workerTypeId,
    required this.profileDefinitionId,
    required this.fixturePath,
    required this.verifyRollbackAndDiagnostics,
    required this.prepareProviderScript,
    required this.applyProviderSpecificOverrides,
  });

  final String description;
  final String workerTypeId;
  final String profileDefinitionId;
  final String fixturePath;
  final bool verifyRollbackAndDiagnostics;
  final Future<String> Function({
    required String repository,
    required Directory root,
  }) prepareProviderScript;
  final void Function(Map<String, Object?> profile, String providerScript)
      applyProviderSpecificOverrides;
}

final _readinessCases = <_ProviderReadinessCase>[
  _ProviderReadinessCase(
    description:
        'live readiness runs the Worker Profile through the generic Engine and keeps a disabled Worker disabled',
    workerTypeId: 'chatgpt',
    profileDefinitionId: 'chatgpt-codex',
    fixturePath: 'packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
    verifyRollbackAndDiagnostics: true,
    prepareProviderScript: ({
      required String repository,
      required Directory root,
    }) async =>
        '$repository/packages/tool-profile/test/fixtures/provider-cli/fixture_provider.dart',
    applyProviderSpecificOverrides: (profile, providerScript) {
      profile['execution'] = {
        'arguments': ['run', providerScript, 'echo', '{{prompt}}'],
        'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
        'output': {'mode': 'plain_text'},
        'events': <Object?>[],
      };
    },
  ),
  _ProviderReadinessCase(
    description:
        'Gemini live readiness uses stream-json through the generic Engine and keeps a disabled Worker disabled',
    workerTypeId: 'gemini',
    profileDefinitionId: 'gemini-antigravity',
    fixturePath:
        'packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
    verifyRollbackAndDiagnostics: false,
    prepareProviderScript: ({
      required String repository,
      required Directory root,
    }) async {
      final providerScript = '${root.path}/fixture_agy.dart';
      await File(providerScript).writeAsString(_geminiFixtureScript);
      return providerScript;
    },
    applyProviderSpecificOverrides: (profile, providerScript) {
      final execution = profile['execution']! as Map<String, Object?>;
      execution['arguments'] = [
        'run',
        providerScript,
        ...(execution['arguments']! as List<Object?>),
      ];
      profile['model'] = Map<String, Object?>.from(profile['model']! as Map)
        ..['supported'] = false
        ..['arguments'] = []
        ..remove('discovery')
        ..remove('selectionMapping');
    },
  ),
];

const _geminiFixtureScript = r'''import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('0.3.0');
    return;
  }
  if (arguments.length == 1 && arguments.single == 'usage') {
    stdout.writeln('fixture usage: ok');
    return;
  }
  await stdin.transform(utf8.decoder).join();
  stdout.writeln(jsonEncode({
    'event': 'init',
    'conversation_id': 'fixture-gemini-session',
  }));
  stdout.writeln(jsonEncode({
    'event': 'result',
    'result': {
      'status': 'SUCCESS',
      'response': 'OK',
      'conversation_id': 'fixture-gemini-session',
    },
  }));
}''';

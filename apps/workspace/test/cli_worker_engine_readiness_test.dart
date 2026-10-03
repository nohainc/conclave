import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:conclave_workspace/worker_diagnostic_store.dart';

import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';
import 'support/logical_worker_catalog_fixture.dart';

void main() {
  test(
      'live readiness runs the signed Profile through the generic Engine and keeps a disabled Worker disabled',
      () async {
    final repository = Directory.current.parent.parent.path;
    final root = await Directory.systemTemp.createTemp('profile-live-test-');
    addTearDown(() => root.delete(recursive: true));
    final signing = await Ed25519ReleaseFixture.create();
    final profileStore = ToolProfileReleaseStore(
      profilesRoot: Directory('${root.path}/Profiles'),
      trustPolicy: signing.trustPolicy,
    );
    final profile = jsonDecode(
      await File(
        '$repository/packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
      ).readAsString(),
    ) as Map<String, Object?>;
    final providerScript =
        '$repository/packages/tool-profile/test/fixtures/provider-cli/fixture_provider.dart';
    final provider = profile['providerTool']! as Map<String, Object?>;
    provider['executableCandidates'] = ['dart'];
    (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
        <String>[];
    (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
      'run',
      providerScript,
      '--version',
    ];
    (provider['versionProbe']! as Map<String, Object?>)['timeoutMs'] = 10000;
    provider['supportedVersions'] = [
      {'min': '0.0.0', 'maxExclusive': '1.0.0'},
    ];
    profile['environment'] = {
      'passthrough': ['PATH', 'HOME'],
      'set': <String, String>{},
    };
    final passive = (profile['probe']! as Map<String, Object?>)['passive']!
        as Map<String, Object?>;
    passive['checks'] = <Object?>[];
    passive['configChecks'] = <Object?>[];
    profile['execution'] = {
      'arguments': ['run', providerScript, 'echo', '{{prompt}}'],
      'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
      'output': {'mode': 'plain_text'},
      'events': <Object?>[],
    };
    final release = <String, Object?>{
      'profileDefinitionId': profile['profileDefinitionId'],
      'workerTypeId': 'chatgpt',
      'displayName': 'Codex Test Profile',
      'providerToolName': (profile['providerTool']! as Map)['name'],
      'channel': 'stable',
      'releaseVersion': profile['releaseVersion'],
      'profile': profile,
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
    };
    await signing.signToolProfileRelease(release);
    await profileStore.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'chatgpt',
    );
    await profileStore.activateVersion('chatgpt-codex', 1,
        selectAsStable: true);
    final candidateProfile =
        jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
    candidateProfile['releaseVersion'] = 2;
    final candidateRelease = <String, Object?>{
      ...release,
      'releaseVersion': 2,
      'profile': candidateProfile,
    };
    await signing.signToolProfileRelease(candidateRelease);
    await profileStore.installRelease(
      releaseInput: candidateRelease,
      expectedWorkerTypeId: 'chatgpt',
    );
    await profileStore.activateVersion('chatgpt-codex', 2);

    final registry = LocalWorkerRegistry(
      dataDirectory: Directory('${root.path}/Registry'),
      workspaceId: 'workspace-profile-live',
      idGenerator: () => 'disabled-chatgpt',
    );
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('chatgpt'),
      status: LocalWorkerStatus.disabled,
    );
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.parse('https://catalog.test'),
      store: profileStore,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [
        logicalWorkerCatalogFixture('chatgpt').toJson(),
      ],
    );
    await catalog.syncCatalog();
    addTearDown(catalog.close);
    final bundledEngine = File(
      '$repository/apps/workspace/assets/engines/'
      'conclave_cli_worker_engine${Platform.isWindows ? '.exe' : ''}',
    );
    final engine = CliWorkerEngineSupervisor(
      engineExecutable: bundledEngine.existsSync()
          ? bundledEngine.path
          : Platform.environment['DART_EXECUTABLE'] ??
              Platform.resolvedExecutable,
      engineArgumentsPrefix: bundledEngine.existsSync()
          ? const []
          : ['$repository/engines/cli_worker/bin/conclave_cli_worker.dart'],
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

    expect(await monitor.rollbackToolProfile('chatgpt'), isTrue);
    final stateAfterRollback = await profileStore.releaseState('chatgpt-codex');
    expect(stateAfterRollback.activeVersion, 1);
    expect(stateAfterRollback.lastKnownGoodVersion, 2);
    expect((await registry.find(worker.id))!.lastLiveTestAt, isNull,
        reason: 'Profile rollback must use only a passive probe.');

    await monitor.checkNow(
      mode: LocalWorkerProbeMode.live,
      workerTypeId: 'chatgpt',
    );

    final tested = (await registry.find(worker.id))!;
    expect(
      tested.lastLiveTestPassed,
      isTrue,
      reason: '${tested.lastLiveTestIssueCode}: ${tested.lastLiveTestDetails} '
          'version=${tested.toolVersion}',
    );
    expect(tested.lastLiveTestAt, isNotNull);
    expect(tested.activationState, LocalWorkerActivationState.disabled);
    expect(tested.status, LocalWorkerStatus.disabled);
    final diagnostic = jsonDecode(
      (await profileDiagnostics.currentFile.readAsLines()).last,
    ) as Map<String, Object?>;
    expect(diagnostic['workspaceVersion'], isNotNull);
    expect(diagnostic['engineVersion'], isNotNull);
    expect(diagnostic['workerTypeId'], 'chatgpt');
    expect(diagnostic['profileDefinitionId'], 'chatgpt-codex');
    expect(diagnostic['profileReleaseVersion'], 1);
    expect(diagnostic['profileResolutionSource'], 'active');
    expect(diagnostic['probeStage'], 'live');
    expect(diagnostic['providerToolName'], isNotNull);
    expect(diagnostic['providerToolVersion'], '0.3.0');
    expect(diagnostic['durationMs'], isA<int>());
    expect(diagnostic['failureLayer'], isNull);
    expect(jsonEncode(diagnostic), isNot(contains('profilePayload')));
    await monitor.dispose();
  });

  test(
      'Gemini live readiness uses stream-json through the generic Engine and keeps a disabled Worker disabled',
      () async {
    final repository = Directory.current.parent.parent.path;
    final root = await Directory.systemTemp.createTemp('profile-gemini-live-');
    addTearDown(() => root.delete(recursive: true));
    final signing = await Ed25519ReleaseFixture.create();
    final profileStore = ToolProfileReleaseStore(
      profilesRoot: Directory('${root.path}/Profiles'),
      trustPolicy: signing.trustPolicy,
    );
    final profile = jsonDecode(
      await File(
        '$repository/packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
      ).readAsString(),
    ) as Map<String, Object?>;
    final providerScript = '${root.path}/fixture_agy.dart';
    await File(providerScript).writeAsString(r'''import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('0.3.0');
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
}''');

    final provider = profile['providerTool']! as Map<String, Object?>;
    provider['executableCandidates'] = ['dart'];
    (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
        <String>[];
    (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
      'run',
      providerScript,
      '--version',
    ];
    (provider['versionProbe']! as Map<String, Object?>)['timeoutMs'] = 10000;
    provider['supportedVersions'] = [
      {'min': '0.0.0', 'maxExclusive': '1.0.0'},
    ];
    profile['environment'] = {
      'passthrough': ['PATH', 'HOME'],
      'set': <String, String>{},
    };
    final passive = (profile['probe']! as Map<String, Object?>)['passive']!
        as Map<String, Object?>;
    passive['checks'] = <Object?>[];
    passive['configChecks'] = <Object?>[];
    final execution = profile['execution']! as Map<String, Object?>;
    execution['arguments'] = [
      'run',
      providerScript,
      ...(execution['arguments']! as List<Object?>),
    ];
    final release = <String, Object?>{
      'profileDefinitionId': profile['profileDefinitionId'],
      'workerTypeId': 'gemini',
      'displayName': 'Antigravity Test Profile',
      'providerToolName': provider['name'],
      'channel': 'stable',
      'releaseVersion': profile['releaseVersion'],
      'profile': profile,
      'schemaVersion': profile['schemaVersion'],
      'engineFamily': profile['engineFamily'],
      'engineCompatibility': profile['engineCompatibility'],
    };
    await signing.signToolProfileRelease(release);
    await profileStore.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'gemini',
    );
    await profileStore.activateVersion('gemini-antigravity', 1,
        selectAsStable: true);

    final registry = LocalWorkerRegistry(
      dataDirectory: Directory('${root.path}/Registry'),
      workspaceId: 'workspace-gemini-profile-live',
      idGenerator: () => 'disabled-gemini',
    );
    final worker = await registry.create(
      catalogEntry: logicalWorkerCatalogFixture('gemini'),
      status: LocalWorkerStatus.disabled,
    );
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.parse('https://catalog.test'),
      store: profileStore,
      trustPolicy: signing.trustPolicy,
      workerCatalogLoader: () async => [
        logicalWorkerCatalogFixture('gemini').toJson(),
      ],
    );
    await catalog.syncCatalog();
    addTearDown(catalog.close);
    final bundledEngine = File(
      '$repository/apps/workspace/assets/engines/'
      'conclave_cli_worker_engine${Platform.isWindows ? '.exe' : ''}',
    );
    final engine = CliWorkerEngineSupervisor(
      engineExecutable: bundledEngine.existsSync()
          ? bundledEngine.path
          : Platform.environment['DART_EXECUTABLE'] ??
              Platform.resolvedExecutable,
      engineArgumentsPrefix: bundledEngine.existsSync()
          ? const []
          : ['$repository/engines/cli_worker/bin/conclave_cli_worker.dart'],
      environmentOverrides: {'HOME': root.path},
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
    );

    await monitor.checkNow(
      mode: LocalWorkerProbeMode.live,
      workerTypeId: 'gemini',
    );

    final tested = (await registry.find(worker.id))!;
    expect(
      tested.lastLiveTestPassed,
      isTrue,
      reason: '${tested.lastLiveTestIssueCode}: ${tested.lastLiveTestDetails} '
          'version=${tested.toolVersion}',
    );
    expect(tested.lastLiveTestAt, isNotNull);
    expect(tested.toolVersion, '0.3.0');
    expect(tested.activationState, LocalWorkerActivationState.disabled);
    expect(tested.status, LocalWorkerStatus.disabled);
    await monitor.dispose();
  });
}

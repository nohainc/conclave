import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_workspace/development_tool_profiles.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/tool_profile_resolver.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Directory root;
  late DevelopmentToolProfiles development;
  late ToolProfileReleaseStore store;
  late Map<String, Object?> profile;
  setUp(() async {
    root = await Directory.systemTemp
        .createTemp('workspace-development-profiles-');
    final signing = await Ed25519ReleaseFixture.create();
    development = DevelopmentToolProfiles(
        draftsRoot: Directory('${root.path}/Drafts'),
        snapshotsRoot: Directory('${root.path}/Development'),
        cloudUri: Uri.parse('http://localhost:8787'));
    store = ToolProfileReleaseStore(
        profilesRoot: Directory('${root.path}/Signed'),
        trustPolicy: signing.trustPolicy,
        developmentProfiles: development);
    profile = jsonDecode(await File(
            '../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
        .readAsString()) as Map<String, Object?>;
    await Directory('${development.draftsRoot.path}/fixture-cli')
        .create(recursive: true);
    await File('${development.draftsRoot.path}/fixture-cli/draft.json')
        .writeAsString(jsonEncode(profile));
  });
  tearDown(() => root.delete(recursive: true));

  test('rejects release builds and non-loopback Cloud connections', () {
    for (final url in [
      'https://app.conclaveax.com',
      'http://localhost.example.com',
      'http://user@localhost'
    ]) {
      expect(
          () => DevelopmentToolProfiles(
              draftsRoot: development.draftsRoot,
              snapshotsRoot: development.snapshotsRoot,
              cloudUri: Uri.parse(url)),
          throwsStateError);
    }
    expect(
        () => DevelopmentToolProfiles(
            draftsRoot: development.draftsRoot,
            snapshotsRoot: development.snapshotsRoot,
            cloudUri: Uri.parse('http://localhost:8787'),
            releaseBuild: true),
        throwsStateError);
  });

  test('selects unsigned local draft without installing it into signed storage',
      () async {
    final resolver = ToolProfileResolver(store);
    final resolution = await resolver.resolveForWorker(
        logicalWorkerTypeId: 'fixture-worker',
        profileDefinitionId: 'fixture-cli',
        engineVersion: '1.0.0',
        providerCliVersion: '0.3.0');
    expect(resolution.source, ToolProfileResolutionSource.draft);
    expect(resolution.release!.isSigned, isFalse);
    expect(resolution.release, isNot(isA<ToolProfileReleaseAdmission>()));
    expect(await store.activeRelease('fixture-cli'), isNull);
    final productionStore = ToolProfileReleaseStore(
        profilesRoot: store.profilesRoot, trustPolicy: store.trustPolicy);
    expect(
        (await ToolProfileResolver(productionStore).resolveForWorker(
                logicalWorkerTypeId: 'fixture-worker',
                profileDefinitionId: 'fixture-cli',
                engineVersion: '1.0.0'))
            .isAvailable,
        isFalse);
    await expectLater(productionStore.executionProfileFile(resolution.release!),
        throwsStateError);
  });

  test('checks identity, Engine and provider compatibility', () async {
    await expectLater(
        development.load('fixture-cli', 'other-worker'), throwsFormatException);
    final resolver = ToolProfileResolver(store);
    expect(
        (await resolver.resolveForWorker(
                logicalWorkerTypeId: 'fixture-worker',
                profileDefinitionId: 'fixture-cli',
                engineVersion: '9.0.0'))
            .reason,
        ToolProfileUnavailableReason.incompatibleEngineVersion);
    expect(
        (await resolver.resolveForWorker(
                logicalWorkerTypeId: 'fixture-worker',
                profileDefinitionId: 'fixture-cli',
                engineVersion: '1.0.0',
                providerCliVersion: '9.0.0'))
            .reason,
        ToolProfileUnavailableReason.unsupportedProviderVersion);
  });

  test('pins a run payload and rejects snapshot tampering', () async {
    final candidate =
        (await development.load('fixture-cli', 'fixture-worker'))!;
    final pinned = await store.executionProfileFile(candidate);
    profile['releaseVersion'] = 2;
    await File('${development.draftsRoot.path}/fixture-cli/draft.json')
        .writeAsString(jsonEncode(profile));
    expect(jsonDecode(await pinned.readAsString())['releaseVersion'], 1);
    await pinned.writeAsString('{}');
    await expectLater(
        store.executionProfileFile(candidate), throwsFormatException);
  });

  test('executes an unsigned development draft through the real generic Engine',
      () async {
    final repository = Directory.current.parent.parent.path;
    final providerScript =
        '$repository/packages/tool-profile/test/fixtures/provider-cli/fixture_provider.dart';
    final provider = profile['providerTool'] as Map<String, Object?>;
    provider['executableCandidates'] = ['dart'];
    (provider['versionProbe'] as Map<String, Object?>)['arguments'] = [
      'run',
      providerScript,
      '--version'
    ];
    final passive = (profile['probe'] as Map<String, Object?>)['passive']
        as Map<String, Object?>;
    passive['checks'] = <Object?>[];
    profile['execution'] = {
      'arguments': ['run', providerScript, 'echo', '{{prompt}}'],
      'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
      'output': {'mode': 'plain_text'},
      'events': <Object?>[]
    };
    await File('${development.draftsRoot.path}/fixture-cli/draft.json')
        .writeAsString(jsonEncode(profile));
    final resolution = await ToolProfileResolver(store).resolveForWorker(
        logicalWorkerTypeId: 'fixture-worker',
        profileDefinitionId: 'fixture-cli',
        engineVersion: '1.0.0');
    final candidate = resolution.release!;
    final engineFile = File(
        '$repository/apps/workspace/assets/engines/conclave_cli_worker_engine');
    expect(await engineFile.exists(), isTrue,
        reason: 'Build the CLI Worker Engine before acceptance tests');
    final supervisor =
        CliWorkerEngineSupervisor(engineExecutable: engineFile.path);
    final working = await Directory('${root.path}/Work').create();
    final result = await supervisor.execute(candidate,
        profileFile: await store.executionProfileFile(candidate),
        stateDirectory: Directory('${root.path}/State'),
        workingDirectory: working,
        workerId: 'local-development-worker',
        maxConcurrentAssignments: 1,
        assignmentId: 'unsigned-development-acceptance',
        prompt: 'unsigned-development-ok',
        timeout: const Duration(seconds: 30),
        sessionPolicy: WorkerSessionPolicy.stateless,
        executionPolicy: WorkerExecutionPolicy.providerDefault);
    expect(result.output, contains('unsigned-development-ok'));
    expect(await store.activeRelease('fixture-cli'), isNull);
  });
}

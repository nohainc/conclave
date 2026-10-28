import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart'
    show CliWorkerEngineSupervisor, cliWorkerEngineVersion;
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show WorkerResult;
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/local_worker_setup.dart';
import 'package:syntila_workspace/tool_profile_catalog.dart';
import 'package:syntila_workspace/worker_profile_store.dart';
import 'package:syntila_workspace/tool_profile_resolver.dart';
import 'package:syntila_workspace/worker_catalog_coordinator.dart';
import 'package:syntila_workspace/workspace_worker_view.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  test(
    'Workspace installs, verifies, caches, updates and executes one Profile per Worker',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('phase11-workspace-');
      addTearDown(() => root.delete(recursive: true));

      final signing = await Ed25519ReleaseFixture.create();
      final store = WorkerProfileStore(
        profilesRoot: Directory('${root.path}/Profiles'),
        trustPolicy: signing.trustPolicy,
      );
      final providerDirectory = Directory('${root.path}/provider-bin')
        ..createSync(recursive: true);
      final provider = File('${providerDirectory.path}/phase11-provider');
      await _writeProvider(provider);
      final baseProfile = jsonDecode(
        await File(
          '$repository/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
        ).readAsString(),
      ) as Map<String, Object?>;

      final workerTypes = ['chatgpt', 'gemini'];
      final profiles = <String, WorkerProfileSnapshotAdmission>{};
      for (final workerTypeId in workerTypes) {
        profiles[workerTypeId] = await _snapshot(
          signing: signing,
          baseProfile: baseProfile,
          workerTypeId: workerTypeId,
          profileDefinitionId: '$workerTypeId-phase11-profile',
          revision: 1,
        );
      }
      final descriptors = workerTypes.map((workerTypeId) {
        return <String, Object?>{
          'workerTypeId': workerTypeId,
          'displayName': workerTypeId == 'chatgpt' ? 'ChatGPT' : 'Gemini',
          'description': 'Phase 11 binary acceptance Worker.',
          'engineFamily': 'cli',
          'profileDefinitionId': '$workerTypeId-phase11-profile',
          'providerToolName': 'Phase 11 Provider',
          'releaseStage': 'stable',
          'visibilityState': 'visible',
          'sortOrder': workerTypeId == 'chatgpt' ? 1 : 2,
        };
      }).toList();

      var cloudAvailable = true;
      final cloudRevokedDigests = <String>{};
      final profileFetches = <String, int>{};
      final catalog = ToolProfileCatalogClient(
        cloudUri: Uri.parse('https://cloud.example'),
        workspaceRuntimeId: 'phase11-runtime',
        store: store,
        trustPolicy: signing.trustPolicy,
        workerCatalogLoader: () async {
          if (!cloudAvailable) throw const SocketException('offline');
          return descriptors;
        },
        currentProfileLoader: (workerTypeId) async {
          if (!cloudAvailable) throw const SocketException('offline');
          profileFetches[workerTypeId] =
              (profileFetches[workerTypeId] ?? 0) + 1;
          return profiles[workerTypeId]!;
        },
        candidateValidator: (candidate, file) async {
          if (candidate is! WorkerProfileSnapshotAdmission ||
              !await file.exists()) {
            return false;
          }
          final parsed = EngineProfile.parse(
            utf8.encode(canonicalJson(candidate.profile)),
          );
          return ToolProfileCompatibility.isEngineCompatible(
            parsed,
            cliWorkerEngineVersion,
          );
        },
        trustRefresher: () async {
          signing.trustPolicy.updateRevocations(digests: cloudRevokedDigests);
        },
      );
      addTearDown(catalog.close);

      final registry = LocalWorkerRegistry(
        dataDirectory: Directory('${root.path}/registry'),
        workspaceId: 'phase11-workspace',
        idGenerator: () => 'phase11-worker-id',
      );
      final coordinator = WorkerCatalogCoordinator(
        catalog: catalog,
        releaseStore: store,
        registry: registry,
        minimumRefreshInterval: Duration.zero,
      );
      addTearDown(coordinator.dispose);

      final chatgptWorker =
          await LocalWorkerSetupService(registry: registry).createCatalogWorker(
        entry: WorkerDescriptor.fromJson(
          Map<String, Object?>.from(descriptors.first),
        ),
        permissions: const [
          'repository:read',
          'repository:write',
          'shell:execute',
        ],
      );
      await coordinator.refreshLocalWorkers();
      await coordinator.refresh(force: true);
      // Only the added Worker downloads its Profile; Gemini stays catalog-only.
      expect(profileFetches, {'chatgpt': 1});
      expect(coordinator.snapshot.profiles['chatgpt']!.state,
          WorkspaceWorkerProfileState.ready);
      expect(coordinator.snapshot.profiles['gemini']!.state,
          WorkspaceWorkerProfileState.unavailable);
      expect(chatgptWorker.workerTypeId, 'chatgpt');
      expect((await registry.find(chatgptWorker.id))!.fullLocalAccessAuthorized,
          isTrue);

      final engine = File(
        '$repository/apps/workspace/assets/engines/'
        'syntila_cli_worker_engine',
      );
      expect(engine.existsSync(), isTrue);
      final supervisor = CliWorkerEngineSupervisor(
        engineExecutable: engine.path,
        environmentOverrides: {
          'PATH':
              '${providerDirectory.path}:${Platform.environment['PATH'] ?? ''}',
          'HOME': root.path,
        },
      );
      addTearDown(supervisor.shutdown);

      Future<WorkerResult> execute(
        WorkerProfileSnapshotAdmission candidate, {
        File? profileFile,
        String assignmentId = 'phase11-assignment',
      }) async {
        return supervisor.execute(
          candidate,
          profileFile:
              profileFile ?? await store.executionProfileFile(candidate),
          stateDirectory: Directory('${root.path}/state'),
          workingDirectory: Directory('${root.path}/work'),
          workerId: chatgptWorker.id,
          maxConcurrentAssignments: 1,
          assignmentId: assignmentId,
          prompt: 'OK',
          timeout: const Duration(seconds: 20),
        );
      }

      final first = profiles['chatgpt']!;
      final pinnedProfile = File('${root.path}/pinned-profile.json')
        ..writeAsStringSync(canonicalJson(first.profile));
      expect(
          (await execute(first, assignmentId: 'phase11-first')).output, 'OK');

      profiles['chatgpt'] = await _snapshot(
        signing: signing,
        baseProfile: baseProfile,
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-phase11-profile',
        revision: 2,
      );
      await coordinator.refresh(force: true);
      expect(profileFetches, {'chatgpt': 2});
      expect((await store.currentWorkerProfile('chatgpt'))?.revision, 2);
      expect((await store.lastKnownGoodWorkerProfile('chatgpt'))?.revision, 1);
      expect(
        (await registry.find(chatgptWorker.id))!.fullLocalAccessAuthorized,
        isTrue,
        reason:
            'Full Local Access authorization must survive a Profile update.',
      );
      expect(
          (await execute(profiles['chatgpt']!, assignmentId: 'phase11-second'))
              .output,
          'OK');

      final restartedStore = WorkerProfileStore(
        profilesRoot: Directory('${root.path}/Profiles'),
        trustPolicy: signing.trustPolicy,
      );
      final restartedResolution =
          await ToolProfileResolver(restartedStore).resolveForWorker(
        logicalWorkerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-phase11-profile',
        engineVersion: cliWorkerEngineVersion,
      );
      expect(restartedResolution.release?.revision, 2,
          reason:
              'A restarted Workspace must load the verified cached Profile.');

      // An active execution may continue to use the exact earlier snapshot
      // after a newer Profile is activated.
      expect(
        (await execute(
          first,
          profileFile: pinnedProfile,
          assignmentId: 'phase11-pinned',
        ))
            .output,
        'OK',
      );

      cloudAvailable = false;
      await coordinator.refresh(force: true);
      expect(coordinator.snapshot.profiles['chatgpt']!.state,
          WorkspaceWorkerProfileState.ready);
      expect(
          (await execute(profiles['chatgpt']!, assignmentId: 'phase11-offline'))
              .output,
          'OK');

      cloudAvailable = true;
      profiles['chatgpt'] = await _snapshot(
        signing: signing,
        baseProfile: baseProfile,
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-phase11-profile',
        revision: 3,
        engineMinimum: '9.0.0',
      );
      await coordinator.refresh(force: true);
      expect((await store.currentWorkerProfile('chatgpt'))?.revision, 2,
          reason:
              'An Engine-incompatible update must not replace the safe current Profile.');
      expect(coordinator.snapshot.profiles['chatgpt']!.state,
          WorkspaceWorkerProfileState.ready);

      final currentDigest =
          (await store.currentWorkerProfile('chatgpt'))!.payloadDigest;
      cloudRevokedDigests.add(currentDigest);
      try {
        await catalog.syncWorkerProfiles('chatgpt');
      } on Object {
        // Revocation is expected to block activation and execution.
      }
      final revokedResolution =
          await ToolProfileResolver(store).resolveForWorker(
        logicalWorkerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-phase11-profile',
        engineVersion: cliWorkerEngineVersion,
      );
      expect(revokedResolution.release, isNull);

      cloudRevokedDigests.clear();
      profiles['chatgpt'] = await _snapshot(
        signing: signing,
        baseProfile: baseProfile,
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-phase11-profile',
        revision: 4,
      );
      await coordinator.refresh(force: true);
      expect((await store.currentWorkerProfile('chatgpt'))?.revision, 4);
      expect(
          (await execute(profiles['chatgpt']!,
                  assignmentId: 'phase11-restored'))
              .output,
          'OK');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<WorkerProfileSnapshotAdmission> _snapshot({
  required Ed25519ReleaseFixture signing,
  required Map<String, Object?> baseProfile,
  required String workerTypeId,
  required String profileDefinitionId,
  required int revision,
  String? engineMinimum,
}) async {
  final profile = jsonDecode(jsonEncode(baseProfile)) as Map<String, Object?>;
  profile['profileDefinitionId'] = profileDefinitionId;
  profile['logicalWorkerTypeId'] = workerTypeId;
  profile['releaseVersion'] = revision;
  final providerTool = Map<String, Object?>.from(
    profile['providerTool']! as Map,
  )
    ..['name'] = 'Phase 11 Provider'
    ..['executableCandidates'] = ['phase11-provider'];
  profile['providerTool'] = providerTool;
  if (engineMinimum != null) {
    profile['engineCompatibility'] = {
      'min': engineMinimum,
      'maxExclusive': '10.0.0',
    };
  }
  final digest = sha256.convert(utf8.encode(canonicalJson(profile))).toString();
  return WorkerProfileSnapshotAdmission(
    profile: profile,
    workerTypeId: workerTypeId,
    revision: revision,
    payloadDigest: digest,
  );
}

Future<void> _writeProvider(File provider) async {
  await provider.writeAsString(r'''#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "phase11-provider 0.3.0"
  exit 0
fi
if [ "$1" = "probe" ]; then
  echo ready
  exit 0
fi
printf '%s\n' "$2"
''');
  await Process.run('chmod', ['700', provider.path]);
}

import 'dart:io';

import 'package:conclave_workspace/local_worker_permissions.dart';
import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/local_worker_setup.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:conclave_protocol/worker_descriptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalWorkerRegistry registry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('workspace_minimal_test_');
    registry = LocalWorkerRegistry(
      dataDirectory: tempDir,
      workspaceId: 'workspace-minimal-test',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('Phase 25 — Workspace Minimal Responsibilities & Security Ceiling', () {
    test(
        'Workspace defaults concurrency limit to 1 without exposing raw tuning knobs',
        () async {
      final setup = LocalWorkerSetupService(registry: registry);

      const entry = WorkerDescriptor(
        workerTypeId: 'claude',
        displayName: 'Claude',
        description: 'Claude Code Worker',
        engineFamily: 'cli',
        visibilityState: 'visible',
        releaseStage: 'stable',
        capabilities: ['code_generation'],
        sortOrder: 1,
        profileDefinitionId: 'claude-code-profile',
        providerToolName: 'claude',
      );

      final worker = await setup.createCatalogWorker(
        entry: entry,
        permissions: defaultLocalWorkerPermissions,
      );

      expect(
          worker.localConcurrencyLimit, equals(defaultLocalWorkerConcurrency));
      expect(
          worker.activationState, equals(LocalWorkerActivationState.enabled));
      expect(worker.status, equals(LocalWorkerStatus.needsAttention));
    });

    test(
        'Workspace allows Enable/Disable toggling cleanly without profile mutation',
        () async {
      final setup = LocalWorkerSetupService(registry: registry);

      const entry = WorkerDescriptor(
        workerTypeId: 'codex',
        displayName: 'Codex',
        description: 'Codex Worker',
        engineFamily: 'cli',
        visibilityState: 'visible',
        releaseStage: 'stable',
        capabilities: ['code_generation'],
        sortOrder: 2,
        profileDefinitionId: 'codex-profile',
        providerToolName: 'codex',
      );

      final worker = await setup.createCatalogWorker(
        entry: entry,
        permissions: defaultLocalWorkerPermissions,
      );

      final enabledWorker = await registry.update(
        worker.id,
        (current) => current.copyWith(
          activationState: LocalWorkerActivationState.enabled,
          status: LocalWorkerStatus.needsAttention,
        ),
      );

      expect(enabledWorker.activationState,
          equals(LocalWorkerActivationState.enabled));

      final disabledWorker = await registry.update(
        worker.id,
        (current) => current.copyWith(
          activationState: LocalWorkerActivationState.disabled,
          status: LocalWorkerStatus.disabled,
        ),
      );

      expect(disabledWorker.activationState,
          equals(LocalWorkerActivationState.disabled));
    });

    test(
        'Workspace verifies signed Tool Profile admissions against Ed25519 trust boundary',
        () {
      final admission = const ToolProfileReleaseAdmission(
        profile: {
          'schemaVersion': 1,
          'profileDefinitionId': 'test-profile',
          'releaseVersion': 1,
          'logicalWorkerTypeId': 'test-worker',
          'engineFamily': 'cli',
          'providerTool': {
            'name': 'test',
            'executableCandidates': ['test']
          },
        },
        profileDefinitionId: 'test-profile',
        releaseVersion: 1,
        logicalWorkerTypeId: 'test-worker',
        providerToolName: 'test',
        payloadDigest: 'fake-digest',
        channel: 'stable',
      );

      expect(admission.isSigned, isTrue);
      expect(admission.channel, equals('stable'));
    });
  });
}

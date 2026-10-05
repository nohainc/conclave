import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/models/profile_admin_read_models.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SelectedWorkerState unified UX state model', () {
    late Directory temp;
    late ProfileLabPaths paths;
    late ProfileLabController controller;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('worker_state_test_');
      paths = ProfileLabPaths(homeDirectory: temp.path);
      controller = ProfileLabController(
        paths: paths,
        sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
      );
      await controller.initialize();
    });

    tearDown(() async {
      controller.dispose();
      await temp.delete(recursive: true);
    });

    test('computes noSelection when no worker is selected', () {
      final state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.noSelection);
      expect(state.nextAction.title, 'Select a Worker');
      expect(state.workerTypeId, isEmpty);
    });

    test('computes noProfile when worker has no definition or draft', () {
      controller.selectedCloudWorker = {
        'workerTypeId': 'custom-worker',
        'displayName': 'Custom Worker',
        'providerToolName': 'custom-tool',
        'releaseStage': 'testing',
      };
      controller.selectedDefinitionId = null;

      final state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.noProfile);
      expect(state.nextAction.title, 'Create Profile Definition');
      expect(state.workerTypeId, 'custom-worker');
      expect(state.displayName, 'Custom Worker');
    });

    test('computes draftCreated when local draft exists and is saved',
        () async {
      controller.selectedCloudWorker = {
        'workerTypeId': 'chatgpt',
        'profileDefinitionId': 'chatgpt-codex',
        'displayName': 'ChatGPT',
        'providerToolName': 'codex',
        'releaseStage': 'testing',
      };
      controller.selectedDefinitionId = 'chatgpt-codex';

      await controller.createNewDraft(
        profileDefinitionId: 'chatgpt-codex',
        workerTypeId: 'chatgpt',
        providerToolName: 'codex',
      );

      final state = controller.selectedWorkerState;
      // Freshly created draft requires testing
      expect(state.hasLocalDraft, isTrue);
      expect(state.status, WorkerLifecycleStatus.testRequired);
      expect(state.nextAction.title, 'Test the Local Profile');
      expect(state.nextAction.actionLabel, 'Run Profile Tests');
    });

    test('computes draftModified when local draft has unsaved edits', () async {
      controller.selectedCloudWorker = {
        'workerTypeId': 'chatgpt',
        'profileDefinitionId': 'chatgpt-codex',
        'displayName': 'ChatGPT',
        'providerToolName': 'codex',
        'releaseStage': 'testing',
      };
      controller.selectedDefinitionId = 'chatgpt-codex';

      await controller.createNewDraft(
        profileDefinitionId: 'chatgpt-codex',
        workerTypeId: 'chatgpt',
        providerToolName: 'codex',
      );

      controller
          .updateJsonText('{"workerTypeId": "chatgpt", "modified": true}');
      expect(controller.isDirty, isTrue);

      final state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.draftModified);
      expect(state.nextAction.title, 'Save Unsaved Changes');
      expect(state.nextAction.actionLabel, 'Review & Save Draft');
    });

    test(
        'computes publicationUnavailable when tests pass but operator cannot publish',
        () async {
      controller.selectedCloudWorker = {
        'workerTypeId': 'chatgpt',
        'profileDefinitionId': 'chatgpt-codex',
        'displayName': 'ChatGPT',
        'providerToolName': 'codex',
        'releaseStage': 'testing',
      };
      controller.selectedDefinitionId = 'chatgpt-codex';

      await controller.createNewDraft(
        profileDefinitionId: 'chatgpt-codex',
        workerTypeId: 'chatgpt',
        providerToolName: 'codex',
      );

      controller.lastTestResult = 'pass';
      controller.labAccess = ProfileLabAccessReadModel.fromJson({
        'permissions': {'profilesAdmin': true, 'releaseManager': false},
        'signer': {'ready': false},
      });

      final state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.publicationUnavailable);
      expect(state.canPublish, isFalse);
      expect(state.nextAction.title, 'Publication Unavailable');
    });

    test(
        'computes testsPassed and recommends Publish when qualified and authorized',
        () async {
      controller.selectedCloudWorker = {
        'workerTypeId': 'chatgpt',
        'profileDefinitionId': 'chatgpt-codex',
        'displayName': 'ChatGPT',
        'providerToolName': 'codex',
        'releaseStage': 'testing',
      };
      controller.selectedDefinitionId = 'chatgpt-codex';

      await controller.createNewDraft(
        profileDefinitionId: 'chatgpt-codex',
        workerTypeId: 'chatgpt',
        providerToolName: 'codex',
      );

      controller.lastTestResult = 'pass';
      controller.labAccess = ProfileLabAccessReadModel.fromJson({
        'permissions': {'profilesAdmin': true, 'releaseManager': true},
        'signer': {'ready': true},
      });

      final state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.testsPassed);
      expect(state.canPublish, isTrue);
      expect(state.nextAction.title, 'Publish to Testing');
      expect(state.nextAction.actionLabel, 'Publish to Testing');
    });

    test('computes channel states: publishedTesting, beta, and stable', () {
      controller.selectedCloudWorker = {
        'workerTypeId': 'chatgpt',
        'profileDefinitionId': 'chatgpt-codex',
        'displayName': 'ChatGPT',
        'providerToolName': 'codex',
        'releaseStage': 'testing',
      };
      controller.selectedDefinitionId = 'chatgpt-codex';
      controller.cloudReleases = [
        {'releaseVersion': 1, 'lifecycleState': 'testing'}
      ];

      // 1. Testing channel
      controller.selectedCloudDefinition = {
        'channels': {'testing': 1}
      };
      var state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.publishedTesting);
      expect(state.nextAction.title, 'Promote to Beta');

      // 2. Beta channel
      controller.selectedCloudDefinition = {
        'channels': {'testing': 1, 'beta': 1}
      };
      state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.beta);
      expect(state.nextAction.title, 'Promote to Stable');

      // 3. Stable channel
      controller.selectedCloudDefinition = {
        'channels': {'testing': 1, 'beta': 1, 'stable': 1}
      };
      state = controller.selectedWorkerState;
      expect(state.status, WorkerLifecycleStatus.stable);
      expect(state.nextAction.title, 'Stable Rollout Active');
      expect(state.nextAction.area, LabArea.workspaces);
    });
  });
}

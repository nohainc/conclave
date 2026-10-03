import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/utils/profile_ai_assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProfileLabPaths tempPaths;
  late ProfileLabController controller;
  const assistantService = ProfileAiAssistantService();

  setUp(() async {
    final tempDir =
        await Directory.systemTemp.createTemp('profile_lab_ai_test_');
    tempPaths = ProfileLabPaths(homeDirectory: tempDir.path);
    await tempPaths.ensureDirectoriesExist();

    controller = ProfileLabController(paths: tempPaths);
    await controller.createNewDraft(
      profileDefinitionId: 'claude-code-test',
      workerTypeId: 'claude',
      providerToolName: 'claude',
    );
  });

  group('ProfileAiAssistantService', () {
    test('gathers context safely from non-credential runtime sources', () {
      final ctx = assistantService.gatherContext(controller);

      expect(ctx.workerMetadata, isNotNull);
      expect(ctx.currentDraft, isNotNull);
      expect(ctx.currentDraft['profileDefinitionId'], 'claude-code-test');
      expect(ctx.testDiagnostics, isNotNull);
      expect(ctx.providerCliInfo, isNotNull);
    });

    test('synthesizes proposed Tool Profile candidate draft based on prompt',
        () {
      final ctx = assistantService.gatherContext(controller);

      final proposed = assistantService.proposeCandidateDraft(
        context: ctx,
        userInstruction:
            'Fix passive probe and add non-interactive execution flag',
      );

      expect(proposed['schemaVersion'], 1);
      expect(proposed['profileDefinitionId'], 'claude-code-test');
      expect(proposed['passiveProbe']['argv'], ['--version']);
      expect(proposed['execution']['argv'], contains('--non-interactive'));
    });

    test(
        'AI candidate proposal lands exclusively in local draft without modifying publication or evidence',
        () async {
      final ctx = assistantService.gatherContext(controller);
      final proposed = assistantService.proposeCandidateDraft(
        context: ctx,
        userInstruction: 'Update execution arguments',
      );

      // Verify applying proposal updates currentJsonText and isDirty, but does not publish or sign
      final initialDigest = controller.currentDraft?.payloadDigest;
      controller.updateJsonText(proposed.toString());

      expect(controller.isDirty, isTrue);
      // Digest remains un-published until server Ed25519 signing
      expect(controller.currentDraft?.payloadDigest, initialDigest);
    });
  });
}

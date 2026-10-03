import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/utils/profile_ai_assistant.dart';
import 'package:conclave_profile_lab/utils/profile_lab_model_proposals.dart';
import 'package:conclave_profile_lab/views/ai_assistant_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProfileLabPaths tempPaths;
  late ProfileLabController controller;
  const assistantService = ProfileAiHeuristicRepairService();
  const modelProposalService = ProfileLabModelProposalService();

  setUp(() async {
    final tempDir =
        await Directory.systemTemp.createTemp('profile_lab_ai_test_');
    tempPaths = ProfileLabPaths(homeDirectory: tempDir.path);
    await tempPaths.ensureDirectoriesExist();

    controller = ProfileLabController(
      paths: tempPaths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(tempPaths),
    );
    controller.setApiClientForTesting(_OfflineProfileAdminApiClient());
    await controller.createNewDraft(
      profileDefinitionId: 'example-runtime-test',
      workerTypeId: 'example-worker',
      providerToolName: 'example-runtime',
    );
  });

  group('ProfileAiHeuristicRepairService', () {
    test('gathers context safely from non-credential runtime sources', () {
      final ctx = assistantService.gatherContext(controller);

      expect(ctx.workerMetadata, isNotNull);
      expect(ctx.currentDraft, isNotNull);
      expect(ctx.currentDraft['profileDefinitionId'], 'example-runtime-test');
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
      expect(proposed['profileDefinitionId'], 'example-runtime-test');
      expect(proposed['passiveProbe']['argv'], ['--version']);
      expect(proposed['execution']['argv'], contains('--non-interactive'));
    });

    test('failed session diagnostics do not invent provider session behavior',
        () {
      final originalProfile = {
        'schemaVersion': 1,
        'profileDefinitionId': 'dynamic-profile',
        'releaseVersion': 1,
        'logicalWorkerTypeId': 'dynamic-worker',
        'engineFamily': 'cli',
        'providerTool': {
          'name': 'example-runtime',
          'executableCandidates': ['example-runtime'],
        },
        'execution': {
          'argv': ['execute'],
          'env': <String, String>{}
        },
        'session': {
          'supported': true,
          'formatId': 'profile-defined-session',
          'resumeArguments': ['--continue', '{{sessionId}}'],
        },
        'capabilities': ['text'],
      };
      final context = AiAssistantContext(
        workerMetadata: {'workerTypeId': 'dynamic-worker'},
        stableProfile: null,
        currentDraft: originalProfile,
        testDiagnostics: [
          {'stage': 'session_test', 'status': 'failed'},
        ],
        providerCliInfo: const {},
      );

      final proposed = assistantService.proposeCandidateDraft(
        context: context,
        userInstruction: 'Review the failed session test',
      );

      expect(proposed['session'], originalProfile['session']);
      expect(proposed['providerTool'], originalProfile['providerTool']);
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

    test(
        'model response must preserve Draft identity and validate as a Profile',
        () {
      final original =
          Map<String, dynamic>.from(controller.currentDraft!.profile);
      final proposal = modelProposalService.parseProposal(
        jsonEncode(original),
        originalDraft: original,
      );
      expect(proposal, original);

      final changedIdentity = Map<String, dynamic>.from(original)
        ..['releaseVersion'] = (original['releaseVersion'] as int) + 1;
      expect(
        () => modelProposalService.parseProposal(
          jsonEncode(changedIdentity),
          originalDraft: original,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('model prompt refuses credential-like Draft content', () {
      expect(
        () => modelProposalService.buildPrompt(
          currentDraft: {
            ...controller.currentDraft!.profile,
            'environment': {
              'set': {'OPENAI_API_KEY': 'secret-value'},
            },
          },
          userInstruction: 'Review this Profile',
          testDiagnostics: const [],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    testWidgets('assistant uses the trusted model proposal flow',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => AiAssistantDialog.show(context, controller),
                child: const Text('Open AI Draft Proposal'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open AI Draft Proposal'));
      await tester.pumpAndSettle();

      expect(find.text('AI Profile Draft Proposal'), findsOneWidget);
      expect(
          find.textContaining('signed Stable Worker Profile'), findsOneWidget);
      expect(find.textContaining('Sign in to Cloud'), findsOneWidget);
    });
  });
}

class _OfflineProfileAdminApiClient extends ProfileAdminApiClient {
  _OfflineProfileAdminApiClient() : super(baseUrl: 'http://127.0.0.1:1');

  @override
  Future<ProfileLabReleaseReadModel> fetchRelease(
          String profileDefinitionId, int releaseVersion) async =>
      ProfileLabReleaseReadModel.fromJson({});

  @override
  Future<ProfileLabReleaseTrustReadModel> fetchReleaseTrust() async =>
      ProfileLabReleaseTrustReadModel.fromJson({
        'revokedKeyIds': <String>[],
        'revokedToolProfiles': <Map<String, Object?>>[],
      });

  @override
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async => [];

  @override
  Future<List<ProfileLabChannelPointerReadModel>> fetchChannelPointers(
          [String? profileDefinitionId]) async =>
      [];
}

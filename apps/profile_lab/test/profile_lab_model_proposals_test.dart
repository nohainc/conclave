import 'dart:async';
import 'package:conclave_design/conclave_design.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/views/ai_assistant_dialog.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'dart:io';

import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/utils/profile_lab_model_proposals.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/worker_profile_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('discovers model options only from current Worker Profiles', () async {
    final currentProfile = await _createCurrentProfile();
    final api = _CurrentProfileApi(currentProfile);

    final options = await const ProfileLabModelProposalService()
        .loadAvailableModels(apiClient: api);

    expect(options.map((option) => option.model).toList(),
        [null, 'model-fast', 'model-safe']);
    expect(options.every((option) => option.profile.isPublished), isTrue);
    expect(options.firstWhere((o) => o.model == 'model-fast').modelIdentifier,
        'model-worker/model-profile@2#model-fast');
  });

  test('retains unavailable provider models for the shared selector', () async {
    final current = await _createCurrentProfile(dynamicModels: true);
    final options =
        await const ProfileLabModelProposalService().loadAvailableModels(
      apiClient: _CurrentProfileApi(current),
      discoverModels: (release) async => DiscoveredModelCatalog(
        profileDigest: release.payloadDigest,
        providerToolVersion: '1.3.3',
        discoveredAt: '2026-10-11T00:00:00Z',
        models: [
          DiscoveredModel(id: 'gemini-new-high', name: 'Gemini New High'),
          DiscoveredModel(id: 'gemini-old', name: 'Old', status: 'unavailable'),
          DiscoveredModel(id: 'other-provider', name: 'Other'),
        ],
      ),
    );
    expect(
        options.map((o) => o.model), [null, 'gemini-new-high', 'gemini-old']);
    expect(
        options
            .firstWhere((o) => o.model == 'gemini-old')
            .capability!
            .available,
        isFalse);
    expect(profileLabSelectionCatalog(options).workers.single.models,
        hasLength(2));
  });

  testWidgets(
      'proposal dialog uses the shared selector without choosing the first model',
      (tester) async {
    final root = Directory.systemTemp.createTempSync('selector-dialog-');
    final pending = Completer<List<ProfileLabAiModelOption>>();
    final controller = _SelectorController(
        paths: ProfileLabPaths(homeDirectory: root.path),
        options: pending.future);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AiAssistantDialog(controller: controller))));
    expect(find.byType(ModelEffortSelector), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Select Worker...'), findsOneWidget);
    expect(find.textContaining('No current Worker Profile'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets(
      'an unavailable proposal Profile remains visibly unavailable after refresh',
      (tester) async {
    final options = (await tester.runAsync(() async {
      final current = await _createCurrentProfile();
      return const ProfileLabModelProposalService()
          .loadAvailableModels(apiClient: _CurrentProfileApi(current));
    }))!;
    final root = Directory.systemTemp.createTempSync('selector-revocation-');
    final controller = _SelectorController(
        paths: ProfileLabPaths(homeDirectory: root.path),
        options: Future.value(options));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AiAssistantDialog(controller: controller))));
    await tester.pumpAndSettle();
    Future<void> choose(String label, String text) async {
      final picker = find.byWidgetPredicate((widget) =>
          widget is DropdownButtonFormField<String> &&
          (widget.key as ValueKey<String>)
              .value
              .startsWith('proposal-$label-'));
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text(text).last);
      await tester.pumpAndSettle();
    }

    await choose('Worker', 'Model Worker · revision 2');
    await choose('Model', 'model-fast');
    final consent = find.byType(CheckboxListTile);
    await tester.ensureVisible(consent);
    await tester.tap(consent);
    await tester.pumpAndSettle();
    final generate = find.text('Generate Candidate Proposal');
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(find.text('model-fast · Unavailable'), findsOneWidget);
    expect(find.text('model-worker@2 · Unavailable'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    root.deleteSync(recursive: true);
  });
}

class _CurrentProfileApi extends ProfileAdminApiClient {
  _CurrentProfileApi(this.currentProfile)
      : super(baseUrl: 'http://127.0.0.1:1');

  final _CurrentProfile currentProfile;
  @override
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async => [
        ProfileLabWorkerReadModel.fromJson({
          'workerTypeId': 'model-worker',
          'displayName': 'Model Worker',
          'providerToolName': 'fixture-provider',
        }),
      ];

  @override
  Future<Map<String, dynamic>> fetchCurrentWorkerProfile(
    String workerTypeId,
  ) async =>
      Map<String, dynamic>.from(currentProfile.envelope);
}

class _CurrentProfile {
  const _CurrentProfile(this.envelope);

  final Map<String, Object?> envelope;
}

Future<_CurrentProfile> _createCurrentProfile(
    {bool dynamicModels = false}) async {
  final profile = buildTestWorkerProfile(
    profileDefinitionId: 'model-profile',
    releaseVersion: 2,
    logicalWorkerTypeId: 'model-worker',
    model: dynamicModels
        ? {
            'supported': true,
            'arguments': ['--model', '{{model}}'],
            'unknownModelPolicy': 'pass_through',
            'discovery': {
              'schemaVersion': 1,
              'arguments': ['models'],
              'timeoutMs': 10000,
              'format': 'tsv',
              'idPrefix': 'gemini-'
            },
          }
        : {
            'supported': true,
            'arguments': ['--model', '{{model}}'],
            'allowlist': ['model-safe', 'model-fast'],
            'unknownModelPolicy': 'profile_allowlist',
          },
  );
  final digest = sha256.convert(utf8.encode(canonicalJson(profile))).toString();
  return _CurrentProfile(
    {
      'workerTypeId': 'model-worker',
      'schemaVersion': profile['schemaVersion'],
      'revision': 2,
      'digest': digest,
      'profile': profile,
      'updatedAt': DateTime.utc(2026).toIso8601String(),
    },
  );
}

class _SelectorController extends ProfileLabController {
  _SelectorController({required super.paths, required this.options});
  final Future<List<ProfileLabAiModelOption>> options;
  @override
  Future<List<ProfileLabAiModelOption>> loadAvailableAiModels() async {
    availableAiModels = await options;
    return availableAiModels;
  }

  @override
  Future<Map<String, dynamic>> generateAiDraftProposal(
      {required String modelOptionId,
      required String userInstruction,
      required bool dataSharingConfirmed,
      String? reasoningEffort}) async {
    availableAiModels = [];
    throw StateError('The selected Profile was revoked.');
  }
}

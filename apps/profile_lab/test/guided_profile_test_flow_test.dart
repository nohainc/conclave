import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_profile_lab/views/release_evidence_view.dart';
import 'package:conclave_profile_lab/views/test_bench_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ProfileLabController {
  _Controller(ProfileLabPaths paths)
      : super(
            paths: paths,
            sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths));
  int runs = 0;
  String? appliedMin;
  @override
  Future<void> runTestLadder() async {
    runs++;
  }

  @override
  Future<void> applyRecommendedProviderCompatibilityRange(
      {required String min, required String maxExclusive}) async {
    appliedMin = min;
  }
}

void main() {
  late Directory temp;
  late _Controller c;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('guided_test_flow_');
    c = _Controller(ProfileLabPaths(homeDirectory: temp.path));
    final payload = jsonDecode(await File(
            '../../packages/tool-profile/test/fixtures/chatgpt-codex.v1.json')
        .readAsString()) as Map<String, dynamic>;
    c.currentDraft = await c.store
        .saveDraft(profileDefinitionId: 'chatgpt-codex', profileJson: payload);
    c.selectedDefinitionId = 'chatgpt-codex';
    c.currentJsonText = jsonEncode(payload);
    c.detectedProviderPaths['codex'] = '/fixture/codex';
  });
  tearDown(() async {
    c.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {Widget? child}) async {
    tester.view.physicalSize = const Size(600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AnimatedBuilder(
                animation: c,
                builder: (_, __) => child ?? TestBenchView(controller: c)))));
  }

  void bindRun() {
    c.testedDraftDigest = c.currentDraft!.payloadDigest;
    c.testedProfileDefinitionId = c.currentDraft!.profileDefinitionId;
  }

  ProfileLabLadderStageResult stage(String id,
          {String status = 'passed',
          Map<String, Object?> details = const {}}) =>
      ProfileLabLadderStageResult(
          stageId: id,
          displayName: id,
          status: status,
          durationMs: 100,
          diagnostics: 'Observed $id',
          consumesQuota: false,
          details: details);

  Map<String, Object?> evidence() => ToolProfileAcceptanceEvidence(
          profileDefinitionId: c.currentDraft!.profileDefinitionId,
          releaseVersion: c.currentDraft!.releaseVersion,
          profileDigest: c.currentDraft!.payloadDigest,
          logicalWorkerTypeId: c.currentDraft!.logicalWorkerTypeId,
          engineVersion: '1.0.0',
          providerToolName: 'Codex CLI',
          providerToolVersion: '0.180.0',
          acceptedAt: DateTime.now().toUtc().toIso8601String(),
          scenarios: cloudAcceptanceScenarioStatuses(c.currentDraft!.profile)!)
      .toJson();

  testWidgets(
      'starts with three honest preflights and one full-test action, logs collapsed',
      (tester) async {
    await mount(tester);
    for (final label in ['Provider CLI', 'Version', 'Authentication']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Found'), findsOneWidget);
    expect(find.text('Not checked'), findsNWidgets(2));
    expect(find.text('Test stages'), findsNothing);
    expect(find.text('Local acceptance evidence'), findsNothing);
    expect(find.text('Execution details'), findsOneWidget);
    expect(find.text('Execution logs appear during a run.'), findsNothing);
    await tester.tap(find.text('Run Full Test'));
    expect(c.runs, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress streams stages while details stay collapsed',
      (tester) async {
    bindRun();
    c.isTesting = true;
    c.activeLadderStages = [stage('schema')];
    c.testLogs = [
      TestExecutionLog(
          timestamp: DateTime.now(),
          level: 'info',
          message: 'streamed-secret-free-message')
    ];
    await mount(tester);
    expect(find.text('schema · passed'), findsOneWidget);
    expect(find.text('streamed-secret-free-message'), findsNothing);
    c.activeLadderStages
        .add(stage('cli_version', details: {'cliVersion': '0.180.0'}));
    c.notifyListeners();
    await tester.pump();
    expect(find.text('0.180.0 · Supported'), findsOneWidget);
    expect(find.text('cli_version · passed'), findsOneWidget);
    await tester.tap(find.text('Execution details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('streamed-secret-free-message'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'completion summarizes all stages, duration and exact local qualification',
      (tester) async {
    bindRun();
    c.lastTestResult = 'pass';
    c.activeLadderStages = [
      stage('executable_discovery'),
      stage('cli_version', details: {'cliVersion': '0.180.0'}),
      stage('passive_probe'),
      for (var i = 0; i < 8; i++) stage('remaining-$i')
    ];
    c.testStartedAt = DateTime.utc(2026, 10, 4);
    c.testCompletedAt = c.testStartedAt!.add(const Duration(seconds: 8));
    c.currentEvidence = [evidence()];
    await mount(tester);
    expect(find.text('11/11 passed'), findsOneWidget);
    expect(find.text('Codex CLI · 0.180.0'), findsOneWidget);
    expect(find.text('Duration: 8.0 s'), findsOneWidget);
    expect(find.text('Ready for Cloud qualification'), findsOneWidget);
    expect(find.text('Local acceptance evidence'), findsOneWidget);
    c.isDirty = true;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Ready for Cloud qualification'), findsNothing);
    expect(find.text('Draft modified · Save and rerun to qualify'),
        findsOneWidget);
    c.isDirty = false;
    c.currentEvidence = [
      {...evidence(), 'profileDigest': 'different'}
    ];
    c.activeLadderStages[10] = stage('optional', status: 'skipped');
    c.notifyListeners();
    await tester.pump();
    expect(find.text('10/11 passed · 1 skipped'), findsOneWidget);
    expect(find.text('Ready for Cloud qualification'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed version stage offers Retry, bounded range and repair',
      (tester) async {
    bindRun();
    c.lastTestResult = 'fail';
    c.activeLadderStages = [
      stage('cli_version', status: 'failed', details: {
        'detectedProviderVersion': '0.180.0',
        'suggestedMin': '0.180.0',
        'suggestedMaxExclusive': '0.181.0'
      })
    ];
    await mount(tester);
    expect(find.text('0/11 passed'), findsOneWidget);
    expect(find.text('Ready for Cloud qualification'), findsNothing);
    expect(find.text('Repair Profile'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(c.runs, 1);
    await tester.tap(find.text('Apply version range'));
    await tester.pump();
    expect(c.appliedMin, '0.180.0');
    c.testedDraftDigest = 'different';
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Repair Profile'), findsNothing);
    expect(find.text('Apply version range'), findsNothing);
    expect(find.text('Not checked'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Releases filters Cloud evidence by definition, version and digest',
      (tester) async {
    final contract = evidence();
    final record = <String, dynamic>{
      'id': 'matching',
      'profileDefinitionId': 'chatgpt-codex',
      'releaseVersion': 1,
      'payloadDigest': c.currentDraft!.payloadDigest,
      'providerToolVersion': '0.180.0',
      'engineVersion': '1.0.0',
      'acceptedAt': contract['acceptedAt'],
      'evidence': contract
    };
    c.cloudEvidence = [
      record,
      {
        ...record,
        'id': 'wrong-definition',
        'profileDefinitionId': 'gemini-antigravity'
      },
      {...record, 'id': 'wrong-version', 'releaseVersion': 2},
      {...record, 'id': 'wrong-digest', 'payloadDigest': 'other'}
    ];
    final release = <String, dynamic>{
      'profileDefinitionId': 'chatgpt-codex',
      'releaseVersion': 1,
      'payloadDigest': c.currentDraft!.payloadDigest,
      'profile': c.currentDraft!.profile
    };
    await mount(tester,
        child: ReleaseEvidenceView(controller: c, release: release));
    expect(find.text('Evidence matching'), findsOneWidget);
    expect(find.textContaining('Evidence wrong-'), findsNothing);
    await tester.tap(find.text('Evidence matching'));
    await tester.pumpAndSettle();
    expect(find.text('passive_probe: passed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

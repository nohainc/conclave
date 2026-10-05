import 'dart:convert';
import 'dart:io';
import 'package:conclave_profile_lab/app.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/widgets/lab_components.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Auth extends ProfileLabAuthClient {
  _Auth() : super(cloudUrl: 'http://localhost');
  bool opened = false, validated = false;
  @override
  Future<ProfileLabAuthIntent> createIntent() async => ProfileLabAuthIntent(
      intentId: 'intent',
      pollToken: 'poll',
      verificationUrl: Uri.parse('http://localhost/approve'),
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      pollIntervalMs: 1,
      audience: profileLabAudience);
  @override
  Future<void> openVerification(ProfileLabAuthIntent intent) async {
    opened = true;
  }

  @override
  Future<ProfileLabSession> waitForApprovalAndClaim(ProfileLabAuthIntent intent,
          {bool Function()? isCancelled}) async =>
      ProfileLabSession(
          credential: 'fixture-session',
          sessionId: 'session',
          userId: 'operator',
          displayName: 'Operator',
          email: 'operator@example.invalid',
          expiresAt: DateTime.now().add(const Duration(hours: 1)));
  @override
  Future<void> validateSession(ProfileLabSession session) async {
    validated = true;
  }
}

class _Cloud extends ProfileAdminApiClient {
  _Cloud(
      {required this.worker,
      required this.definition,
      required this.publishing})
      : super(baseUrl: 'http://localhost');
  final Map<String, dynamic> worker, definition;
  final bool publishing;
  Map<String, dynamic>? draft;
  int creates = 0, updates = 0;
  int publications = 0;
  Map<String, Object?>? qualification;
  @override
  Future<ProfileLabSigningPreflightReadModel> checkSigningPreflight() async =>
      ProfileLabSigningPreflightReadModel.fromJson(
          {'ready': publishing, 'issues': []});
  @override
  Future<Map<String, dynamic>> submitLocalQualification(
      {required String profileDefinitionId,
      required int releaseVersion,
      required Map<String, Object?> evidence}) async {
    expect(evidence['profileDigest'], draft!['payloadDigest']);
    qualification = evidence;
    return {'qualificationEvidenceId': 'fixture-qualification'};
  }

  @override
  Future<Map<String, dynamic>> publishRelease(
      {required String profileDefinitionId,
      required int releaseVersion,
      required String qualificationEvidenceId}) async {
    expect(qualificationEvidenceId, 'fixture-qualification');
    expect(qualification, isNotNull);
    publications++;
    draft!['lifecycleState'] = 'testing';
    draft!['publishedAt'] = DateTime.now().toUtc().toIso8601String();
    definition['channels'] = {'testing': releaseVersion};
    return {'status': 'testing'};
  }

  @override
  Future<ProfileLabAccessReadModel> fetchLabAccess() async =>
      ProfileLabAccessReadModel.fromJson({
        'schemaVersion': 1,
        'permissions': {'profilesAdmin': true, 'releaseManager': true},
        'signer': {'ready': publishing},
      });
  @override
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async =>
      [ProfileLabWorkerReadModel.fromJson(worker)];
  @override
  Future<ProfileLabDefinitionReadModel> fetchDefinition(String id) async =>
      ProfileLabDefinitionReadModel.fromJson(definition);
  @override
  Future<List<ProfileLabReleaseReadModel>> fetchReleases(String id) async =>
      draft == null ? [] : [ProfileLabReleaseReadModel.fromJson(draft!)];
  @override
  Future<ProfileLabReleaseReadModel> fetchRelease(
      String id, int version) async {
    if (draft == null) throw ProfileAdminNotFoundException('No Profile');
    return ProfileLabReleaseReadModel.fromJson(draft!);
  }

  @override
  Future<List<ProfileLabEvidenceReadModel>> fetchReleaseEvidence(
          String id, int version) async =>
      [];
  @override
  Future<List<ProfileLabAuditEventReadModel>> fetchAudit([String? id]) async =>
      [];
  Map<String, dynamic> _save(
      String id, int version, Map<String, dynamic> profile) {
    final candidate = LocalDraftProfileCandidate.fromProfileMap(profile);
    draft = {
      'profileDefinitionId': id,
      'releaseVersion': version,
      'lifecycleState': 'draft',
      'profile': jsonDecode(jsonEncode(profile)),
      'payloadDigest': candidate.payloadDigest
    };
    return draft!;
  }

  @override
  Future<Map<String, dynamic>> createDraftRelease(
      {required String profileDefinitionId,
      required int releaseVersion,
      required Map<String, dynamic> profile}) async {
    creates++;
    return _save(profileDefinitionId, releaseVersion, profile);
  }

  @override
  Future<Map<String, dynamic>> updateDraft(
      {required String profileDefinitionId,
      required int releaseVersion,
      required Map<String, dynamic> profile,
      String? expectedBaseDigest}) async {
    updates++;
    expect(expectedBaseDigest, draft?['payloadDigest']);
    return _save(profileDefinitionId, releaseVersion, profile);
  }
}

class _Controller extends ProfileLabController {
  _Controller(
      {required super.paths,
      required _Cloud cloud,
      required this.auth,
      required Map<String, String> environment})
      : super(
            apiClientOverride: cloud,
            sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
            sandboxEnvironmentOverrides: environment);
  final _Auth auth;
  @override
  Future<void> signInWithBrowser({ProfileLabAuthClient? clientOverride}) =>
      super.signInWithBrowser(clientOverride: auth);
}

void main() {
  late Directory temp;
  late _Controller c;
  late _Cloud cloud;
  late _Auth auth;
  Future<void> prepare(
      String workerId, String name, String definitionId, String executable,
      {bool publishing = false, bool template = true}) async {
    temp = await Directory.systemTemp.createTemp('worker_first_run_');
    final bin = Directory('${temp.path}/.local/bin')
      ..createSync(recursive: true);
    final provider = File('${bin.path}/$executable')
      ..writeAsStringSync('''#!/bin/sh
if [ "\$1" = "--version" ]; then echo "$executable ${executable == 'codex' ? '0.180.0' : '1.2.3'}"; exit 0; fi
if [ "\$1" = "login" ]; then echo 'Authenticated fixture'; exit 0; fi
if [ "$executable" = "agy" ]; then IFS= read -r input; else input=\$(cat); fi
case "\$input" in *cancellation*|*timeout*) sleep 30 ;; esac
case "\$input" in *acceptance-write.txt*) printf 'conclave-profile-lab-write-verified' > acceptance-write.txt ;; esac
if [ "$executable" = "codex" ]; then
printf '%s\\n' '{"type":"thread.started","thread_id":"fixture-session"}' '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}' '{"type":"turn.completed"}'
else
printf '%s\\n' '{"event":"init","conversation_id":"fixture-session"}' '{"event":"result","conversation_id":"fixture-session","result":{"status":"SUCCESS","response":"OK"}}'
fi
''');
    await Process.run('chmod', ['700', provider.path]);
    final worker = <String, dynamic>{
      'workerTypeId': workerId,
      'displayName': name,
      'profileDefinitionId': definitionId,
      'providerToolName': executable,
      'releaseStage': 'stable',
      'lifecycleState': 'active',
      'visibilityState': 'visible'
    };
    final definition = <String, dynamic>{
      'profileDefinitionId': definitionId,
      'workerTypeId': workerId,
      'providerToolName': executable,
      'displayName': '$name Profile',
      'channels': <String, dynamic>{}
    };
    if (template) {
      final payload = jsonDecode(await File(
              '../../packages/tool-profile/test/fixtures/$definitionId.v1.json')
          .readAsString()) as Map<String, dynamic>;
      definition['starterTemplate'] = {'schemaVersion': 1, 'profile': payload};
    }
    Directory('${temp.path}/.gemini/antigravity-cli')
        .createSync(recursive: true);
    File('${temp.path}/.gemini/antigravity-cli/settings.json')
        .writeAsStringSync('{"modelProvider":"gemini"}');
    cloud =
        _Cloud(worker: worker, definition: definition, publishing: publishing);
    auth = _Auth();
    c = _Controller(
        paths: ProfileLabPaths(homeDirectory: temp.path),
        cloud: cloud,
        auth: auth,
        environment: {
          'HOME': temp.path,
          'PATH': '${bin.path}:${Platform.environment['PATH']}',
          'GEMINI_API_KEY': 'fixture-not-a-secret'
        });
    await c.initialize(loadEngine: template, scanProviders: false);
  }

  tearDown(() async {
    c.dispose();
    await temp.delete(recursive: true);
  });
  Future<void> waitForOperations() async {
    for (var i = 0; i < 500; i++) {
      if (!c.isSigningIn &&
          !c.isLoadingWorkerCatalog &&
          !c.isLoadingDefinitions &&
          !c.isLoadingReleases &&
          !c.isCreatingInitialDraft &&
          !c.isTesting &&
          !c.isSavingLocally &&
          !c.isSavingToCloud) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    fail(
        'Operation did not complete: sign-in=${c.isSigningIn}, catalog=${c.isLoadingWorkerCatalog}, definition=${c.isLoadingDefinitions}, releases=${c.isLoadingReleases}, test=${c.testStatusMessage}');
  }

  Future<void> tap(WidgetTester t, Finder finder) async {
    await t.ensureVisible(finder);
    await t.runAsync(() async {
      await t.tap(finder);
      await waitForOperations();
    });
    await t.pump();
  }

  Future<void> signInAndSelect(WidgetTester t, String name) async {
    t.view.physicalSize = const Size(1440, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(ProfileLabApp(controller: c));
    expect(c.currentDraft, isNull);
    expect(cloud.draft, isNull);
    await tap(t, find.text('Sign In'));
    expect(auth.opened, isTrue);
    expect(auth.validated, isTrue);
    expect(c.currentSession, isNotNull);
    await tap(t, find.text('Workers'));
    await tap(
        t,
        find.descendant(
            of: find.byType(WorkerSidebarItem), matching: find.text(name)));
    expect(c.selectedWorkerState.stableVersion, 'None');
    expect(find.text('Catalog stage: stable'), findsOneWidget);
    final stableCard = find.byWidgetPredicate((widget) =>
        widget is ReleaseChannelCard && widget.channel == 'Stable Channel');
    expect(find.descendant(of: stableCard, matching: find.text('None')),
        findsOneWidget);
    expect(find.descendant(of: stableCard, matching: find.text('Unassigned')),
        findsOneWidget);
    expect(find.text('Stable release'), findsNothing);
    await tap(t, find.byKey(const ValueKey('subview-draftAndTest')));
    expect(find.text('$name does not have an implementation Profile yet'),
        findsOneWidget);
    expect(find.text('Local drafts'), findsNothing);
    expect(find.text('Profiles'), findsNothing);
    expect(find.text('Tests'), findsNothing);
  }

  for (final spec in [
    ('chatgpt', 'ChatGPT', 'chatgpt-codex', 'codex'),
    ('gemini', 'Gemini', 'gemini-antigravity', 'agy')
  ]) {
    for (final publishing in [false, true]) {
      testWidgets(
          '${spec.$2} first run through real Engine, local save and Cloud sync (${publishing ? 'signer ready' : 'signer missing'})',
          (t) async {
        await t.runAsync(() => prepare(spec.$1, spec.$2, spec.$3, spec.$4,
            publishing: publishing));
        await signInAndSelect(t, spec.$2);
        await tap(t, find.text('Create Initial Draft'));
        expect(find.byType(AlertDialog), findsNothing);
        expect(c.currentDraft, isNotNull,
            reason: t
                .widgetList<Text>(find.byType(Text))
                .map((w) => w.data)
                .join(' | '));
        expect(
            c.currentDraft!.profile,
            jsonDecode(jsonEncode(
                (cloud.definition['starterTemplate'] as Map)['profile'])));
        expect(c.currentDraft!.profileDefinitionId, spec.$3);
        expect(c.currentDraft!.logicalWorkerTypeId, spec.$1);
        expect(c.detectedProviderPaths[spec.$4],
            '${temp.path}/.local/bin/${spec.$4}');
        await tap(t, find.text('Run Full Test'));
        expect(c.lastTestResult, 'pass',
            reason:
                '${c.testStatusMessage}: ${c.activeLadderStages.map((s) => '${s.stageId}: ${s.diagnostics}').join('\n')}');
        expect(c.activeLadderStages, hasLength(11));
        expect(
            c.activeLadderStages.where((s) => s.status == 'failed'), isEmpty);
        expect(c.currentEvidence, isNotEmpty);
        expect(c.currentEvidence.single['profileDigest'],
            c.currentDraft!.payloadDigest);
        expect(find.text('Publish to Testing'), findsOneWidget);
        expect(
            find.text(
                'Cloud Profile signing is not ready. Configure the signer and refresh access.'),
            publishing ? findsNothing : findsOneWidget);
        final editor = find.byType(TextField).last;
        await t.enterText(editor, '${c.currentJsonText}\n');
        await t.pump();
        expect(c.isDirty, isTrue);
        await tap(t, find.text('Save'));
        expect(c.isDirty, isFalse);
        final saved = await t.runAsync(() => c.store.loadDraft(spec.$3));
        expect(saved!.payloadDigest, c.currentDraft!.payloadDigest);
        await tap(t, find.text('Sync to Cloud'));
        expect(cloud.creates, 1);
        expect(cloud.updates, 0);
        expect(cloud.draft!['payloadDigest'], c.currentDraft!.payloadDigest);
        expect(cloud.draft!['lifecycleState'], 'draft');
        expect(find.textContaining('Synced to Cloud'), findsOneWidget);
        expect(c.selectedCloudDefinition?['channels'], isEmpty);
        expect(c.canPublish, publishing);
        expect(t.takeException(), isNull);
        if (publishing) {
          await tap(t, find.text('Publish to Testing'));
          expect(cloud.publications, 1);
          expect(cloud.qualification!['profileDigest'],
              c.currentDraft!.payloadDigest);
          expect(cloud.draft!['lifecycleState'], 'testing');
          expect(c.selectedWorkerState.status,
              WorkerLifecycleStatus.publishedTesting);
          expect(find.text('Publish to Testing'), findsNothing);
          await tap(t, find.text('View Releases'));
          expect(find.text('No published Profile yet'), findsNothing);
          expect(find.text('v1'), findsWidgets);
          expect(c.selectedCloudDefinition!['channels']['testing'], 1);
          expect(t.takeException(), isNull);
        }
        if (spec.$1 == 'chatgpt' && !publishing) {
          final digest = c.currentDraft!.payloadDigest;
          final evidence = jsonEncode(c.currentEvidence);
          c.dispose();
          auth = _Auth();
          c = _Controller(
              paths: ProfileLabPaths(homeDirectory: temp.path),
              cloud: cloud,
              auth: auth,
              environment: {
                'HOME': temp.path,
                'PATH':
                    '${temp.path}/.local/bin:${Platform.environment['PATH']}'
              });
          await t.runAsync(
              () => c.initialize(loadEngine: false, scanProviders: false));
          await t.pumpWidget(ProfileLabApp(
              key: const ValueKey('restored-local-data'), controller: c));
          await tap(t, find.text('Sign In'));
          await tap(
              t,
              find.descendant(
                  of: find.byType(WorkerSidebarItem),
                  matching: find.text(spec.$2)));
          await tap(t, find.byKey(const ValueKey('subview-draftAndTest')));
          expect(c.currentDraft!.payloadDigest, digest);
          expect(jsonEncode(c.currentEvidence), evidence);
          expect(c.selectedWorkerState.lastTestResult, 'pass');
          expect(find.text('Create Initial Draft'), findsNothing);
          expect(find.textContaining('Synced to Cloud'), findsOneWidget);
          expect(cloud.creates, 1);
          expect(t.takeException(), isNull);
        }
      });
    }
  }
  testWidgets(
      'future Worker without template creates a blank Draft from its catalog identity',
      (t) async {
    await t.runAsync(() => prepare(
        'future', 'Future Worker', 'future-cli', 'future-cli',
        template: false));
    await signInAndSelect(t, 'Future Worker');
    await tap(t, find.text('Create blank Profile'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(c.currentDraft!.profileDefinitionId, 'future-cli');
    expect(c.currentDraft!.logicalWorkerTypeId, 'future');
    expect(
        (c.currentDraft!.profile['providerTool']
            as Map)['executableCandidates'],
        ['future-cli']);
    expect(c.currentEvidence, isEmpty);
    expect(cloud.draft, isNull);
    expect(find.text('Create Initial Draft'), findsNothing);
    expect(t.takeException(), isNull);
  });
}

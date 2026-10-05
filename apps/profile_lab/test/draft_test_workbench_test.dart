import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/theme/profile_lab_theme.dart';
import 'package:conclave_profile_lab/views/draft_test_workbench.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ProfileLabController {
  _Controller(ProfileLabPaths paths)
      : super(
            paths: paths,
            sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths));

  int saves = 0;
  int syncs = 0;
  @override
  Future<void> saveCurrentDraft(
      {String author = 'developer', String notes = ''}) async {
    saves++;
    isDirty = false;
    notifyListeners();
  }

  @override
  Future<void> saveCurrentDraftToCloud(
      {bool force = false,
      String author = 'developer',
      String notes = ''}) async {
    syncs++;
    cloudDraftExists = true;
    cloudDraftVersion = currentDraft!.releaseVersion;
    cloudDigest = currentDraft!.payloadDigest;
    notifyListeners();
  }
}

void main() {
  late Directory temp;
  late _Controller c;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('draft_workbench_');
    c = _Controller(ProfileLabPaths(homeDirectory: temp.path));
    final payload = jsonDecode(await File(
            '../../packages/tool-profile/test/fixtures/chatgpt-codex.v1.json')
        .readAsString()) as Map<String, dynamic>;
    c.currentDraft = await c.store
        .saveDraft(profileDefinitionId: 'chatgpt-codex', profileJson: payload);
    c.currentJsonText = const JsonEncoder.withIndent('  ').convert(payload);
    c.selectedDefinitionId = 'chatgpt-codex';
    c.cloudDraftExists = false;
    c.currentSession = ProfileLabSession(
        credential: 'test',
        sessionId: 'test',
        userId: 'test',
        displayName: 'Operator',
        email: 'operator@example.invalid',
        expiresAt: DateTime.now().add(const Duration(hours: 1)));
  });
  tearDown(() async {
    c.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: ProfileLabTheme.darkTheme,
        home: Scaffold(
            body: AnimatedBuilder(
                animation: c,
                builder: (_, __) => DraftTestWorkbench(controller: c)))));
  }

  testWidgets(
      'wide workbench resizes and preserves edits through pane collapse and Inspector',
      (tester) async {
    await mount(tester, const Size(1400, 850));
    expect(find.text('LOCAL DRAFTS'), findsNothing);
    expect(find.text('Split View'), findsNothing);
    expect(find.text('Editor Only'), findsNothing);
    expect(find.text('Test Bench Only'), findsNothing);
    expect(find.text('Draft v1 · Saved locally · Not synced to Cloud'),
        findsOneWidget);
    final editor = find.byKey(const ValueKey('profile-json-editor'));
    final before = tester.getSize(editor).width;
    await tester.drag(
        find.byKey(const ValueKey('workbench-divider')), const Offset(100, 0));
    await tester.pump();
    expect(tester.getSize(editor).width, greaterThan(before));
    final changed = '${c.currentJsonText}\n';
    await tester.enterText(find.byType(TextField), changed);
    await tester.pump();
    expect(find.text('Save'), findsOneWidget);
    final run = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run Full Test'));
    expect(run.onPressed, isNull);
    await tester.tap(find.byTooltip('Collapse editor'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Profile Tests'), findsOneWidget);
    await tester.tap(find.byTooltip('Show editor'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        changed);
    await tester.tap(find.byTooltip('Show Inspector'));
    await tester.pump();
    expect(find.text('Inspector'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide Inspector'));
    await tester.pump();
    expect(find.text('Inspector'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Save then Sync to Cloud is the primary workflow',
      (tester) async {
    await mount(tester, const Size(1200, 800));
    c.updateJsonText(c.currentJsonText);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(c.saves, 1);
    expect(c.syncs, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Sync to Cloud'));
    await tester.pumpAndSettle();
    expect(c.syncs, 1);
    expect(find.text('Draft v1 · Saved locally · Synced to Cloud'),
        findsOneWidget);
    c.cloudDraftVersion = 2;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Draft v1 · Saved locally · Not synced to Cloud'),
        findsOneWidget);
    c.updateJsonText('{ invalid');
    await tester.pump();
    expect(find.textContaining('Synced to Cloud'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
  });

  testWidgets('Cloud conflicts stay actionable in a short split pane',
      (tester) async {
    await mount(tester, const Size(1050, 460));
    c.syncState = DraftSyncState.conflict;
    c.cloudDraftPayload = Map<String, dynamic>.from(c.currentDraft!.profile);
    c.isDirty = true;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Draft v1 · Unsaved changes · Cloud conflict'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Overwrite Cloud Draft'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Compare Local vs Cloud'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'advanced actions stay in overflow and format updates the dirty editor',
      (tester) async {
    await mount(tester, const Size(1200, 800));
    expect(find.text('Experimental Repair'), findsNothing);
    expect(find.text('AI Proposal'), findsNothing);
    c.updateJsonText(jsonEncode(c.currentDraft!.profile));
    await tester.pump();
    await tester.tap(find.byTooltip('More draft actions'));
    await tester.pumpAndSettle();
    for (final action in [
      'Format JSON',
      'Compare',
      'Duplicate as Next Release',
      'Revert',
      'AI Proposal',
      'Experimental Repair'
    ]) {
      expect(find.text(action), findsOneWidget);
    }
    await tester.tap(find.text('Format JSON'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        contains('\n  "schemaVersion"'));
    expect(c.isDirty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed tests expose contextual repair and narrow panes remain usable',
      (tester) async {
    await mount(tester, const Size(760, 520));
    expect(find.text('Experimental Repair'), findsNothing);
    c.testedDraftDigest = c.currentDraft!.payloadDigest;
    c.testedProfileDefinitionId = c.currentDraft!.profileDefinitionId;
    c.lastTestResult = 'fail';
    c.testStatusMessage = 'Provider test failed';
    c.notifyListeners();
    await tester.pump();
    await tester.tap(find.byTooltip('Collapse editor'));
    await tester.pump();
    expect(find.text('Repair Profile'), findsOneWidget);
    await tester.ensureVisible(find.text('Repair Profile'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Collapse tests'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Profile Tests'), findsNothing);
    await tester.tap(find.byTooltip('Show tests'));
    await tester.pump();
    final divider = find.byKey(const ValueKey('workbench-divider'));
    final before = tester.getTopLeft(divider).dy;
    await tester.drag(divider, const Offset(0, 35));
    await tester.pump();
    expect(tester.getTopLeft(divider).dy, greaterThan(before));
    expect(tester.takeException(), isNull);
  });
}

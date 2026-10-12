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
      'editor-first workbench keeps tests collapsed and preserves edits',
      (tester) async {
    await mount(tester, const Size(1400, 850));
    expect(find.text('LOCAL DRAFTS'), findsNothing);
    expect(find.text('Split View'), findsNothing);
    expect(find.text('Editor Only'), findsNothing);
    expect(find.text('Test Bench Only'), findsNothing);
    expect(find.text('Draft v1 · Saved locally · Not synced to Cloud'),
        findsOneWidget);
    final editor = find.byKey(const ValueKey('profile-json-editor'));
    expect(find.text('Profile Tests'), findsNothing);
    await tester.tap(find.byTooltip('Show tests'));
    await tester.pump();
    final before = tester.getSize(editor).height;
    await tester.drag(
        find.byKey(const ValueKey('workbench-divider')), const Offset(0, 40));
    await tester.pump();
    expect(tester.getSize(editor).height, greaterThan(before));
    final changed = '${c.currentJsonText}\n';
    await tester.enterText(find.byType(EditableText), changed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Save'), findsOneWidget);
    final run = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Run tests'));
    expect(run.onPressed, isNull);
    await tester.tap(find.byTooltip('Collapse editor'));
    await tester.pump();
    expect(find.byType(EditableText), findsNothing);
    expect(find.text('Profile Tests'), findsOneWidget);
    await tester.tap(find.byTooltip('Show editor'));
    await tester.pump();
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        changed);
    await tester.tap(find.byTooltip('Show Inspector'));
    await tester.pump();
    expect(find.text('Inspector'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide Inspector'));
    await tester.pump();
    expect(find.text('Inspector'), findsNothing);
    await tester.tap(find.byTooltip('Focus editor'));
    await tester.pump();
    expect(find.text('Profile Tests'), findsNothing);
    await tester.tap(find.byTooltip('Exit focused editor'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Save and development actions keep stable purposes',
      (tester) async {
    await mount(tester, const Size(1200, 800));
    c.updateJsonText(c.currentJsonText);
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(c.saves, 1);
    expect(c.syncs, 0);
    expect(find.widgetWithText(OutlinedButton, 'Validate'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Run tests'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Publish'), findsOneWidget);
    c.cloudDraftVersion = 2;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('Draft v1 · Saved locally · Not synced to Cloud'),
        findsOneWidget);
    c.updateJsonText('{ invalid');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('Synced to Cloud'), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Save'))
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
    expect(find.byType(EditableText), findsOneWidget);
    expect(find.text('Compare Local vs Cloud'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'advanced actions stay in overflow and format updates the dirty editor',
      (tester) async {
    await mount(tester, const Size(1200, 800));
    expect(find.text('AI Repair'), findsNothing);
    expect(find.text('AI Proposal'), findsNothing);
    c.updateJsonText(jsonEncode(c.currentDraft!.profile));
    await tester.pump();
    await tester.tap(find.byTooltip('More draft actions'));
    await tester.pumpAndSettle();
    for (final action in [
      'Format JSON',
      'Compare with current Profile',
      'Restore saved Profile',
      'Restore recovery snapshot',
      'AI Repair'
    ]) {
      expect(find.text(action), findsOneWidget);
    }
    await tester.tap(find.text('Format JSON'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        contains('\n  "schemaVersion"'));
    expect(c.isDirty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed tests expose contextual repair and narrow panes remain usable',
      (tester) async {
    await mount(tester, const Size(760, 520));
    expect(find.text('AI Repair'), findsNothing);
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
    expect(find.byType(EditableText), findsOneWidget);
    expect(find.text('Profile Tests'), findsNothing);
    await tester.tap(find.byTooltip('Show tests'));
    await tester.pump();
    final divider = find.byKey(const ValueKey('workbench-divider'));
    final before = tester.getTopLeft(divider).dy;
    await tester.drag(divider, const Offset(0, -35));
    await tester.pump();
    expect(tester.getTopLeft(divider).dy, lessThan(before));
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:syntila_profile_lab/controllers/profile_lab_controller.dart';
import 'package:syntila_profile_lab/profile_lab_auth.dart';
import 'package:syntila_profile_lab/profile_lab_paths.dart';
import 'package:syntila_profile_lab/profile_lab_session_store.dart';
import 'package:syntila_profile_lab/theme/profile_lab_theme.dart';
import 'package:syntila_profile_lab/views/draft_test_workbench.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ProfileLabController {
  _Controller(ProfileLabPaths paths)
      : super(
            paths: paths,
            sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths));

  int saves = 0;
  bool failValidation = false;

  @override
  Future<void> saveCurrentDraft(
      {String author = 'developer', String notes = ''}) async {
    saves++;
    isDirty = false;
    notifyListeners();
  }

  @override
  Future<void> validateCurrentDraft() async {
    if (failValidation) {
      throw StateError('Candidate validation failed: schema mismatch');
    }
    return super.validateCurrentDraft();
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
    c.currentProfileRevision = 1;
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

  testWidgets('workbench provides JSON and Tests sub-tabs and preserves edits',
      (tester) async {
    await mount(tester, const Size(1400, 850));
    expect(find.text('LOCAL DRAFTS'), findsNothing);
    expect(find.text('Split View'), findsNothing);
    expect(find.text('Editor Only'), findsNothing);
    expect(find.text('Test Bench Only'), findsNothing);
    expect(find.text('Revision 1'), findsOneWidget);
    expect(find.text('Worker Profile · revision 1'), findsNothing);
    expect(find.byKey(const ValueKey('profile-json-editor')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sub-tab-tests')));
    await tester.pump();
    expect(find.text('Test Results'), findsOneWidget);
    expect(find.text('Event Mapping'), findsNothing);
    expect(find.text('Local acceptance evidence'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Run Full Test'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sub-tab-json')));
    await tester.pump();
    final changed = '${c.currentJsonText}\n';
    await tester.enterText(find.byType(EditableText), changed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Save'), findsOneWidget);
    final run = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Run tests'));
    expect(run.onPressed, isNull);
    await tester.tap(find.byKey(const Key('sub-tab-tests')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sub-tab-json')));
    await tester.pump();
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        changed);
    expect(find.text('Inspector'), findsNothing);
    expect(find.byTooltip('Focus editor'), findsNothing);
    expect(find.byTooltip('Collapse editor'), findsNothing);
    expect(find.byTooltip('Collapse tests'), findsNothing);
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
    expect(find.widgetWithText(OutlinedButton, 'Validate'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Run tests'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Publish'), findsOneWidget);
    c.updateJsonText('{ invalid');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('Cloud conflict'), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Save'))
            .onPressed,
        isNull);
  });

  testWidgets('invalid candidates remain editable in a short split pane',
      (tester) async {
    await mount(tester, const Size(1050, 460));
    c.updateJsonText('{ invalid');
    c.isDirty = true;
    c.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(EditableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct sidebar actions format JSON and compare profiles',
      (tester) async {
    await mount(tester, const Size(1200, 800));
    expect(find.text('AI Repair'), findsNothing);
    expect(find.text('AI Proposal'), findsNothing);
    expect(find.text('Profile history'), findsNothing);
    expect(find.text('Restore saved Profile'), findsNothing);
    expect(find.text('Restore recovery snapshot'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Format JSON'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Compare'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Reload from file'),
        findsOneWidget);

    c.updateJsonText(jsonEncode(c.currentDraft!.profile));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Format JSON'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        contains('\n  "schemaVersion"'));
    expect(c.isDirty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sub-tabs and narrow panes remain usable when tests fail',
      (tester) async {
    await mount(tester, const Size(760, 520));
    expect(find.text('AI Repair'), findsNothing);
    c.testedDraftDigest = c.currentDraft!.payloadDigest;
    c.testedProfileDefinitionId = c.currentDraft!.profileDefinitionId;
    c.lastTestResult = 'fail';
    c.testStatusMessage = 'Provider test failed';
    c.notifyListeners();
    await tester.pump();

    // Switch to Tests sub-tab
    await tester.tap(find.byKey(const Key('sub-tab-tests')));
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Switch back to JSON sub-tab
    await tester.tap(find.byKey(const Key('sub-tab-json')));
    await tester.pump();
    expect(find.byType(EditableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Validate displays error popup with copy icon that copies error message',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await mount(tester, const Size(1200, 800));
    c.isDirty = false;
    c.failValidation = true;
    c.notifyListeners();
    await tester.pump();

    final validateBtn = find.widgetWithText(OutlinedButton, 'Validate');
    expect(validateBtn, findsOneWidget);
    await tester.tap(validateBtn);
    await tester.pumpAndSettle();

    expect(find.textContaining('Candidate validation failed: schema mismatch'),
        findsOneWidget);
    final copyBtn = find.byKey(const Key('copy-error-message-button'));
    expect(copyBtn, findsOneWidget);
    await tester.tap(copyBtn);
    await tester.pumpAndSettle();

    expect(copied, contains('Candidate validation failed: schema mismatch'));
    expect(find.text('Error message copied'), findsOneWidget);
  });

  testWidgets(
      'continuous JSON validation banner exposes copy icon on invalid JSON',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await mount(tester, const Size(1200, 800));
    c.updateJsonText('{ invalid');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    final copyBannerBtn = find.byKey(const Key('copy-json-validation-error'));
    expect(copyBannerBtn, findsOneWidget);
    await tester.tap(copyBannerBtn);
    await tester.pump();

    expect(copied, contains('Invalid JSON'));
    expect(find.text('Validation error copied'), findsOneWidget);
  });
}

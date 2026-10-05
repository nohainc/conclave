import 'dart:io';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/utils/activity_event_summary.dart';
import 'package:conclave_profile_lab/views/audit_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ProfileLabController {
  _Controller(ProfileLabPaths paths)
      : super(
            paths: paths,
            sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths));
  final filters = <bool?>[];
  @override
  Future<void> fetchCloudAudit({bool? definitionOnly}) async {
    filters.add(definitionOnly);
    auditFilterCurrentDefinition =
        definitionOnly ?? auditFilterCurrentDefinition;
    notifyListeners();
  }
}

void main() {
  test('formats lifecycle events and handles unknown actors honestly', () {
    expect(
        activityEventSummary(
            {'action': 'promoted', 'channel': 'beta', 'releaseVersion': 3},
            workerName: 'ChatGPT', actorName: 'Vitalii'),
        'ChatGPT v3 promoted to Beta by Vitalii');
    expect(
        activityEventSummary({
          'action': 'rolled_back',
          'channel': 'stable',
          'releaseVersion': 2,
          'previousReleaseVersion': 3,
          'actorUserId': 'unknown-id'
        }, workerName: 'Gemini'),
        'Stable rolled back to Gemini v2 from v3 by an operator');
    expect(
        activityEventSummary({'action': 'future_action', 'channel': ''},
            workerName: 'Future Worker'),
        'Future Worker: future action by System');
  });
  testWidgets(
      'Activity defaults to all events and hides raw metadata behind expansion',
      (tester) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = Directory.systemTemp.createTempSync('activity_test_');
    final c = _Controller(ProfileLabPaths(homeDirectory: temp.path));
    addTearDown(() async {
      c.dispose();
      temp.deleteSync(recursive: true);
    });
    c.currentSession = ProfileLabSession(
        credential: 'test',
        sessionId: 'session',
        userId: 'me',
        displayName: 'Me',
        email: 'me@example.invalid',
        expiresAt: DateTime.now().add(const Duration(hours: 1)));
    c.selectedDefinitionId = 'chatgpt-codex';
    c.selectedCloudWorker = {'displayName': 'ChatGPT'};
    c.cloudAuditEvents = [
      {
        'id': 'raw-event-id',
        'profileDefinitionId': 'chatgpt-codex',
        'releaseVersion': 3,
        'action': 'promoted',
        'channel': 'beta',
        'actorUserId': 'raw-actor-id',
        'actorDisplayName': 'Vitalii',
        'workerDisplayName': 'ChatGPT',
        'createdAt': '2026-10-05'
      }
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AnimatedBuilder(
                animation: c, builder: (_, __) => AuditView(controller: c)))));
    expect(c.auditFilterCurrentDefinition, isFalse);
    expect(find.text('ChatGPT v3 promoted to Beta by Vitalii'), findsOneWidget);
    expect(find.textContaining('raw-actor-id'), findsNothing);
    await tester.tap(find.text('ChatGPT v3 promoted to Beta by Vitalii'));
    await tester.pumpAndSettle();
    expect(find.textContaining('raw-actor-id'), findsOneWidget);
    await tester.tap(find.text('ChatGPT'));
    await tester.pumpAndSettle();
    expect(c.filters.last, isTrue);
    await tester.tap(find.text('All events'));
    await tester.pumpAndSettle();
    expect(c.filters.last, isFalse);
    expect(tester.takeException(), isNull);
  });
}

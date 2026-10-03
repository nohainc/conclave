import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/views/workers_view.dart';
import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Create Worker uses catalog stages and canonical capabilities',
      (tester) async {
    final controller = ProfileLabController(
      paths: ProfileLabPaths(homeDirectory: '/private/tmp/workers_view_test'),
    )
      ..currentSession = ProfileLabSession(
        credential: 'test-credential',
        sessionId: 'test-session',
        userId: 'test-user',
        displayName: 'Test User',
        email: 'test@example.invalid',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      )
      ..cloudWorkers = [
        {
          'workerTypeId': 'existing-worker',
          'displayName': 'Existing Worker',
        },
      ];
    addTearDown(() async {
      controller.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkersView(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('Create Worker + Definition'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));

    expect(find.text('Testing'), findsOneWidget);
    expect(find.text('Draft'), findsNothing);
    expect(find.byType(FilterChip), findsNWidgets(8));
    for (final capability in canonicalWorkerCapabilities) {
      expect(find.widgetWithText(FilterChip, capability), findsOneWidget);
    }
    expect(
      tester
          .widget<FilterChip>(
            find.widgetWithText(FilterChip, 'text'),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(
            find.widgetWithText(FilterChip, 'workstream_write'),
          )
          .selected,
      isFalse,
    );

    final imageCapability = find.widgetWithText(FilterChip, 'image');
    await tester.ensureVisible(imageCapability);
    await tester.tap(imageCapability);
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'image'))
          .selected,
      isTrue,
    );
  });
}

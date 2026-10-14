import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'ax_fixture_data.dart';

class RetrySource extends AxFixtureDataSource {
  RetrySource({required this.allowed, required this.confirmation});
  final bool allowed;
  final bool confirmation;
  final approvals = <bool>[];

  @override
  Future<List<AxWorkRequest>> workRequestRows(
          {required String threadId, bool activeOnly = false}) async =>
      [
        AxWorkRequest(
            id: 'request',
            requestedByName: 'You',
            prompt: 'Verify changes',
            workflowId: 'verify',
            workflowVersion: 1,
            status: 'failed',
            createdAt: '2026-10-14T10:00:00Z',
            executionPhase: 'failed',
            steps: [
              AxWorkRequestStep(
                  kind: 'verify',
                  status: 'failed',
                  workerId: 'worker',
                  executionPhase: 'failed',
                  workerDisplayName: 'Test Worker',
                  failureCategory: 'provider_start_failed',
                  failureCategoryMessage: 'AI provider could not start',
                  retryAllowed: allowed,
                  retryRequiresConfirmation: confirmation)
            ])
      ];

  @override
  Future<void> retryWorkRequestStep(
      {required String workRequestId,
      required String stepKind,
      String? sessionStrategy,
      bool confirmSideEffects = false}) async {
    expect(workRequestId, 'request');
    expect(stepKind, 'verify');
    approvals.add(confirmSideEffects);
  }
}

Widget page(RetrySource source) => MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      initialTab: 1,
      space:
          const AxSpace(id: 's', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 't',
          spaceId: 's',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: source,
      onBackToSpace: () {},
      onArchive: () {},
    )));

void main() {
  testWidgets(
      'safe retry sends no side-effect approval and shows public failure',
      (tester) async {
    final source = RetrySource(allowed: true, confirmation: false);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    expect(find.text('AI provider could not start'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(source.approvals, [false]);
    expect(find.text('Retry anyway?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('ambiguous retry requires approval; cancelling sends nothing',
      (tester) async {
    final source = RetrySource(allowed: true, confirmation: true);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    final retry = find.byTooltip(
        'Retry anyway — the previous execution may already have made changes');
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(source.approvals, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(source.approvals, isEmpty);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Retry anyway'));
    await tester.pumpAndSettle();
    expect(source.approvals, [true]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('unconfirmed stop offers no retry', (tester) async {
    final source = RetrySource(allowed: false, confirmation: true);
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Retry'), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(source.approvals, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}

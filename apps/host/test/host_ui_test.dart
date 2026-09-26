import 'package:conclave_host/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpDashboard(
    WidgetTester tester,
    HostUiSnapshot snapshot, {
    VoidCallback? onPair,
    VoidCallback? onAccountAction,
    Future<void> Function()? onRetry,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostDashboard(
            snapshot: snapshot,
            onPair: onPair,
            onAccountAction: onAccountAction,
            onRetry: onRetry,
          ),
        ),
      ),
    );
  }

  testWidgets('first launch focuses the user on pairing', (tester) async {
    var paired = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Pair this Workspace',
        detail: 'Connect this machine to Conclave to begin.',
      ),
      onPair: () => paired = true,
    );

    expect(find.text('Start pairing'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Chats'), findsNothing);
    await tester.tap(find.text('Start pairing'));
    expect(paired, isTrue);
  });

  testWidgets('paired Workspace shows machine controls, not orchestration',
      (tester) async {
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'This machine is paired and ready to run assigned work.',
        paired: true,
        cloudConnected: true,
        hostId: 'host-a',
        repositorySummary: '2 repositories registered',
        permissionSummary: 'Filesystem access is ready',
        workerSummary: '2 Workers healthy',
        logsPath: '/tmp/host.log',
        updateSummary: 'Up to date',
      ),
    );

    expect(find.text('Repositories and permissions'), findsOneWidget);
    expect(find.text('Workers'), findsOneWidget);
    expect(find.text('Add Worker'), findsOneWidget);
    expect(find.text('Logs'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Updates'), 300);
    expect(find.text('Updates'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Quit Workspace'), 300);
    expect(find.text('Quit Workspace'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Workspace management'), findsNothing);
    expect(find.text('New Worker'), findsNothing);
  });

  testWidgets('auth needed exposes local account action', (tester) async {
    var opened = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.authNeeded,
        title: 'Account action needed',
        detail: 'Sign in locally before this Workspace can run work.',
        accountsNeedingAction: ['Personal Codex'],
      ),
      onAccountAction: () => opened = true,
    );

    expect(find.text('Accounts needing attention'), findsOneWidget);
    expect(find.text('Personal Codex'), findsOneWidget);
    await tester.tap(find.text('Open account setup'));
    expect(opened, isTrue);
  });

  testWidgets('active, offline, and install failure states stay understandable',
      (tester) async {
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.active,
        title: 'Work in progress',
        detail: 'The Workspace is running assigned work.',
        activeAssignments: 2,
      ),
    );
    expect(find.text('2 active assignments'), findsOneWidget);

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.offline,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect.',
        issue: 'Network unavailable',
      ),
    );
    expect(find.text('Network unavailable'), findsOneWidget);

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.installFailure,
        title: 'Worker update needs attention',
        detail: 'The last Worker update could not be installed.',
        issue: 'Signature rejected',
      ),
    );
    expect(find.text('Signature rejected'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Workers'), 300);
    expect(find.text('Workers'), findsOneWidget);
  });

  testWidgets('install failure explains safety and offers recovery',
      (tester) async {
    var retried = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.installFailure,
        title: 'Worker update needs attention',
        detail: 'The last Worker update could not be installed.',
        issue: 'Signature rejected',
      ),
      onRetry: () async => retried = true,
    );

    expect(find.text('What happened'), findsOneWidget);
    expect(
        find.text(
            'Your work is safe. The Workspace will not discard an assignment.'),
        findsOneWidget);
    await tester.tap(find.text('Retry update'));
    expect(retried, isTrue);
  });

  testWidgets('advanced details are available through accessible labels',
      (tester) async {
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        paired: true,
        cloudConnected: true,
        hostId: 'host-a',
      ),
    );

    expect(find.bySemanticsLabel('Machine status'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Advanced details'), 300);
    expect(find.text('Advanced details'), findsOneWidget);
    await tester.tap(find.text('Advanced details'));
    await tester.pumpAndSettle();
    expect(find.text('Workspace ID'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
  });
}

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
    Future<void> Function()? onExportDiagnostics,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostDashboard(
            snapshot: snapshot,
            onPair: onPair,
            onAccountAction: onAccountAction,
            onRetry: onRetry,
            onExportDiagnostics: onExportDiagnostics,
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
        workspaceName: 'MacBook Pro',
        workspaceId: 'ws-123',
        hostId: 'host-a',
        workRootPath: '/Users/test/Work',
        logsPath: '/tmp/host.log',
        updateSummary: 'Up to date',
      ),
    );

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Workers'), findsWidgets);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('Open Conclave AX'), findsOneWidget);
    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('Current Work'), findsOneWidget);
    expect(find.text('Add Worker'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Workspace management'), findsNothing);
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
        activeAssignmentIds: ['assignment-1', 'assignment-2'],
      ),
    );
    expect(find.text('2 active'), findsOneWidget);
    expect(find.text('assignment-1'), findsOneWidget);

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

  testWidgets('diagnostics tab displays identity and connection metrics',
      (tester) async {
    var exported = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        paired: true,
        cloudConnected: true,
        workspaceId: 'ws-test-123',
        hostId: 'runtime-host-a',
        logsPath: '/var/logs/host.log',
      ),
      onExportDiagnostics: () async => exported = true,
    );

    expect(find.bySemanticsLabel('Machine status'), findsOneWidget);
    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();

    expect(find.text('Machine & Runtime Identity'), findsOneWidget);
    expect(find.text('Workspace ID'), findsOneWidget);
    expect(find.text('ws-test-123'), findsOneWidget);
    expect(find.text('Runtime ID'), findsOneWidget);
    expect(find.text('runtime-host-a'), findsOneWidget);
    expect(find.text('Cloud Gateway Connection'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);

    expect(find.text('Export Report'), findsOneWidget);
    await tester.tap(find.text('Export Report'));
    expect(exported, isTrue);
  });

  testWidgets('settings tab displays work root and cloud pairing',
      (tester) async {
    var paired = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        paired: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
        workspaceId: 'ws-456',
        hostId: 'host-456',
        cloudUrl: 'https://app.conclaveax.com',
        workRootPath: '/workspace/root',
      ),
      onPair: () => paired = true,
    );

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Work Root Directory'), findsOneWidget);
    expect(find.text('/workspace/root'), findsOneWidget);
    expect(find.text('Cloud Pairing'), findsOneWidget);
    expect(find.text('Office Mac'), findsWidgets);
    expect(find.text('https://app.conclaveax.com'), findsOneWidget);

    await tester.tap(find.text('Re-pair Workspace'));
    expect(paired, isTrue);
  });
}


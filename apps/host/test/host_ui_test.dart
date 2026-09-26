import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpDashboard(
    WidgetTester tester,
    HostUiSnapshot snapshot, {
    VoidCallback? onPair,
    VoidCallback? onUnpair,
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
            onUnpair: onUnpair,
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

    expect(find.text('Pair with Conclave AX'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Chats'), findsNothing);
    await tester.tap(find.text('Pair with Conclave AX'));
    expect(paired, isTrue);
  });

  testWidgets('unpaired offline Workspace can still open pairing',
      (tester) async {
    var opened = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.offline,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect.',
        issue: 'Network unavailable',
      ),
      onPair: () => opened = true,
    );

    expect(find.text('Pair with Conclave AX'), findsOneWidget);
    await tester.tap(find.text('Pair with Conclave AX'));
    expect(opened, isTrue);
  });

  testWidgets('paired Workspace shows two-surface tabs (Workspace and Workers)',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Workers'), findsWidgets);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Open Conclave AX'), findsOneWidget);
    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('Current Work'), findsOneWidget);
    expect(find.text('View Workers'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Workspace management'), findsNothing);
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
    expect(find.text('2 active assignments running.'), findsOneWidget);

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

  testWidgets('advanced diagnostics accordion displays identity and metrics',
      (tester) async {
    var exported = false;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    expect(find.bySemanticsLabel('Workspace status'), findsOneWidget);
    expect(find.text('Advanced & Diagnostics'), findsOneWidget);

    await tester.ensureVisible(find.text('Advanced & Diagnostics'));
    await tester.tap(find.text('Advanced & Diagnostics'));
    await tester.pumpAndSettle();

    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Workspace ID'), findsOneWidget);
    expect(find.text('ws-test-123'), findsOneWidget);
    expect(find.text('Runtime ID'), findsOneWidget);
    expect(find.text('runtime-host-a'), findsOneWidget);
    expect(find.text('Gateway state'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);
    expect(find.text('Open Log File'), findsOneWidget);

    final exportBtn = find.text('Export Report');
    await tester.ensureVisible(exportBtn);
    await tester.pumpAndSettle();
    expect(exportBtn, findsOneWidget);
    await tester.tap(exportBtn);
    expect(exported, isTrue);
  });

  testWidgets('workspace tab displays work root, cloud pairing, and unpair',
      (tester) async {
    var paired = false;
    var unpaired = false;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
      onUnpair: () => unpaired = true,
    );

    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('/workspace/root'), findsOneWidget);
    expect(find.text('Cloud Pairing'), findsOneWidget);
    expect(find.text('Connected as “Office Mac”'), findsOneWidget);

    await tester.tap(find.text('Re-pair'));
    expect(paired, isTrue);

    await tester.ensureVisible(find.text('Advanced & Diagnostics'));
    await tester.tap(find.text('Advanced & Diagnostics'));
    await tester.pumpAndSettle();

    final unpairBtn = find.text('Unpair Workspace');
    await tester.ensureVisible(unpairBtn);
    await tester.pumpAndSettle();
    expect(unpairBtn, findsOneWidget);
    await tester.tap(unpairBtn);
    expect(unpaired, isTrue);
  });

  testWidgets('switching to workers surface displays configured workers area',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        paired: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
      ),
    );

    expect(find.text('View Workers'), findsOneWidget);
    await tester.tap(find.text('View Workers'));
    await tester.pumpAndSettle();

    expect(find.text('Configured Workers'), findsOneWidget);
    expect(find.text('Add Worker'), findsOneWidget);
  });

  group('deriveLocalWorkerHealth', () {
    LocalConfiguredWorker makeWorker({
      LocalWorkerStatus status = LocalWorkerStatus.ready,
      LocalWorkerCredentialStatus credentialStatus =
          LocalWorkerCredentialStatus.ready,
      String authStrategy = 'browser_auth',
      List<String> permissions = const ['workstream_filesystem'],
      Map<String, Object?> adapterConfig = const {},
    }) {
      return LocalConfiguredWorker(
        id: 'worker-1',
        workspaceId: 'ws-1',
        name: 'Test Worker',
        workerTypeId: 'claude-code',
        authStrategy: authStrategy,
        credentialRef: 'cred-1',
        defaultModel: 'claude-3-7-sonnet',
        adapterConfig: adapterConfig,
        allowedModels: const ['claude-3-7-sonnet'],
        localPermissions: permissions,
        localConcurrencyLimit: 2,
        adapterVersionPolicy: 'latest',
        status: status,
        credentialStatus: credentialStatus,
        revision: 42,
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );
    }

    test('derives Ready for healthy worker', () {
      final worker = makeWorker();
      expect(deriveLocalWorkerHealth(worker), 'Ready');
    });

    test('derives Disabled for disabled worker', () {
      final worker = makeWorker(status: LocalWorkerStatus.disabled);
      expect(deriveLocalWorkerHealth(worker), 'Disabled');
    });

    test('derives Sign in required when authentication is needed or expired', () {
      expect(
        deriveLocalWorkerHealth(
          makeWorker(
              status: LocalWorkerStatus.needsAttention,
              credentialStatus: LocalWorkerCredentialStatus.needsAuthentication),
        ),
        'Sign in required',
      );
      expect(
        deriveLocalWorkerHealth(
          makeWorker(credentialStatus: LocalWorkerCredentialStatus.expired),
        ),
        'Sign in required',
      );
    });

    test('derives CLI missing when cliMissing flag is present', () {
      final worker = makeWorker(
        status: LocalWorkerStatus.needsAttention,
        adapterConfig: {'cliMissing': true},
      );
      expect(deriveLocalWorkerHealth(worker), 'CLI missing');
    });

    test('derives Adapter unavailable when adapterMissing flag is present', () {
      final worker = makeWorker(
        status: LocalWorkerStatus.needsAttention,
        adapterConfig: {'adapterMissing': true},
      );
      expect(deriveLocalWorkerHealth(worker), 'Adapter unavailable');
    });

    test('derives Endpoint unavailable for local endpoint error', () {
      final worker = makeWorker(
        authStrategy: 'local_endpoint',
        status: LocalWorkerStatus.needsAttention,
        credentialStatus: LocalWorkerCredentialStatus.error,
      );
      expect(deriveLocalWorkerHealth(worker), 'Endpoint unavailable');
    });

    test('derives Credential invalid for API key error', () {
      final worker = makeWorker(
        authStrategy: 'api_key',
        status: LocalWorkerStatus.needsAttention,
        credentialStatus: LocalWorkerCredentialStatus.error,
      );
      expect(deriveLocalWorkerHealth(worker), 'Credential invalid');
    });

    test('derives Permission required when localPermissions is empty', () {
      final worker = makeWorker(permissions: const []);
      expect(deriveLocalWorkerHealth(worker), 'Permission required');
    });
  });
}

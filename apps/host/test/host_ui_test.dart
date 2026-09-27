import 'dart:async';
import 'dart:io';

import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/main.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/secure_credentials.dart';
import 'package:conclave_host/workspace_enrollment.dart';
import 'package:conclave_host/workspace_pairing_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestPlatformRuntime implements PlatformRuntime {
  @override
  String get operatingSystem => 'test';
  @override
  bool get isWindows => false;
  @override
  String get homeDirectory => '/tmp';
  @override
  Future<void> restrictPermissions(String path,
      {required bool directory}) async {}
  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
          void Function() onTermination) =>
      [];
  @override
  Future<Process> startIsolatedProcess(
      String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true}) {
    throw UnsupportedError('not used by UI tests');
  }

  @override
  Future<void> terminateProcessTree(Process process,
      {required bool force}) async {}
}

class _MemoryCredentialStore implements SecureCredentialStore {
  final values = <String, String>{};

  @override
  String? readSync(String key) => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeWorkerRegistry extends LocalConfiguredWorkerRegistry {
  _FakeWorkerRegistry(this.workers)
      : super(
          dataDirectory: Directory('/tmp'),
          workspaceId: 'ws-fake',
          platform: _TestPlatformRuntime(),
        );

  final List<LocalConfiguredWorker> workers;

  @override
  Future<List<LocalConfiguredWorker>> list(
          {bool includeRemoved = false}) async =>
      workers
          .where((w) => includeRemoved || w.status != LocalWorkerStatus.removed)
          .toList();

  @override
  Future<LocalConfiguredWorker> update(
      String id,
      LocalConfiguredWorker Function(LocalConfiguredWorker current)
          updater) async {
    final idx = workers.indexWhere((w) => w.id == id);
    if (idx != -1) {
      workers[idx] = updater(workers[idx]);
      return workers[idx];
    }
    throw StateError('Worker not found');
  }
}

void main() {
  Future<void> pumpDashboard(
    WidgetTester tester,
    HostUiSnapshot snapshot, {
    VoidCallback? onPair,
    Future<void> Function(WorkspacePairingRequest request)? onPairRequest,
    VoidCallback? onDisconnect,
    VoidCallback? onUnpair,
    VoidCallback? onReset,
    VoidCallback? onAccountAction,
    VoidCallback? onQuit,
    Future<void> Function()? onRetry,
    Future<void> Function()? onExportDiagnostics,
    Future<void> Function(String path)? onChangeWorkRoot,
    LocalConfiguredWorkerRegistry? localWorkerRegistry,
    SecureCredentialStore? credentialStore,
    Future<void> Function()? onAddWorker,
    Future<String> Function()? resolveComputerName,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostDashboard(
            snapshot: snapshot,
            onPair: onPair,
            onPairRequest: onPairRequest,
            onDisconnect: onDisconnect,
            onUnpair: onUnpair,
            onReset: onReset,
            onAccountAction: onAccountAction,
            onQuit: onQuit,
            onRetry: onRetry,
            onExportDiagnostics: onExportDiagnostics,
            onChangeWorkRoot: onChangeWorkRoot,
            localWorkerRegistry: localWorkerRegistry,
            credentialStore:
                credentialStore ?? const PlatformSecureCredentialStore(),
            onAddWorker: onAddWorker,
            resolveComputerName: resolveComputerName,
          ),
        ),
      ),
    );
  }

  testWidgets(
      'first launch presents clean workspace tab with inline connect card, work root, and diagnostics',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    WorkspacePairingRequest? capturedRequest;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Pair this Workspace',
        detail: 'Connect this machine to Conclave to begin.',
        hostname: 'test-mac',
        workspaceName: "Vitalii's MacBook Pro",
        workRootPath: '/Users/test/Work',
      ),
      onPairRequest: (request) async => capturedRequest = request,
      resolveComputerName: () async => "Vitalii's MacBook Pro",
    );

    expect(find.text('Workspace name'), findsOneWidget);
    expect(find.text("Vitalii's MacBook Pro"), findsOneWidget);
    expect(find.text('Pairing code'), findsOneWidget);
    expect(find.text('Advanced options'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Work Root'), findsOneWidget);
    final workRootField =
        tester.widget<TextField>(find.widgetWithText(TextField, 'Work Root'));
    expect(workRootField.readOnly, isTrue);
    expect(find.text('Browse'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Open folder'), findsOneWidget);
    expect(find.text('Advanced & Diagnostics'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Chats'), findsNothing);

    // Enter code and connect
    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'code-987',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(capturedRequest, isNotNull);
    expect(capturedRequest!.workspaceName, "Vitalii's MacBook Pro");
    expect(capturedRequest!.token, 'code-987');
  });

  testWidgets(
      'first-launch pairing form displays differentiated error messages and actions on failure',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Object? pairingErrorToThrow;

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        paired: false,
        title: 'Pair this Workspace',
        detail: 'Connect this machine to Conclave to begin.',
        hostname: 'test-mac',
        workspaceName: "Vitalii's Custom Mac",
      ),
      onPairRequest: (request) async {
        final error = pairingErrorToThrow;
        if (error != null) {
          throw error;
        }
      },
      resolveComputerName: () async => "Vitalii's Custom Mac",
    );

    // 1. Expired code
    pairingErrorToThrow = const WorkspacePairingException(
      kind: WorkspacePairingErrorKind.expiredCode,
      message: 'This pairing code has expired.',
      action: 'Generate a new code in Conclave AX and try again.',
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'expired-token-123',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(
        find.textContaining('This pairing code has expired.'), findsOneWidget);
    expect(
        find.textContaining(
            'Generate a new code in Conclave AX and try again.'),
        findsOneWidget);
    // Custom name is retained
    expect(find.text("Vitalii's Custom Mac"), findsOneWidget);

    // 2. Already used code
    pairingErrorToThrow = const WorkspacePairingException(
      kind: WorkspacePairingErrorKind.alreadyUsed,
      message: 'This pairing code has already been used.',
      action:
          'Generate a fresh pairing code in Conclave AX to connect this Workspace.',
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'used-token-456',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('This pairing code has already been used.'),
        findsOneWidget);
    expect(
        find.textContaining(
            'Generate a fresh pairing code in Conclave AX to connect this Workspace.'),
        findsOneWidget);

    // 3. Cloud unavailable
    pairingErrorToThrow = const WorkspacePairingException(
      kind: WorkspacePairingErrorKind.cloudUnavailable,
      message: 'Unable to connect to Conclave Cloud.',
      action: 'Check your internet connection or verify the Cloud URL.',
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'valid-looking-code',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unable to connect to Conclave Cloud.'),
        findsOneWidget);
    expect(
        find.textContaining(
            'Check your internet connection or verify the Cloud URL.'),
        findsOneWidget);
  });

  testWidgets('offline Workspace displays recovery panel with retry',
      (tester) async {
    var retried = false;
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.offline,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect.',
        issue: 'Network unavailable',
        paired: true,
        workspaceId: 'workspace-1',
        hostId: 'runtime-1',
        workspaceName: 'Development Mac',
      ),
      onRetry: () async => retried = true,
    );

    expect(find.text('Network unavailable'), findsOneWidget);
    expect(find.text('Development Mac'), findsOneWidget);
    expect(find.text('Offline'), findsNWidgets(2));
    expect(find.text('Pairing code'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
    expect(find.text('Retry connection'), findsOneWidget);
    expect(find.byTooltip('Copy error message'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy error message'));
    await tester.pump();
    expect(copiedText, 'Network unavailable');
    expect(find.text('Error message copied'), findsOneWidget);
    await tester.tap(find.text('Retry connection'));
    expect(retried, isTrue);
  });

  testWidgets(
      'paired Workspace defaults to Workspace tab with two-surface tabs and zero duplicate cards',
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
      onPair: () {},
    );

    // Only Workspace and Workers tabs exist in top navigation
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Workers'), findsWidgets);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Diagnostics'), findsNothing);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Workspace management'), findsNothing);

    // Header actions: 3-lines menu icon, no duplicate button in header
    expect(find.byIcon(Icons.menu), findsOneWidget);

    // Streamlined Workspace tab: Workspace title, display name, Connected indicator, Work Root and Advanced & Diagnostics
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('Advanced & Diagnostics'), findsOneWidget);

    // No pairing form is shown when paired
    expect(find.text('Connect this Workspace'), findsNothing);
    expect(find.text('Pairing code'), findsNothing);
    expect(find.text('Connect'), findsNothing);

    // Removed sections are not on the Workspace tab
    expect(find.text('Current Work'), findsNothing);
    expect(find.text('View Workers'), findsNothing);
    expect(find.bySemanticsLabel('Workspace status'), findsNothing);
  });

  testWidgets('header overflow menu provides AX, updates, about, and quit',
      (tester) async {
    var quitCalled = false;
    var retryCalled = false;

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        paired: true,
        cloudConnected: true,
        statusLabel: 'Connected',
        hostname: 'MacBook Pro',
      ),
      onQuit: () => quitCalled = true,
      onRetry: () async => retryCalled = true,
    );

    expect(find.text('Conclave Workspace'), findsOneWidget);
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);

    // Verify HUD Quit icon button is visible and clickable
    expect(find.byTooltip('Quit Conclave Workspace'), findsOneWidget);
    await tester.tap(find.byTooltip('Quit Conclave Workspace'));
    expect(quitCalled, isTrue);

    // Open overflow menu (3 lines icon)
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Open Conclave AX'), findsOneWidget);
    expect(find.text('Check for Updates'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Advanced Diagnostics'), findsNothing);

    // Tap Check for Updates
    await tester.tap(find.text('Check for Updates'));
    await tester.pumpAndSettle();
    expect(retryCalled, isTrue);

    // Open overflow menu and tap About
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutDialog), findsOneWidget);
    expect(find.text('Conclave Workspace Runtime and Local Worker Manager.'),
        findsOneWidget);
    // Dismiss about dialog
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'install failure explains safety and offers recovery in recovery panel',
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
    expect(find.text('Signature rejected'), findsOneWidget);
    expect(
        find.text(
            'Your work is safe. The Workspace will not discard an assignment.'),
        findsOneWidget);
    await tester.tap(find.text('Retry update'));
    expect(retried, isTrue);
  });

  testWidgets(
      'advanced diagnostics accordion starts collapsed and exposes IDs, logs, metrics upon expansion',
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

    expect(find.text('Advanced & Diagnostics'), findsOneWidget);

    // Before expanding, internal section headers and IDs are collapsed / not shown
    expect(find.text('Runtime ID'), findsNothing);

    await tester.ensureVisible(find.text('Advanced & Diagnostics'));
    await tester.tap(find.text('Advanced & Diagnostics'));
    await tester.pumpAndSettle();

    // After expanding, details are exposed
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

  testWidgets(
      'workspace tab displays work root, disconnect from AX, and reset local workspace',
      (tester) async {
    var disconnected = false;
    var reset = false;
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
      onDisconnect: () => disconnected = true,
      onReset: () => reset = true,
    );

    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('/workspace/root'), findsOneWidget);

    await tester.ensureVisible(find.text('Advanced & Diagnostics'));
    await tester.tap(find.text('Advanced & Diagnostics'));
    await tester.pumpAndSettle();

    final disconnectBtn = find.text('Disconnect from Conclave AX');
    await tester.ensureVisible(disconnectBtn);
    await tester.pumpAndSettle();
    expect(disconnectBtn, findsOneWidget);
    await tester.tap(disconnectBtn);
    expect(disconnected, isTrue);

    final resetBtn = find.text('Reset local Workspace');
    await tester.ensureVisible(resetBtn);
    await tester.pumpAndSettle();
    expect(resetBtn, findsOneWidget);
    await tester.tap(resetBtn);
    expect(reset, isTrue);
  });

  testWidgets(
      'workspace tab renders read-only work root field with browse button and open folder button below',
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
        workRootPath: '/custom/work/root',
      ),
    );

    // Verify read-only TextField
    final textFieldFinder = find.widgetWithText(TextField, 'Work Root');
    expect(textFieldFinder, findsOneWidget);
    final textField = tester.widget<TextField>(textFieldFinder);
    expect(textField.readOnly, isTrue);
    expect(find.text('/custom/work/root'), findsOneWidget);

    // Verify Browse button
    expect(find.text('Browse'), findsOneWidget);

    // Verify Open folder button below with FilledButton style
    final openFolderBtn = find.widgetWithText(FilledButton, 'Open folder');
    expect(openFolderBtn, findsOneWidget);
  });

  testWidgets(
      'workers surface before pairing allows adding workers at any time without blocking',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var addWorkerCalled = false;
    final registry = _FakeWorkerRegistry([]);
    final credentials = _MemoryCredentialStore();

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Pair this Workspace',
        detail: 'Pairing needed',
        paired: false,
        hostname: 'test-mac',
      ),
      localWorkerRegistry: registry,
      credentialStore: credentials,
      onAddWorker: () async => addWorkerCalled = true,
    );

    // Switch to Workers tab
    await tester.tap(find.text('Workers').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Connect this Workspace before adding Workers.'),
        findsNothing);
    expect(
        find.text(
            'Local AI models and execution adapters running on this machine.'),
        findsOneWidget);
    expect(find.text('Configured Workers'), findsNothing);

    // Add Worker button is enabled and clickable
    final addWorkerBtn = find.widgetWithText(FilledButton, 'Add Worker');
    expect(addWorkerBtn, findsWidgets);
    await tester.tap(addWorkerBtn.first);
    await tester.pump();
    expect(addWorkerCalled, isTrue);
  });

  testWidgets(
      'switching to workers surface when paired displays configured workers area',
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

    await tester.tap(find.text('Workers').first);
    await tester.pumpAndSettle();

    expect(find.text('Configured Workers'), findsNothing);
    expect(
        find.text(
            'Local AI models and execution adapters running on this machine.'),
        findsOneWidget);
    expect(find.text('Add Worker'), findsOneWidget);
  });

  testWidgets(
      'workers surface displays worker cards with health badges, auth attention, and detail dialog',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final initialWorker = LocalConfiguredWorker(
      id: 'w-1',
      workspaceId: 'ws-test',
      name: 'Primary Claude Worker',
      workerTypeId: 'claude-code',
      authStrategy: 'browser_auth',
      credentialRef: 'cred-1',
      defaultModel: 'claude-3-7-sonnet',
      adapterConfig: const {},
      allowedModels: const ['claude-3-7-sonnet'],
      localPermissions: const ['workstream_filesystem'],
      localConcurrencyLimit: 1,
      adapterVersionPolicy: 'latest',
      status: LocalWorkerStatus.ready,
      credentialStatus: LocalWorkerCredentialStatus.ready,
      revision: 1,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    );

    final registry = _FakeWorkerRegistry([initialWorker]);
    final credentials = _MemoryCredentialStore();

    var addWorkerCalled = false;
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
      localWorkerRegistry: registry,
      credentialStore: credentials,
      onAddWorker: () async => addWorkerCalled = true,
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Switch to Workers surface
    await tester.tap(find.text('Workers').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Primary Claude Worker'), findsOneWidget);
    expect(find.text('Ready'), findsWidgets);

    // Tap Add Worker
    await tester.tap(find.text('Add Worker'));
    expect(addWorkerCalled, isTrue);

    // Tap worker card to open detail dialog
    await tester.tap(find.text('Primary Claude Worker'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Check detail dialog contents
    expect(find.text('Worker Type'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('claude-3-7-sonnet'), findsWidgets);
    expect(find.text('Concurrency'), findsOneWidget);
    expect(find.text('1 concurrent runs'), findsOneWidget);
    expect(find.text('Edit Worker'), findsOneWidget);
    expect(find.text('Disable locally'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);

    // Disable locally
    await tester.tap(find.text('Disable locally'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Status is updated to Disabled
    final updatedList = await registry.list();
    expect(updatedList.first.status, LocalWorkerStatus.disabled);
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

    test('derives Sign in required when authentication is needed or expired',
        () {
      expect(
        deriveLocalWorkerHealth(
          makeWorker(
              status: LocalWorkerStatus.needsAttention,
              credentialStatus:
                  LocalWorkerCredentialStatus.needsAuthentication),
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

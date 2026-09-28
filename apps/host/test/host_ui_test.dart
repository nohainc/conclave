import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/desktop_auth.dart';
import 'package:conclave_host/main.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/secure_credentials.dart';
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
  Future<String?> read(String key) async => readSync(key);

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
  testWidgets('pairing error notification has a working copy action',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

    const error = 'Could not prepare pairing recovery: MissingPluginException';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showCopyableErrorSnackBar(context, error),
            child: const Text('Show error'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Show error'));
    await tester.pump();
    expect(find.text(error), findsOneWidget);
    expect(find.byTooltip('Copy error message'), findsOneWidget);

    final copyButton = tester.widget<IconButton>(find.ancestor(
      of: find.byTooltip('Copy error message'),
      matching: find.byType(IconButton),
    ));
    copyButton.onPressed!();
    await tester.pump();
    expect(copiedText, error);
  });

  testWidgets(
      'launch-at-login preference is applied through the native desktop API',
      (tester) async {
    final methods = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.conclave.workspace/desktop'),
      (call) async {
        methods.add(call);
        return null;
      },
    );
    addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              const MethodChannel('com.conclave.workspace/desktop'),
              null,
            ));

    await HostLifecycleController.setLaunchAtLogin(true);
    expect(methods.single.method, 'setLaunchAtLogin');
    expect(methods.single.arguments, isTrue);
  });

  Future<void> pumpDashboard(
    WidgetTester tester,
    HostUiSnapshot snapshot, {
    VoidCallback? onDisconnect,
    Future<void> Function()? onRelease,
    VoidCallback? onReset,
    Future<void> Function()? onRecoverCredential,
    VoidCallback? onAccountAction,
    Future<void> Function()? onSignIn,
    Future<void> Function()? onSignOut,
    VoidCallback? onQuit,
    Future<void> Function()? onRetry,
    Future<void> Function()? onExportDiagnostics,
    Future<void> Function(String path)? onChangeWorkRoot,
    LocalConfiguredWorkerRegistry? localWorkerRegistry,
    SecureCredentialStore? credentialStore,
    Future<void> Function()? onAddWorker,
    bool signedIn = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostDashboard(
            snapshot: snapshot,
            onRecoverCredential: onRecoverCredential,
            onDisconnect: onDisconnect,
            onRelease: onRelease,
            onReset: onReset,
            onAccountAction: onAccountAction,
            onSignIn: onSignIn,
            onSignOut: onSignOut,
            onQuit: onQuit,
            onRetry: onRetry,
            onExportDiagnostics: onExportDiagnostics,
            onChangeWorkRoot: onChangeWorkRoot,
            localWorkerRegistry: localWorkerRegistry,
            // Build-time widget tests must never read the developer's actual
            // Keychain. Tests covering Keychain behavior provide a mocked
            // native bridge explicitly.
            credentialStore: credentialStore ?? _MemoryCredentialStore(),
            onAddWorker: onAddWorker,
            signedIn: signedIn,
          ),
        ),
      ),
    );
  }

  testWidgets('first launch uses authenticated registration instead of pairing',
      (tester) async {
    var signInStarted = false;
    var connectStarted = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Workspace is ready to connect',
        detail: 'Sign in to register this computer.',
        hostname: 'test-mac',
      ),
      credentialStore: _MemoryCredentialStore(),
      onSignIn: () async => signInStarted = true,
      onRecoverCredential: () async => connectStarted = true,
    );

    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Connect Workspace'), findsNothing);
    expect(find.text('This computer is not connected as a Workspace.'),
        findsOneWidget);
    expect(find.text('Pairing code'), findsNothing);
    expect(find.text('Connect'), findsNothing);

    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(signInStarted, isTrue);
    expect(connectStarted, isFalse,
        reason: 'Sign in must not invoke Workspace registration or startup.');
  });

  testWidgets('signed-out root shell exposes no management surfaces',
      (tester) async {
    var signInStarted = false;
    final credentials = _MemoryCredentialStore();
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const HostUiSnapshot(
          mode: HostUiMode.firstLaunch,
          title: 'Workspace is ready to connect',
          detail: 'Sign in to register this computer.',
          hostname: 'test-mac',
        ),
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (_) async => null,
        onSignIn: () async => signInStarted = true,
        onConnectWorkspace: () async {},
        onSignOut: () async {},
        onQuit: () async {},
        managementShellBuilder: () => const Text('MANAGEMENT DASHBOARD'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('About'), findsNothing); // About is in the menu.
    expect(find.text('Workspace'), findsNothing);
    expect(find.text('Workers'), findsNothing);
    expect(find.text('Work Root'), findsNothing);
    expect(find.text('Add Worker'), findsNothing);
    expect(find.text('Disconnect Workspace'), findsNothing);
    expect(find.text('Reset local Workspace'), findsNothing);
    expect(find.text('MANAGEMENT DASHBOARD'), findsNothing);
    expect(find.textContaining('v'), findsWidgets);
    expect(find.byTooltip('Quit Conclave Workspace'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(signInStarted, isTrue);
  });

  testWidgets('locked shell hides management surfaces until unlock',
      (tester) async {
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'human-session-secret',
        'sessionId': 'session-1',
        'userId': 'user-1',
        'displayName': 'Vitalii Noha',
        'email': 'vitalii@example.com',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      });
    var unlockRequested = false;
    var managementVisible = false;
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const HostUiSnapshot(
          mode: HostUiMode.active,
          title: 'Workspace connected',
          detail: 'Ready',
          paired: true,
          workspaceReady: true,
          cloudConnected: true,
          ownerUserId: 'user-1',
          hostname: 'sensitive-machine-name',
          workRootPath: '/private/work/root',
        ),
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (session) async => session,
        onSignIn: () async {},
        onConnectWorkspace: () async {},
        onSignOut: () async {},
        onQuit: () async {},
        managementLocked: true,
        onUnlock: () async => unlockRequested = true,
        managementShellBuilder: () {
          managementVisible = true;
          return const Text('MANAGEMENT DASHBOARD');
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Workspace is locked.'), findsOneWidget);
    expect(find.text('Runtime is still connected.'), findsOneWidget);
    expect(find.text('MANAGEMENT DASHBOARD'), findsNothing);
    expect(find.text('Workers'), findsNothing);
    expect(find.text('/private/work/root'), findsNothing);
    expect(find.text('sensitive-machine-name'), findsNothing);
    expect(managementVisible, isFalse);

    await tester.ensureVisible(find.text('Unlock'));
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    expect(unlockRequested, isTrue);
    expect(managementVisible, isFalse,
        reason: 'the shell itself cannot change runtime or reveal controls');
  });

  testWidgets('signed-in disconnected account exposes explicit Connect action',
      (tester) async {
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'human-session-secret',
        'sessionId': 'session-1',
        'userId': 'user-1',
        'displayName': 'Vitalii Noha',
        'email': 'vitalii@example.com',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      });
    var connectStarted = false;
    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Connect this Workspace',
        detail: 'Sign in to register this computer.',
        hostname: "Vitalii's MacBook Pro",
      ),
      credentialStore: credentials,
      onRecoverCredential: () async => connectStarted = true,
      signedIn: true,
    );
    await tester.pumpAndSettle();

    expect(find.text('Signed in as'), findsOneWidget);
    expect(find.text('Vitalii Noha'), findsOneWidget);
    expect(find.text('vitalii@example.com'), findsOneWidget);
    expect(find.text('This computer is not connected as a Workspace.'),
        findsOneWidget);
    expect(find.text('Computer\nVitalii\'s MacBook Pro'), findsOneWidget);
    expect(find.text('Connect Workspace'), findsOneWidget);
    expect(find.text('Workers'), findsWidgets);
    await tester.tap(find.text('Workers').first);
    await tester.pumpAndSettle();
    expect(find.text('Workers are unavailable'), findsOneWidget);
    expect(find.text('Add Worker'), findsNothing);
    await tester.tap(find.text('Workspace').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Workspace'));
    expect(connectStarted, isTrue);
  });

  testWidgets('disconnected owned Workspace can be explicitly released',
      (tester) async {
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'human-session-secret',
        'sessionId': 'session-1',
        'userId': 'user-1',
        'displayName': 'Vitalii Noha',
        'email': 'vitalii@example.com',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      });
    var released = false;
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const HostUiSnapshot(
          mode: HostUiMode.firstLaunch,
          title: 'Workspace disconnected',
          detail: 'This installation remains owned.',
          paired: true,
          workspaceReady: false,
          cloudConnected: false,
          ownerUserId: 'user-1',
          hostname: 'test-mac',
        ),
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (session) async => session,
        onSignIn: () async {},
        onConnectWorkspace: () async {},
        onSignOut: () async {},
        onRelease: () async => released = true,
        onQuit: () async {},
        managementShellBuilder: () => Scaffold(
          body: HostDashboard(
            snapshot: const HostUiSnapshot(
              mode: HostUiMode.firstLaunch,
              title: 'Workspace disconnected',
              detail: 'This installation remains owned.',
              paired: true,
              workspaceReady: false,
              cloudConnected: false,
              ownerUserId: 'user-1',
              hostname: 'test-mac',
            ),
            credentialStore: credentials,
            signedIn: true,
            onSignOut: () async {},
            onRecoverCredential: () async {},
            onRelease: () async => released = true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Connect Workspace'), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Workers'), findsWidgets);
    await tester.tap(find.text('Workers').first);
    await tester.pumpAndSettle();
    expect(
      find.text('Connect this computer before configuring Workers.'),
      findsOneWidget,
    );
    expect(find.text('Add Worker'), findsNothing);
    await tester.tap(find.text('Workspace').first);
    await tester.pumpAndSettle();
    expect(find.text('Connect Workspace'), findsOneWidget);
    expect(find.text('Release Workspace from account'), findsNothing);
    await tester.ensureVisible(find.text('Advanced & Diagnostics'));
    await tester.tap(find.text('Advanced & Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Release Workspace from account'), findsOneWidget);
    await tester.ensureVisible(find.text('Release Workspace from account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release Workspace from account'));
    expect(released, isTrue);
  });

  testWidgets('connected unlocked owner sees Workspace and Workers tabs',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'human-session-a',
        'sessionId': 'session-a',
        'userId': 'user-a',
        'displayName': 'User A',
        'email': 'a@example.com',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      });
    const snapshot = HostUiSnapshot(
      mode: HostUiMode.ready,
      title: 'Workspace ready',
      detail: 'Ready',
      paired: true,
      workspaceReady: true,
      cloudConnected: true,
      desiredRuntimeConnected: true,
      ownerUserId: 'user-a',
      workspaceName: 'User A Workspace',
    );

    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: snapshot,
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (session) async => session,
        onSignIn: () async {},
        onConnectWorkspace: () async {},
        onSignOut: () async {},
        onQuit: () async {},
        managementShellBuilder: () => Scaffold(
          body: HostDashboard(
            snapshot: snapshot,
            credentialStore: credentials,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Workers'), findsWidgets);
  });

  testWidgets('a different account cannot open a connected owner Workspace',
      (tester) async {
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'human-session-b',
        'sessionId': 'session-b',
        'userId': 'user-b',
        'displayName': 'User B',
        'email': 'b@example.com',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      });
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const HostUiSnapshot(
          mode: HostUiMode.ready,
          title: 'Workspace ready',
          detail: 'Ready',
          paired: true,
          workspaceReady: true,
          cloudConnected: true,
          ownerUserId: 'user-a',
          workspaceName: 'User A Workspace',
        ),
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (session) async => session,
        onSignIn: () async {},
        onConnectWorkspace: () async {},
        onSignOut: () async {},
        onQuit: () async {},
        managementShellBuilder: () => const Text('MANAGEMENT DASHBOARD'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Sign in again to manage Workspace'), findsOneWidget);
    expect(
        find.textContaining('Sign in as the Workspace owner'), findsOneWidget);
    expect(find.text('MANAGEMENT DASHBOARD'), findsNothing);
    expect(find.text('Workers'), findsNothing);
  });

  testWidgets('an expired disconnected session asks the user to sign in',
      (tester) async {
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'expired-session',
        'sessionId': 'expired-session-id',
        'userId': 'user-a',
        'displayName': 'User A',
        'email': 'a@example.com',
        'expiresAt': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      });
    var restoreAttempted = false;
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const HostUiSnapshot(
          mode: HostUiMode.firstLaunch,
          title: 'Workspace disconnected',
          detail: 'Sign-in expired.',
          paired: true,
          ownerUserId: 'user-a',
          cloudConnected: false,
          desiredRuntimeConnected: false,
        ),
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (_) async {
          restoreAttempted = true;
          return null;
        },
        onSignIn: () async {},
        onConnectWorkspace: () async {},
        onSignOut: () async {},
        onQuit: () async {},
        managementShellBuilder: () => const Text('MANAGEMENT DASHBOARD'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Sign in required'), findsOneWidget);
    expect(find.text('MANAGEMENT DASHBOARD'), findsNothing);
    expect(restoreAttempted, isFalse);
  });

  testWidgets('expired human session leaves connected runtime available',
      (tester) async {
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'expired-session',
        'sessionId': 'expired-session-id',
        'userId': 'user-a',
        'displayName': 'User A',
        'email': 'a@example.com',
        'expiresAt': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      });
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const HostUiSnapshot(
          mode: HostUiMode.ready,
          title: 'Workspace ready',
          detail: 'Runtime is connected.',
          paired: true,
          workspaceReady: true,
          ownerUserId: 'user-a',
          cloudConnected: true,
          desiredRuntimeConnected: true,
        ),
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (_) async => null,
        onSignIn: () async {},
        onConnectWorkspace: () async {},
        onSignOut: () async {},
        onQuit: () async {},
        managementShellBuilder: () => const Text('MANAGEMENT DASHBOARD'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Sign in again to manage Workspace'), findsOneWidget);
    expect(
      find.text(
          'The runtime remains connected. Sign in as the Workspace owner to manage it.'),
      findsOneWidget,
    );
    expect(find.text('MANAGEMENT DASHBOARD'), findsNothing);
  });

  testWidgets('near-expiry session rotates and persists without reconnecting',
      (tester) async {
    final current = DesktopHumanSession(
      credential: 'current-human-session',
      sessionId: 'session-a',
      userId: 'user-a',
      displayName: 'User A',
      email: 'a@example.com',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 2)),
    );
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode(current.toSecureJson());
    var runtimeRebuilt = false;
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const HostUiSnapshot(
          mode: HostUiMode.ready,
          title: 'Workspace ready',
          detail: 'Runtime is connected.',
          paired: true,
          workspaceReady: true,
          ownerUserId: 'user-a',
          cloudConnected: true,
          desiredRuntimeConnected: true,
        ),
        credentialStore: credentials,
        cloudUrl: 'https://cloud.example',
        refreshToken: 0,
        restoreSession: (_) async => DesktopHumanSession(
          credential: 'rotated-human-session',
          sessionId: 'session-a',
          userId: 'user-a',
          displayName: 'User A',
          email: 'a@example.com',
          expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
        ),
        onSignIn: () async {},
        onConnectWorkspace: () async => runtimeRebuilt = true,
        onSignOut: () async {},
        onQuit: () async {},
        managementShellBuilder: () => const Text('MANAGEMENT DASHBOARD'),
      ),
    ));
    await tester.pumpAndSettle();

    final stored = jsonDecode(credentials.values[desktopHumanCredentialKey]!)
        as Map<String, dynamic>;
    expect(stored['credential'], 'rotated-human-session');
    expect(find.text('MANAGEMENT DASHBOARD'), findsOneWidget);
    expect(runtimeRebuilt, isFalse);
  });

  testWidgets('offline Workspace displays recovery panel with retry',
      (tester) async {
    var retried = false;
    var recoveryPrepared = false;
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
      onRecoverCredential: () async => recoveryPrepared = true,
      credentialStore: _MemoryCredentialStore()
        ..values[desktopHumanCredentialKey] = jsonEncode({
          'credential': 'human-session',
          'sessionId': 'session-1',
          'userId': 'user-1',
          'displayName': 'Test User',
          'email': 'test@example.com',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        }),
    );

    expect(find.text('Network unavailable'), findsOneWidget);
    expect(find.text('Offline'), findsWidgets);
    expect(find.text('Pairing code'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
    expect(find.text('Retry connection'), findsOneWidget);
    expect(find.text('Connect Workspace'), findsOneWidget);
    expect(find.byTooltip('Copy error message'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy error message'));
    await tester.pump();
    expect(copiedText, 'Network unavailable');
    expect(find.text('Error message copied'), findsOneWidget);
    await tester.tap(find.text('Retry connection'));
    expect(retried, isTrue);
    await tester.ensureVisible(find.text('Connect Workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Workspace'));
    expect(recoveryPrepared, isTrue);
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
        detail: 'This computer is registered and ready to run assigned work.',
        paired: true,
        workspaceReady: true,
        cloudConnected: true,
        activeTransportMode: 'websocket',
        workspaceName: 'MacBook Pro',
        workspaceId: 'ws-123',
        hostId: 'host-a',
        workRootPath: '/Users/test/Work',
        logsPath: '/tmp/host.log',
        updateSummary: 'Up to date',
      ),
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

    // Lifecycle sections are visible without opening diagnostics.
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Connected · WebSocket'), findsOneWidget);
    expect(find.text('Startup'), findsOneWidget);
    expect(find.text('Current work'), findsOneWidget);
    expect(find.text('Workers'), findsWidgets);
    expect(find.text('View Workers'), findsNothing);
    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('Application'), findsNothing);
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
        workspaceReady: true,
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
    var retried = false;
    String? copiedConnectionDetails;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedConnectionDetails = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        paired: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceId: 'ws-test-123',
        hostId: 'runtime-host-a',
        cloudUrl:
            'wss://app.conclaveax.com/api/workspace-gateway/connect?workspaceRuntimeId=runtime-host-a',
        logsPath: '/var/logs/host.log',
        connectionStage: HostConnectionStage.offline,
        connectionError: 'Cloud rejected the WebSocket upgrade with HTTP 400.',
        connectionHttpStatus: 400,
        runtimeCredentialAvailable: true,
        protocolHelloStatus: 'not started',
        dnsTlsStatus: 'passed',
        webSocketUpgradeStatus: 'failed (HTTP 400)',
      ),
      onExportDiagnostics: () async => exported = true,
      onRetry: () async => retried = true,
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
    expect(find.text('Connection stage'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
    expect(find.text('DNS / TLS'), findsOneWidget);
    expect(find.text('passed'), findsOneWidget);
    expect(find.text('WebSocket upgrade'), findsOneWidget);
    expect(find.text('Protocol hello'), findsOneWidget);
    expect(find.text('not started'), findsOneWidget);
    expect(find.text('failed (HTTP 400)'), findsOneWidget);
    expect(find.text('Runtime credential'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);
    expect(find.text('Open Log File'), findsOneWidget);

    final exportBtn = find.text('Export Report');
    await tester.ensureVisible(exportBtn);
    await tester.pumpAndSettle();
    expect(exportBtn, findsOneWidget);
    await tester.tap(exportBtn);
    expect(exported, isTrue);

    final copyButton = find.text('Copy connection details');
    await tester.ensureVisible(copyButton);
    await tester.pumpAndSettle();
    await tester.tap(copyButton);
    expect(copiedConnectionDetails, contains('HTTP 400'));
    expect(copiedConnectionDetails, isNot(contains('Bearer')));

    final retryButton = find.text('Retry connection');
    await tester.ensureVisible(retryButton);
    await tester.pumpAndSettle();
    await tester.tap(retryButton);
    expect(retried, isTrue);
  });

  testWidgets('workspace tab separates status from advanced lifecycle actions',
      (tester) async {
    var disconnected = false;
    var signedOut = false;
    var released = false;
    var reset = false;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final credentials = _MemoryCredentialStore()
      ..values[desktopHumanCredentialKey] = jsonEncode({
        'credential': 'human-session-secret',
        'sessionId': 'session-1',
        'userId': 'user-1',
        'displayName': 'Test User',
        'email': 'test@example.com',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      });

    await pumpDashboard(
      tester,
      const HostUiSnapshot(
        mode: HostUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        paired: true,
        workspaceReady: true,
        cloudConnected: true,
        activeTransportMode: 'websocket',
        workspaceName: 'Office Mac',
        workspaceId: 'ws-456',
        hostId: 'host-456',
        cloudUrl: 'https://app.conclaveax.com',
        workRootPath: '/workspace/root',
      ),
      onDisconnect: () => disconnected = true,
      onSignOut: () async => signedOut = true,
      onRelease: () async => released = true,
      onReset: () => reset = true,
      credentialStore: credentials,
    );

    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('/workspace/root'), findsOneWidget);
    expect(find.text('Disconnect Workspace'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    await tester.ensureVisible(find.text('Disconnect Workspace'));
    await tester.tap(find.text('Disconnect Workspace'));
    expect(disconnected, isTrue);
    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    expect(signedOut, isTrue);
    await tester.tap(find.text('Advanced & Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Workspace management'), findsOneWidget);

    final releaseButton = find.text('Release Workspace from account');
    await tester.ensureVisible(releaseButton);
    await tester.pumpAndSettle();
    expect(releaseButton, findsOneWidget);
    await tester.tap(releaseButton);
    expect(released, isTrue);

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
        workspaceReady: true,
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

  testWidgets('workers surface stays hidden until Workspace is Ready',
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
        title: 'Connect this Workspace',
        detail: 'Sign in to register this computer.',
        paired: false,
        hostname: 'test-mac',
      ),
      localWorkerRegistry: registry,
      credentialStore: credentials,
      onAddWorker: () async => addWorkerCalled = true,
    );

    expect(find.text('Workers'), findsNothing);
    expect(
        find.text(
            'Local AI models and execution adapters running on this machine.'),
        findsNothing);
    expect(find.text('Configured Workers'), findsNothing);
    expect(find.text('Add Worker'), findsNothing);
    expect(addWorkerCalled, isFalse);
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
        workspaceReady: true,
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
        workspaceReady: true,
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

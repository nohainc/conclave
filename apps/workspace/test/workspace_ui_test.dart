import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/local_worker_registry.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/desktop_auth.dart';
import 'package:conclave_workspace/main.dart';
import 'package:conclave_workspace/platform_runtime.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/tool_profile_catalog.dart';
import 'package:conclave_workspace/tool_profile_release_store.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/worker_catalog_coordinator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ed25519_release_fixture.dart';
import 'support/logical_worker_catalog_fixture.dart';

Future<void> _installTestToolProfile({
  required ToolProfileReleaseStore store,
  required Ed25519ReleaseFixture signing,
  required String workerTypeId,
  required String profileDefinitionId,
  required String toolName,
  int version = 1,
}) async {
  final baseFile =
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json');
  final baseContent = baseFile.existsSync()
      ? baseFile.readAsStringSync()
      : File('packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync();
  final profile = jsonDecode(baseContent) as Map<String, Object?>;
  profile['profileDefinitionId'] = profileDefinitionId;
  profile['logicalWorkerTypeId'] = workerTypeId;
  profile['releaseVersion'] = version;
  (profile['providerTool']! as Map<String, Object?>)['name'] = toolName;
  (profile['providerTool']! as Map<String, Object?>)['supportedVersions'] = [
    {'min': '0.0.0', 'maxExclusive': '99.0.0'},
  ];

  final release = <String, Object?>{
    'profileDefinitionId': profileDefinitionId,
    'workerTypeId': workerTypeId,
    'displayName': '$workerTypeId Test Profile',
    'providerToolName': toolName,
    'channel': 'stable',
    'releaseVersion': version,
    'profile': profile,
    'schemaVersion': profile['schemaVersion'],
    'engineFamily': profile['engineFamily'],
    'engineCompatibility': profile['engineCompatibility'],
  };
  await signing.signToolProfileRelease(release);
  await store.installRelease(
    releaseInput: release,
    expectedWorkerTypeId: workerTypeId,
  );
  await store.activateVersion(profileDefinitionId, version,
      selectAsStable: true);
}

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

class _FakeWorkerRegistry extends LocalWorkerRegistry {
  _FakeWorkerRegistry(this.workers)
      : super(
          dataDirectory: Directory('/tmp'),
          workspaceId: 'ws-fake',
          platform: _TestPlatformRuntime(),
        );

  final List<LocalWorker> workers;

  @override
  Future<List<LocalWorker>> list({bool includeRemoved = false}) async => workers
      .where((w) => includeRemoved || w.status != LocalWorkerStatus.removed)
      .toList();

  @override
  Future<LocalWorker> update(
      String id, LocalWorker Function(LocalWorker current) updater) async {
    final idx = workers.indexWhere((w) => w.id == id);
    if (idx != -1) {
      workers[idx] = updater(workers[idx]);
      return workers[idx];
    }
    throw StateError('Worker not found');
  }
}

LocalWorker _disabledChatGptWorker({
  required WorkerReadinessState readinessState,
}) =>
    LocalWorker(
      id: 'w-chatgpt-disabled',
      workspaceId: 'ws-test',
      workerTypeId: 'chatgpt',
      localPermissions: const ['repository:read', 'shell:execute'],
      localConcurrencyLimit: 1,
      status: LocalWorkerStatus.disabled,
      readinessState: readinessState,
      revision: 1,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    );

void main() {
  Future<void> waitForCatalogRefresh(WidgetTester tester) async {
    final dashboard = tester.widget<WorkspaceDashboard>(
      find.byType(WorkspaceDashboard),
    );
    final controller = dashboard.workerCatalogCoordinator;
    if (controller != null) {
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (controller.snapshot.refreshing &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
    }
    await tester.pumpAndSettle();
  }

  Future<void> openWorkers(WidgetTester tester) async {
    await tester.tap(find.text('Workers').first);
    await tester.pump();
    await waitForCatalogRefresh(tester);
  }

  testWidgets('Workspace error notification has a working copy action',
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

    const error = 'Could not register Workspace: Cloud unavailable';
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

  testWidgets('launch-at-login uses the native desktop API only when supported',
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

    if (Platform.isMacOS) {
      await WorkspaceLifecycleController.setLaunchAtLogin(true);
      expect(methods.single.method, 'setLaunchAtLogin');
      expect(methods.single.arguments, isTrue);
    } else {
      await expectLater(
        WorkspaceLifecycleController.setLaunchAtLogin(true),
        throwsUnsupportedError,
      );
      expect(methods, isEmpty);
    }
  });

  Future<void> pumpDashboard(
    WidgetTester tester,
    WorkspaceUiSnapshot snapshot, {
    Future<void> Function()? onConnect,
    Future<void> Function([String? name])? onRegister,
    VoidCallback? onDisconnect,
    Future<void> Function()? onRelease,
    VoidCallback? onReset,
    Future<void> Function([String? name])? onRecoverCredential,
    VoidCallback? onAccountAction,
    Future<void> Function()? onSignIn,
    Future<void> Function()? onSignOut,
    VoidCallback? onQuit,
    Future<void> Function()? onRetry,
    Future<void> Function()? onExportDiagnostics,
    Future<void> Function(String path)? onChangeWorkRoot,
    LocalWorkerRegistry? localWorkerRegistry,
    Future<void> Function({LocalWorkerProbeMode mode, String? workerTypeId})?
        onReadinessCheck,
    SecureCredentialStore? credentialStore,
    ToolProfileCatalogClient? toolProfileCatalog,
    bool signedIn = false,
  }) async {
    final profileDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('workspace-ui-catalog-'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => profileDirectory.delete(recursive: true)),
    );
    final signing = await tester.runAsync(Ed25519ReleaseFixture.create);
    final trustPolicy = signing!.trustPolicy;
    final store = ToolProfileReleaseStore(
      profilesRoot: profileDirectory,
      trustPolicy: trustPolicy,
    );
    final catalog = toolProfileCatalog ??
        ToolProfileCatalogClient(
          cloudUri: Uri.parse('https://catalog.test'),
          store: store,
          trustPolicy: trustPolicy,
          trustRefresher: () => SynchronousFuture<void>(null),
          listLoader: (workerTypeId, channel) => Future.error(
            StateError('No Profile release fixture for $workerTypeId'),
          ),
          workerCatalogLoader: () => SynchronousFuture([
            logicalWorkerCatalogFixture('chatgpt').toJson(),
            logicalWorkerCatalogFixture('gemini').toJson(),
          ]),
        );
    if (toolProfileCatalog == null) {
      await tester.runAsync(() async {
        await _installTestToolProfile(
          store: store,
          signing: signing,
          workerTypeId: 'chatgpt',
          profileDefinitionId: 'chatgpt-codex',
          toolName: 'codex',
        );
        await _installTestToolProfile(
          store: store,
          signing: signing,
          workerTypeId: 'gemini',
          profileDefinitionId: 'gemini-antigravity',
          toolName: 'agy',
        );
        await catalog.syncCatalog();
      });
    }
    addTearDown(catalog.close);
    final catalogCoordinator = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
      registry: localWorkerRegistry,
      refreshExecutor: (operation) => Zone.root.run(operation),
    );
    addTearDown(catalogCoordinator.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceDashboard(
            snapshot: snapshot,
            onConnect: onConnect,
            onRegister: onRegister,
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
            onReadinessCheck: onReadinessCheck,
            localWorkerRegistry: localWorkerRegistry,
            workerCatalogCoordinator: catalogCoordinator,
            // Build-time widget tests must never read the developer's actual
            // Keychain. Tests covering Keychain behavior provide a mocked
            // native bridge explicitly.
            credentialStore: credentialStore ?? _MemoryCredentialStore(),
            signedIn: signedIn,
          ),
        ),
      ),
    );
  }

  testWidgets('first launch uses authenticated desktop registration',
      (tester) async {
    var signInStarted = false;
    final credentials = _MemoryCredentialStore();
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.firstLaunch,
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
    expect(find.text('Connect Workspace'), findsNothing);
    expect(find.text('Connect'), findsNothing);

    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(signInStarted, isTrue);
  });

  testWidgets('signed-out root shell exposes no management surfaces',
      (tester) async {
    var signInStarted = false;
    final credentials = _MemoryCredentialStore();
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.firstLaunch,
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
    expect(find.byTooltip('Quit Conclave Workspace'), findsNothing);
    expect(find.byIcon(Icons.menu), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(signInStarted, isTrue);
  });

  testWidgets('signed-in session routes directly to management shell',
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
    var managementVisible = false;
    await tester.pumpWidget(MaterialApp(
      home: WorkspaceShellRouter(
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.active,
          title: 'Workspace connected',
          detail: 'Ready',
          registered: true,
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
        managementShellBuilder: () {
          managementVisible = true;
          return const Text('MANAGEMENT DASHBOARD');
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('MANAGEMENT DASHBOARD'), findsOneWidget);
    expect(managementVisible, isTrue);
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
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.firstLaunch,
        title: 'Connect this Workspace',
        detail: 'Sign in to register this computer.',
        hostname: "Vitalii's MacBook Pro",
      ),
      credentialStore: credentials,
      onRecoverCredential: ([name]) async => connectStarted = true,
      signedIn: true,
    );
    await tester.pumpAndSettle();

    expect(find.text('vitalii@example.com'), findsOneWidget);
    expect(find.text('Register'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Workers'), findsWidgets);
    await openWorkers(tester);
    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
    await tester.tap(find.text('Workspace').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Register'));
    expect(connectStarted, isTrue);
  });

  testWidgets('disconnected owned Workspace can be explicitly released',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.firstLaunch,
          title: 'Workspace disconnected',
          detail: 'This installation remains owned.',
          registered: true,
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
          body: WorkspaceDashboard(
            snapshot: const WorkspaceUiSnapshot(
              mode: WorkspaceUiMode.firstLaunch,
              title: 'Workspace disconnected',
              detail: 'This installation remains owned.',
              registered: true,
              workspaceReady: false,
              cloudConnected: false,
              ownerUserId: 'user-1',
              hostname: 'test-mac',
            ),
            credentialStore: credentials,
            signedIn: true,
            onSignOut: () async {},
            onRecoverCredential: ([name]) async {},
            onRelease: () async => released = true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Workers'), findsWidgets);
    await openWorkers(tester);
    await tester.tap(find.text('Workspace').first);
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Release'), findsOneWidget);
    await tester.ensureVisible(find.text('Release'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release'));
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
    const snapshot = WorkspaceUiSnapshot(
      mode: WorkspaceUiMode.ready,
      title: 'Workspace ready',
      detail: 'Ready',
      registered: true,
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
          body: WorkspaceDashboard(
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
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.ready,
          title: 'Workspace ready',
          detail: 'Ready',
          registered: true,
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
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.firstLaunch,
          title: 'Workspace disconnected',
          detail: 'Sign-in expired.',
          registered: true,
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
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.ready,
          title: 'Workspace ready',
          detail: 'Runtime is connected.',
          registered: true,
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
        snapshot: const WorkspaceUiSnapshot(
          mode: WorkspaceUiMode.ready,
          title: 'Workspace ready',
          detail: 'Runtime is connected.',
          registered: true,
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
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.offline,
        desiredRuntimeConnected: true,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect.',
        issue: 'Network unavailable',
        registered: true,
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'runtime-1',
        workspaceName: 'Development Mac',
      ),
      onRetry: () async => retried = true,
      onRecoverCredential: ([name]) async => recoveryPrepared = true,
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
    expect(find.text('Retry connection'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.byTooltip('Copy error message'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy error message'));
    await tester.pump();
    expect(copiedText, 'Network unavailable');
    expect(find.text('Error message copied'), findsOneWidget);
    await tester.tap(find.text('Retry connection'));
    expect(retried, isTrue);
    await tester.ensureVisible(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    expect(recoveryPrepared, isTrue);
  });

  testWidgets(
      'registered Workspace defaults to Workspace tab with two-surface tabs and zero duplicate cards',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'This computer is registered and ready to run assigned work.',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        activeTransportMode: 'websocket',
        workspaceName: 'MacBook Pro',
        workspaceId: 'ws-123',
        workspaceRuntimeId: 'workspace-a',
        workRootPath: '/Users/test/Work',
        logsPath: '/tmp/workspace.log',
        updateSummary: 'Up to date',
      ),
    );

    // Only Workspace and Workers tabs exist in top navigation
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('Workers'), findsWidgets);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Workspace management'), findsNothing);

    // Header actions: 3-lines menu icon, no duplicate button in header
    expect(find.byIcon(Icons.menu), findsOneWidget);

    // Lifecycle sections are visible without opening diagnostics.
    expect(find.text('Workspace'), findsWidgets);
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Connection'), findsNothing);
    expect(find.text('Connected · WebSocket'), findsOneWidget);
    expect(find.text('Start at login'), findsOneWidget);
    expect(find.text('Startup'), findsNothing);
    expect(find.text('Current work'), findsNothing);
    expect(find.text('Workers'), findsWidgets);
    expect(find.text('View Workers'), findsNothing);
    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('Application'), findsNothing);
    expect(find.text('Advanced Diagnostics'), findsOneWidget);

    // The registered Workspace has no enrollment form.
    expect(find.text('Connect this Workspace'), findsNothing);
    expect(find.text('Connect'), findsNothing);

    // Removed sections are not on the Workspace tab
    expect(find.text('Current Work'), findsNothing);
    expect(find.text('View Workers'), findsNothing);
    expect(find.bySemanticsLabel('Workspace status'), findsNothing);
  });

  testWidgets('header overflow menu provides AX, updates, and about',
      (tester) async {
    var retryCalled = false;

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        statusLabel: 'Connected',
        hostname: 'MacBook Pro',
      ),
      onRetry: () async => retryCalled = true,
    );

    expect(find.text('Conclave Workspace'), findsOneWidget);
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);

    // Verify HUD Quit icon button is not shown
    expect(find.byTooltip('Quit Conclave Workspace'), findsNothing);

    // Open overflow menu (3 lines icon)
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Open Conclave AX'), findsOneWidget);
    expect(find.text('Check for Updates'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

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
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.installFailure,
        desiredRuntimeConnected: true,
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
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceId: 'ws-test-123',
        workspaceRuntimeId: 'runtime-workspace-a',
        cloudUrl:
            'wss://app.conclaveax.com/api/workspace-gateway/connect?workspaceRuntimeId=runtime-workspace-a',
        logsPath: '/var/logs/workspace.log',
        connectionStage: WorkspaceConnectionStage.offline,
        connectionError: 'Cloud rejected the WebSocket upgrade with HTTP 400.',
        connectionHttpStatus: 400,
        runtimeCredentialAvailable: true,
        protocolHelloStatus: 'not started',
        dnsTlsStatus: 'passed',
        webSocketUpgradeStatus: 'failed (HTTP 400)',
      ),
      onExportDiagnostics: () async => exported = true,
    );

    expect(find.text('Advanced Diagnostics'), findsOneWidget);

    // Before expanding, internal section headers and IDs are collapsed / not shown
    expect(find.text('Runtime ID'), findsNothing);

    await tester.ensureVisible(find.text('Advanced Diagnostics'));
    await tester.tap(find.text('Advanced Diagnostics'));
    await tester.pumpAndSettle();

    // After expanding, details are exposed
    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Workspace ID'), findsOneWidget);
    expect(find.text('ws-test-123'), findsOneWidget);
    expect(find.text('Runtime ID'), findsOneWidget);
    expect(find.text('runtime-workspace-a'), findsOneWidget);
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

    // Diagnostics section does not show Retry connection button
    expect(find.text('Retry connection'), findsNothing);
  });

  test('runtime credential diagnostics reflect desired runtime state', () {
    const disconnected = WorkspaceUiSnapshot(
      mode: WorkspaceUiMode.firstLaunch,
      title: 'Connect this Workspace',
      detail: 'Sign in first.',
    );
    const connectedWithoutCredential = WorkspaceUiSnapshot(
      mode: WorkspaceUiMode.offline,
      title: 'Workspace is offline',
      detail: 'Runtime connection needs attention.',
      desiredRuntimeConnected: true,
    );

    expect(disconnected.runtimeCredentialStatus,
        'Not needed while Workspace is disconnected');
    expect(connectedWithoutCredential.runtimeCredentialStatus,
        'Missing from secure storage');
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
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        activeTransportMode: 'websocket',
        workspaceName: 'Office Mac',
        workspaceId: 'ws-456',
        workspaceRuntimeId: 'workspace-456',
        cloudUrl: 'https://app.conclaveax.com',
        workRootPath: '/workspace/root',
      ),
      onDisconnect: () => disconnected = true,
      onSignOut: () async => signedOut = true,
      onRelease: () async => released = true,
      onReset: () => reset = true,
      credentialStore: credentials,
    );

    expect(find.text('test@example.com'), findsOneWidget);
    expect(find.text('Work Root'), findsOneWidget);
    expect(find.text('/workspace/root'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    await tester.ensureVisible(find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    expect(disconnected, isTrue);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(signedOut, isTrue);

    final releaseButton = find.text('Release');
    await tester.ensureVisible(releaseButton);
    await tester.pumpAndSettle();
    expect(releaseButton, findsOneWidget);
    await tester.tap(releaseButton);
    expect(released, isTrue);

    final resetBtn = find.text('Reset');
    await tester.ensureVisible(resetBtn);
    await tester.pumpAndSettle();
    expect(resetBtn, findsOneWidget);
    await tester.tap(resetBtn);
    expect(reset, isTrue);
  });

  testWidgets(
      'workspace tab renders read-only work root field with browse button and no open folder button',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
        workRootPath: '/custom/work/root',
      ),
    );

    // Verify read-only TextField and title
    expect(find.text('Work Root'), findsOneWidget);
    final workRootTextFieldFinder =
        find.widgetWithText(TextField, '/custom/work/root');
    expect(workRootTextFieldFinder, findsOneWidget);
    final textField = tester.widget<TextField>(workRootTextFieldFinder);
    expect(textField.readOnly, isTrue);

    // Verify Browse button
    expect(find.text('Browse'), findsOneWidget);

    // Verify Open folder button is deleted
    final openFolderBtn = find.widgetWithText(FilledButton, 'Open folder');
    expect(openFolderBtn, findsNothing);
  });

  testWidgets('Workers catalog stays hidden until Workspace is Ready',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Connect this Workspace',
        detail: 'Sign in to register this computer.',
        registered: false,
        hostname: 'test-mac',
      ),
      localWorkerRegistry: _FakeWorkerRegistry([]),
    );

    expect(find.text('Workers'), findsNothing);
    expect(find.text('ChatGPT'), findsNothing);
    expect(find.text('Gemini'), findsNothing);
    expect(find.text('Add Worker'), findsNothing);
  });

  testWidgets('Workers page renders each Cloud catalog entry', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
      ),
      localWorkerRegistry: _FakeWorkerRegistry([]),
    );
    await openWorkers(tester);
    await tester.ensureVisible(find.byKey(const Key('worker-catalog-chatgpt')));
    await tester.pumpAndSettle();

    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
    expect(find.text('Setup required'), findsNWidgets(2));
    expect(find.text('codex · Unknown'), findsOneWidget);
    expect(find.text('agy · Unknown'), findsOneWidget);
    expect(find.textContaining('Capabilities:'), findsNothing);
    expect(find.text('Diagnostics'), findsNWidgets(2));
    expect(find.text('Set up ChatGPT'), findsNothing);
    expect(find.text('Set up Gemini'), findsNothing);
    expect(find.text('Save Worker'), findsNothing);
    expect(find.text('Save readiness'), findsNothing);
    expect(find.text('Readiness'), findsNothing);
    expect(find.text('Add Worker'), findsNothing);
    expect(find.text('No local Workers configured'), findsNothing);
    expect(find.byKey(const Key('worker-type-selector')), findsNothing);
    expect(find.text('Configure'), findsNWidgets(2));
  });

  testWidgets(
      'Workers page displays catalog Workers independently of local Profiles',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final profileDirectory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('workspace-ui-dynamic-workers-'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => profileDirectory.delete(recursive: true)),
    );
    final signing = await tester.runAsync(Ed25519ReleaseFixture.create);
    final trustPolicy = signing!.trustPolicy;
    final store = ToolProfileReleaseStore(
      profilesRoot: profileDirectory,
      trustPolicy: trustPolicy,
    );
    var workerCatalogLoads = 0;
    final catalog = ToolProfileCatalogClient(
      cloudUri: Uri.parse('https://catalog.test'),
      store: store,
      trustPolicy: trustPolicy,
      trustRefresher: () => SynchronousFuture<void>(null),
      listLoader: (workerTypeId, channel) => Future.error(
        StateError('No Profile release fixture for $workerTypeId'),
      ),
      workerCatalogLoader: () {
        workerCatalogLoads++;
        return SynchronousFuture([
          logicalWorkerCatalogFixture('chatgpt').toJson(),
          logicalWorkerCatalogFixture('gemini').toJson(),
          logicalWorkerCatalogFixture(
            'dynamic-test-worker',
            displayName: 'Dynamic Test Worker',
            profileDefinitionId: 'dynamic-test-cli',
            providerToolName: 'Fixture CLI',
          ).toJson(),
        ]);
      },
    );
    // Install profile only for Gemini; the other catalog entries stay visible.
    await tester.runAsync(() async {
      await _installTestToolProfile(
        store: store,
        signing: signing,
        workerTypeId: 'gemini',
        profileDefinitionId: 'gemini-antigravity',
        toolName: 'agy',
      );
      await catalog.syncCatalog();
    });
    workerCatalogLoads = 0;
    addTearDown(catalog.close);
    final registry = _FakeWorkerRegistry([]);
    final catalogCoordinator = WorkerCatalogCoordinator(
      catalog: catalog,
      releaseStore: store,
      registry: registry,
      refreshExecutor: (operation) => Zone.root.run(operation),
    );
    addTearDown(catalogCoordinator.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceDashboard(
            snapshot: const WorkspaceUiSnapshot(
              mode: WorkspaceUiMode.ready,
              title: 'Workspace is ready',
              detail: 'Ready',
              registered: true,
              workspaceReady: true,
              cloudConnected: true,
              workspaceName: 'Office Mac',
            ),
            localWorkerRegistry: registry,
            workerCatalogCoordinator: catalogCoordinator,
            credentialStore: _MemoryCredentialStore(),
          ),
        ),
      ),
    );
    expect(workerCatalogLoads, 0);
    await openWorkers(tester);
    expect(workerCatalogLoads, 1);

    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
    expect(find.text('Dynamic Test Worker'), findsOneWidget);
    expect(find.text('Setup required'), findsNWidgets(3));
    expect(find.text('Diagnostics'), findsNWidgets(3));
    final refreshButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh),
    );
    expect(refreshButton.onPressed, isNotNull);
  });

  testWidgets('fixed catalog rows merge local Worker status by type',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chatGptWorker = LocalWorker(
      id: 'w-chatgpt',
      workspaceId: 'ws-test',
      workerTypeId: 'chatgpt',
      localPermissions: const ['repository:read', 'shell:execute'],
      localConcurrencyLimit: 1,
      status: LocalWorkerStatus.disabled,
      readinessState: WorkerReadinessState.runtimeUnavailable,
      revision: 1,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      lastLiveTestAt: '2026-01-02T03:04:05Z',
      lastLiveTestPassed: false,
      lastLiveTestIssueCode: 'package_unavailable',
      toolVersion: '1.2.3',
      toolName: 'Codex CLI',
      toolPath: '/Users/test/.local/bin/codex',
      lastLiveTestDetails:
          'Test failed (execution_test_failed)\nThe local check did not complete.',
    );
    final geminiWorker = LocalWorker(
      id: 'w-gemini',
      workspaceId: 'ws-test',
      workerTypeId: 'gemini',
      localPermissions: const ['repository:read', 'shell:execute'],
      localConcurrencyLimit: 1,
      status: LocalWorkerStatus.needsAttention,
      readinessState: WorkerReadinessState.setupRequired,
      revision: 1,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      readinessIssueCode: 'setup_required',
    );

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
      ),
      localWorkerRegistry: _FakeWorkerRegistry([chatGptWorker, geminiWorker]),
    );
    await openWorkers(tester);
    await tester.ensureVisible(find.byKey(const Key('worker-catalog-chatgpt')));
    await tester.pumpAndSettle();

    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
    final disabledChatGptCard = find.byKey(const Key('worker-catalog-chatgpt'));
    expect(
      find.descendant(
        of: disabledChatGptCard,
        matching: find.text('Disabled'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: disabledChatGptCard,
        matching: find.text('Needs attention'),
      ),
      findsOneWidget,
    );
    expect(find.text('Setup required'), findsOneWidget);
    expect(find.text('Codex CLI · 1.2.3'), findsOneWidget);
    expect(find.text('agy · Not detected'), findsOneWidget);
    expect(find.text('Test'), findsNWidgets(2));
    expect(find.textContaining('Test failed (execution_test_failed)'),
        findsNothing);
    expect(find.byTooltip('Copy test details'), findsNothing);
    expect(find.textContaining('Issue code:'), findsNothing);
    expect(find.textContaining('Worker Package ·'), findsNothing);
    expect(find.textContaining('Adapter unavailable'), findsNothing);
    expect(find.textContaining('Adapter version'), findsNothing);
    expect(find.textContaining('Signature'), findsNothing);
    expect(find.textContaining('Release channel'), findsNothing);
    expect(find.text('Diagnostics'), findsNWidgets(2));
    expect(find.text('Save readiness'), findsNothing);
    expect(find.text('Authentication'), findsNothing);
    expect(
        find.text('Check again').evaluate().length +
            find.byType(Switch).evaluate().length,
        2);
    expect(find.text('Configure'), findsNothing);
    expect(find.textContaining('ChatGPT local'), findsNothing);
    expect(find.text('Default Model'), findsNothing);
    expect(find.text('Allowed Models'), findsNothing);
    expect(find.text('Permissions'), findsNothing);

    await tester.tap(find.text('Workspace').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Advanced Diagnostics'));
    await tester.tap(find.text('Advanced Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Engine & Tool Profiles'), findsNothing);

    await openWorkers(tester);
    await tester.ensureVisible(find.text('Diagnostics').first);
    await tester.tap(find.text('Diagnostics').first);
    await tester.pumpAndSettle();
    expect(find.text('Engine version'), findsOneWidget);
    expect(find.text('1.0.0'), findsWidgets);
    expect(find.text('Provider CLI'), findsOneWidget);
    expect(find.text('Provider CLI version'), findsOneWidget);
    expect(find.text('Codex CLI'), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.textContaining('Worker version'), findsNothing);
    expect(find.textContaining('Signing key'), findsNothing);
    expect(find.textContaining('Release channel'), findsNothing);
  });

  testWidgets('testing a disabled Worker preserves activation', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final worker = _disabledChatGptWorker(
      readinessState: WorkerReadinessState.setupRequired,
    );
    final registry = _FakeWorkerRegistry([worker]);
    LocalWorkerActivationState? activationAtProbe;

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
      ),
      localWorkerRegistry: registry,
      onReadinessCheck: ({
        LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
        String? workerTypeId,
      }) async {
        expect(mode, LocalWorkerProbeMode.live);
        activationAtProbe = registry.workers.single.activationState;
        await registry.update(
          worker.id,
          (current) => current.copyWith(
            lastLiveTestAt: '2026-01-02T03:04:05Z',
            lastLiveTestPassed: true,
          ),
        );
      },
    );
    await openWorkers(tester);
    final chatGptCard = find.byKey(const Key('worker-catalog-chatgpt'));
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Disabled')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Setup required')),
      findsOneWidget,
    );
    await tester.tap(find.text('Test').first);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();

    expect(activationAtProbe, LocalWorkerActivationState.disabled);
    expect(registry.workers.single.activationState,
        LocalWorkerActivationState.disabled);
    expect(registry.workers.single.lastLiveTestPassed, isTrue);
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Disabled')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Ready')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Setup required')),
      findsNothing,
    );
  });

  testWidgets('a failed live Test keeps Disabled and shows Needs attention',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final worker = _disabledChatGptWorker(
      readinessState: WorkerReadinessState.ready,
    );
    final registry = _FakeWorkerRegistry([worker]);
    LocalWorkerActivationState? activationAtProbe;

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
      ),
      localWorkerRegistry: registry,
      onReadinessCheck: ({
        LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
        String? workerTypeId,
      }) async {
        expect(mode, LocalWorkerProbeMode.live);
        activationAtProbe = registry.workers.single.activationState;
        await registry.update(
          worker.id,
          (current) => current.copyWith(
            lastLiveTestAt: '2026-01-02T03:04:05Z',
            lastLiveTestPassed: false,
            lastLiveTestIssueCode: 'execution_test_failed',
          ),
        );
      },
    );
    await openWorkers(tester);
    final chatGptCard = find.byKey(const Key('worker-catalog-chatgpt'));
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Disabled')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Ready')),
      findsOneWidget,
    );
    await tester.tap(find.text('Test').first);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();

    expect(activationAtProbe, LocalWorkerActivationState.disabled);
    expect(registry.workers.single.activationState,
        LocalWorkerActivationState.disabled);
    expect(registry.workers.single.lastLiveTestPassed, isFalse);
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Disabled')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chatGptCard, matching: find.text('Needs attention')),
      findsOneWidget,
    );
  });

  testWidgets('activation switch never requests a live Worker test',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final worker = LocalWorker(
      id: 'w-chatgpt-toggle',
      workspaceId: 'ws-test',
      workerTypeId: 'chatgpt',
      localPermissions: const ['repository:read', 'shell:execute'],
      localConcurrencyLimit: 1,
      status: LocalWorkerStatus.ready,
      readinessState: WorkerReadinessState.ready,
      revision: 1,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    );
    final registry = _FakeWorkerRegistry([worker]);
    final probeModes = <LocalWorkerProbeMode>[];

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
      ),
      localWorkerRegistry: registry,
      onReadinessCheck: ({
        LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
        String? workerTypeId,
      }) async {
        probeModes.add(mode);
      },
    );
    await openWorkers(tester);

    await tester.tap(find.byType(Switch).first); // Disable.
    await tester.pumpAndSettle();
    expect(registry.workers.single.activationState,
        LocalWorkerActivationState.disabled);
    expect(probeModes, isEmpty);

    await tester.tap(find.byType(Switch).first); // Enable.
    await tester.pumpAndSettle();
    expect(registry.workers.single.activationState,
        LocalWorkerActivationState.enabled);
    expect(probeModes, [LocalWorkerProbeMode.passive]);
    expect(registry.workers.single.lastLiveTestAt, isNull);
  });

  testWidgets('unrecognized Worker types are absent from the catalog',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final unknownWorker = LocalWorker(
      id: 'w-unknown',
      workspaceId: 'ws-test',
      workerTypeId: 'internal-tool',
      localPermissions: const ['repository:read'],
      localConcurrencyLimit: 1,
      status: LocalWorkerStatus.ready,
      revision: 1,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    );
    final registry = _FakeWorkerRegistry([unknownWorker]);

    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Office Mac',
      ),
      localWorkerRegistry: registry,
    );
    await openWorkers(tester);

    expect(find.text('ChatGPT'), findsOneWidget);
    expect(find.text('Gemini'), findsOneWidget);
    expect(find.text('internal-tool'), findsOneWidget);
    expect(find.text('Catalog retired'), findsOneWidget);
    expect((await registry.list()).single.id, unknownWorker.id);
  });

  group('deriveLocalWorkerHealth', () {
    LocalWorker makeWorker({
      LocalWorkerStatus status = LocalWorkerStatus.ready,
      WorkerReadinessState readinessState = WorkerReadinessState.ready,
      List<String> permissions = const ['repository:read'],
      String? readinessIssueCode,
    }) {
      return LocalWorker(
        id: 'worker-1',
        workspaceId: 'ws-1',
        workerTypeId: 'chatgpt',
        localPermissions: permissions,
        localConcurrencyLimit: 2,
        status: status,
        readinessState: readinessState,
        readinessIssueCode: readinessIssueCode,
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
      final worker = makeWorker(
        status: LocalWorkerStatus.disabled,
        readinessState: WorkerReadinessState.ready,
      );
      expect(deriveLocalWorkerHealth(worker), 'Disabled');
      expect(worker.readinessState, WorkerReadinessState.ready);
    });

    test('readiness calculation does not use compatibility status', () {
      final worker = makeWorker(
        status: LocalWorkerStatus.disabled,
        readinessState: WorkerReadinessState.ready,
      ).copyWith(activationState: LocalWorkerActivationState.enabled);

      expect(deriveLocalWorkerHealth(worker), 'Ready');
    });

    test('readiness remains visible as its own dimension while disabled', () {
      final worker = makeWorker(
        status: LocalWorkerStatus.disabled,
        readinessState: WorkerReadinessState.setupRequired,
      );

      expect(deriveLocalWorkerReadiness(worker), 'Setup required');
      expect(deriveLocalWorkerHealth(worker), 'Disabled');
    });

    test('disabled Worker badges retain each readiness state', () {
      expect(
        deriveLocalWorkerStatusBadges(makeWorker(
          status: LocalWorkerStatus.disabled,
          readinessState: WorkerReadinessState.ready,
        )),
        ['Disabled', 'Ready'],
      );
      expect(
        deriveLocalWorkerStatusBadges(makeWorker(
          status: LocalWorkerStatus.disabled,
          readinessState: WorkerReadinessState.runtimeUnavailable,
        )),
        ['Disabled', 'Needs attention'],
      );
      expect(
        deriveLocalWorkerStatusBadges(makeWorker(
          status: LocalWorkerStatus.disabled,
          readinessState: WorkerReadinessState.setupRequired,
        )),
        ['Disabled', 'Setup required'],
      );
      expect(
        deriveLocalWorkerStatusBadges(makeWorker(
          status: LocalWorkerStatus.disabled,
          readinessState: WorkerReadinessState.runtimeUnavailable,
          readinessIssueCode: 'cli_not_found',
        )),
        ['Disabled', 'Not installed'],
      );
    });

    test('maps package state into the limited Workers row vocabulary', () {
      expect(
        deriveLocalWorkerHealth(makeWorker(
          status: LocalWorkerStatus.ready,
          readinessState: WorkerReadinessState.ready,
        )),
        'Ready',
      );
      expect(
        deriveLocalWorkerHealth(makeWorker(
          status: LocalWorkerStatus.needsAttention,
          readinessState: WorkerReadinessState.setupRequired,
        )),
        'Setup required',
      );
      expect(
        deriveLocalWorkerHealth(makeWorker(
          status: LocalWorkerStatus.needsAttention,
          readinessState: WorkerReadinessState.runtimeUnavailable,
        )),
        'Needs attention',
      );
      expect(
        deriveLocalWorkerHealth(makeWorker(
          status: LocalWorkerStatus.needsAttention,
          readinessState: WorkerReadinessState.runtimeUnavailable,
          readinessIssueCode: 'cli_not_found',
        )),
        'Not installed',
      );
      expect(
        deriveLocalWorkerHealth(makeWorker(
          status: LocalWorkerStatus.disabled,
          readinessState: WorkerReadinessState.runtimeUnavailable,
        )),
        'Disabled',
      );
    });
  });

  testWidgets(
      'workspace tab respects registration and connection state for buttons and field editability',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    // Case 1: Unregistered workspace
    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.firstLaunch,
        title: 'Connect this Workspace',
        detail: 'Sign in to register this computer.',
        hostname: 'test-mac',
        registered: false,
        workspaceReady: false,
      ),
      credentialStore: credentials,
      signedIn: true,
      onConnect: () async {},
      onRegister: ([name]) async {},
      onReset: () {},
    );
    await tester.pumpAndSettle();

    // Connect button is disabled
    final connectBtn = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect'));
    expect(connectBtn.onPressed, isNull);

    // Register button is enabled
    final registerBtn = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Register'));
    expect(registerBtn.onPressed, isNotNull);

    // Workspace name is editable and enabled
    final nameField =
        tester.widget<TextField>(find.widgetWithText(TextField, 'test-mac'));
    expect(nameField.readOnly, isFalse);
    expect(nameField.enabled, isTrue);

    // Work Root is enabled when disconnected
    final workRootField = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Not configured'));
    expect(workRootField.enabled, isTrue);

    // Browse button is enabled
    final browseBtn =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Browse'));
    expect(browseBtn.onPressed, isNotNull);

    // Case 2: Registered and connected workspace
    await pumpDashboard(
      tester,
      const WorkspaceUiSnapshot(
        mode: WorkspaceUiMode.ready,
        title: 'Workspace is ready',
        detail: 'Ready',
        registered: true,
        workspaceId: 'ws-123',
        workspaceReady: true,
        cloudConnected: true,
        workspaceName: 'Registered Mac',
        workRootPath: '/workspace/root',
      ),
      credentialStore: credentials,
      signedIn: true,
      onDisconnect: () {},
      onRelease: () async {},
      onReset: () {},
    );
    await tester.pumpAndSettle();

    // Disconnect button is enabled
    final disconnectBtn = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Disconnect'));
    expect(disconnectBtn.onPressed, isNotNull);

    // Release button is enabled
    final releaseBtn = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Release'));
    expect(releaseBtn.onPressed, isNotNull);

    // Reset button is enabled
    final resetBtn = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Reset'));
    expect(resetBtn.onPressed, isNotNull);

    // Workspace name is read-only and disabled
    final regNameField = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Registered Mac'));
    expect(regNameField.readOnly, isTrue);
    expect(regNameField.enabled, isFalse);

    // Work root is disabled when connected
    final regWorkRootField = tester
        .widget<TextField>(find.widgetWithText(TextField, '/workspace/root'));
    expect(regWorkRootField.enabled, isFalse);

    // Browse button is disabled when connected
    final disabledBrowseBtn =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Browse'));
    expect(disabledBrowseBtn.onPressed, isNull);
  });
}

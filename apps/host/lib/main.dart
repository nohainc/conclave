import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'cloud_connection.dart';
import 'diagnostics.dart';
import 'desktop_auth.dart';
import 'friendly_computer_name.dart';
import 'host.dart';
import 'host_configuration.dart';
import 'local_worker_setup.dart';
import 'local_worker_permissions.dart';
import 'first_party_worker_registry.dart';
import 'secure_credentials.dart';
import 'secure_credentials_flutter.dart';
import 'v7_adapter_package_store.dart';
import 'v7_adapter_protocol.dart';
import 'v7_adapter_catalog.dart';
import 'workspace_enrollment.dart';
import 'workspace_runtime.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_lifecycle.dart';
import 'local_management_authenticator.dart';
import 'copyable_messages.dart';

export 'copyable_messages.dart' show showCopyableErrorSnackBar;

bool _hasValidCachedDesktopSession(SecureCredentialStore credentialStore) {
  try {
    final stored = credentialStore.readSync(desktopHumanCredentialKey);
    if (stored == null || stored.isEmpty) return false;
    final decoded = jsonDecode(stored);
    if (decoded is! Map || decoded['credential'] is! String) return false;
    final expiresAt = DateTime.tryParse(decoded['expiresAt']?.toString() ?? '');
    return expiresAt != null && expiresAt.isAfter(DateTime.now().toUtc());
  } on Object {
    return false;
  }
}

String? _readUserEmailFromCredentialStore(
    SecureCredentialStore credentialStore) {
  try {
    final stored = credentialStore.readSync(desktopHumanCredentialKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map) return null;
    final email = decoded['email'];
    return email is String && email.isNotEmpty ? email : null;
  } on Object {
    return null;
  }
}

String _webSocketUpgradeStatus(HostCloudConnection? connection) {
  if (connection == null) return 'not configured';
  final failureAt = connection.lastWebSocketFailureAt;
  if (failureAt != null &&
      (connection.lastWebSocketUpgradeAt == null ||
          failureAt.isAfter(connection.lastWebSocketUpgradeAt!))) {
    final status = connection.lastWebSocketHttpStatusCode;
    return status == null ? 'failed' : 'failed (HTTP $status)';
  }
  final status = connection.lastHttpStatusCode;
  if (status != null) return 'failed (HTTP $status)';
  if (connection.lastWebSocketUpgradeAt != null) return 'succeeded';
  return 'not completed';
}

Future<bool> drainWorkspaceAssignments({
  required int Function() activeAssignmentCount,
  required void Function() beginDrain,
  required void Function() restoreNewWorkState,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 250),
  DateTime Function()? now,
  Future<void> Function(Duration)? wait,
}) async {
  beginDrain();
  final clock = now ?? DateTime.now;
  final delay = wait ?? Future<void>.delayed;
  final deadline = clock().add(timeout);
  while (activeAssignmentCount() > 0 && clock().isBefore(deadline)) {
    await delay(pollInterval);
  }
  if (activeAssignmentCount() == 0) return true;
  restoreNewWorkState();
  return false;
}

class HostLifecycleController extends ChangeNotifier {
  HostLifecycleController(this.host) {
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _publishMenuStatus();
      notifyListeners();
    });
  }

  Host host;
  bool _hidden = false;
  bool _quitting = false;
  Object? _startupError;
  Timer? _statusTimer;
  // Fail closed until the human session has been restored by the shell router.
  bool _managementAuthRequired = true;
  static const _desktopChannel =
      MethodChannel('com.conclave.workspace/desktop');

  static Future<void> setLaunchAtLogin(bool enabled) async {
    if (!Platform.isMacOS) {
      if (enabled) {
        throw UnsupportedError(
          'Launch at login is currently supported only on macOS.',
        );
      }
      return;
    }
    await _desktopChannel.invokeMethod<void>('setLaunchAtLogin', enabled);
  }

  bool get hidden => _hidden;
  bool get quitting => _quitting;
  bool get running => host.isRunning;
  Object? get startupError => _startupError;
  bool get acceptingNewWork => host.cloudConnection?.acceptingNewWork ?? false;

  void updateManagementAuthRequired(bool required) {
    if (_managementAuthRequired == required) return;
    _managementAuthRequired = required;
    _publishMenuStatus();
  }

  void refreshMenuStatus() {
    _publishMenuStatus();
    notifyListeners();
  }

  Future<void> checkWorkerReadiness({
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
    String? workerTypeId,
  }) async {
    await host.workerReadinessMonitor?.checkNow(
      mode: mode,
      workerTypeId: workerTypeId,
    );
    notifyListeners();
  }

  Future<void> handleDesktopAction(String action) async {
    switch (action) {
      case 'openWorkspace':
        restore();
        break;
      case 'pause':
        host.cloudConnection?.pauseNewWork();
        break;
      case 'resume':
        host.cloudConnection?.resumeNewWork();
        break;
      case 'togglePause':
        final connection = host.cloudConnection;
        if (connection?.isDraining == true) break;
        if (connection?.acceptingNewWork == true) {
          connection?.pauseNewWork();
        } else if (connection?.isConnected == true) {
          connection?.resumeNewWork();
        }
        break;
      case 'diagnostics':
        final file = await exportDiagnostics();
        await openPath(file.path);
        break;
      case 'logs':
        await openPath(WorkspacePaths(host.config.dataDirectory).logsFile.path);
        break;
      case 'openAX':
        await openAX();
        break;
      default:
        return;
    }
    _publishMenuStatus();
    notifyListeners();
  }

  static Future<void> openPath(String path) async {
    try {
      await _desktopChannel.invokeMethod<void>('openPath', path);
    } catch (_) {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      }
    }
  }

  static Future<String?> chooseDirectory({String? initialPath}) async {
    try {
      final result = await _desktopChannel.invokeMethod<String>(
          'chooseDirectory', initialPath);
      if (result != null && result.trim().isNotEmpty) return result.trim();
    } catch (_) {}
    if (Platform.isMacOS) {
      try {
        final script = initialPath != null &&
                Directory(initialPath).existsSync()
            ? 'POSIX path of (choose folder with prompt "Select Work Root Directory" default location POSIX file "$initialPath")'
            : 'POSIX path of (choose folder with prompt "Select Work Root Directory")';
        final result = await Process.run('osascript', ['-e', script]);
        if (result.exitCode == 0) {
          final path = result.stdout.toString().trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    } else if (Platform.isLinux) {
      try {
        final result = await Process.run('zenity', [
          '--file-selection',
          '--directory',
          '--title=Select Work Root Directory'
        ]);
        if (result.exitCode == 0) {
          final path = result.stdout.toString().trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    } else if (Platform.isWindows) {
      try {
        final ps = '''
Add-Type -AssemblyName System.Windows.Forms
\$f = New-Object System.Windows.Forms.FolderBrowserDialog
\$f.Description = "Select Work Root Directory"
if (\$f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { \$f.SelectedPath }
''';
        final result =
            await Process.run('powershell', ['-NoProfile', '-Command', ps]);
        if (result.exitCode == 0) {
          final path = result.stdout.toString().trim();
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<void> openAX([String? url]) async {
    try {
      await _desktopChannel.invokeMethod<void>('openAX');
    } catch (_) {
      final target = url ?? 'https://app.conclaveax.com';
      if (Platform.isMacOS) {
        await Process.run('open', [target]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [target]);
      }
    }
  }

  void _publishMenuStatus() {
    final connection = host.cloudConnection;
    final state = startupError != null
        ? 'Attention'
        : connection?.isConnected == true
            ? 'Connected'
            : WorkspaceLifecyclePreferencesStore(host.config.dataDirectory)
                        .readSync()
                        .desiredRuntime ==
                    DesiredRuntimeState.connected
                ? 'Connecting'
                : 'Disconnected';
    unawaited(_desktopChannel.invokeMethod<void>('status', {
      'state': state,
      'transportMode': connection?.activeTransportMode ?? 'offline',
      'fallbackHealth': connection?.fallbackHealthStatus ?? 'not configured',
      'lastWebSocketFailure': connection?.lastWebSocketFailure,
      'active': connection?.activeAssignmentCount ?? 0,
      'accepting': connection?.acceptingNewWork ?? false,
      'draining': connection?.isDraining ?? false,
      'managementLocked': WorkspaceLifecyclePreferencesStore(
            host.config.dataDirectory,
          ).readSync().managementLockPreference ==
          ManagementLockState.locked,
      'reauthRequired': _managementAuthRequired,
      'runtimeRunning': connection?.isConnected == true,
    }).catchError((_) {}));
  }

  HostUiSnapshot get uiSnapshot {
    final connection = host.cloudConnection;
    final registration =
        HostRegistrationStore(host.config.dataDirectory).readSync();
    final preferences =
        WorkspaceLifecyclePreferencesStore(host.config.dataDirectory)
            .readSync();
    final workspaceName = registration?.name ??
        preferences.customWorkspaceName ??
        resolveFriendlyComputerNameSync();
    final workspaceId = host.config.workspaceId ?? registration?.workspaceId;
    final hostId = host.config.hostId ?? registration?.hostId;
    final installationId = host.installationId ??
        host.config.installationId ??
        registration?.installationId ??
        InstallationIdentityStore(host.config.dataDirectory).readSync();
    final hostname = registration?.hostname ?? Platform.localHostname;
    final ownerUserId = registration?.ownerUserId;
    final cloudUrl = host.config.cloudUri?.toString() ?? registration?.cloudUrl;
    final workRootPath = host.workRoot?.path ?? host.config.workRootPath;
    final desiredRuntimeConnected =
        WorkspaceLifecyclePreferencesStore(host.config.dataDirectory)
                .readSync()
                .desiredRuntime ==
            DesiredRuntimeState.connected;

    if (quitting) {
      return HostUiSnapshot(
        mode: HostUiMode.stopped,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Stopping Workspace',
        detail: 'Stopping the runtime and closing its connection.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Stopping',
        connectionStage: connection?.connectionStage,
        connectionError: connection?.lastConnectionError,
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    if (startupError != null) {
      return HostUiSnapshot(
        mode: HostUiMode.offline,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect. It will be safe to retry.',
        issue: startupError.toString(),
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        paired: hostId != null && workspaceId != null,
        ownerUserId: ownerUserId,
        workspaceReady:
            connection?.connectionStage == HostConnectionStage.ready,
        // A saved token can be present and still be revoked in Cloud. The
        // Account section can recover it through the human management API.
        statusLabel: 'Offline',
        logsPath: WorkspacePaths(host.config.dataDirectory).logsDirectory.path,
        connectionStage: connection?.connectionStage,
        connectionError:
            connection?.lastConnectionError ?? startupError.toString(),
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    if (host.config.hostId == null) {
      final isPaired = registration != null;
      return HostUiSnapshot(
        mode: isPaired ? HostUiMode.offline : HostUiMode.firstLaunch,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: isPaired ? 'Workspace is offline' : 'Connect this Workspace',
        detail: isPaired
            ? 'The Workspace is registered and ready to connect.'
            : 'Sign in to register this computer with Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        hostId: hostId,
        paired: isPaired,
        ownerUserId: ownerUserId,
        installationId: installationId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: isPaired ? 'Offline' : 'Not paired',
        connectionStage: connection?.connectionStage,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
      );
    }
    if (!running) {
      return HostUiSnapshot(
        mode: HostUiMode.starting,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Starting Workspace',
        detail: 'Checking this machine and reconnecting to Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        installationId: installationId,
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Starting',
        connectionStage: connection?.connectionStage,
        connectionError: connection?.lastConnectionError,
        connectionHttpStatus: connection?.lastHttpStatusCode,
        runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
        protocolHelloStatus: connection?.protocolHelloStatus,
        dnsTlsStatus: connection?.lastDnsTlsStatus,
        webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
        activeTransportMode: connection?.activeTransportMode,
        fallbackHealthStatus: connection?.fallbackHealthStatus,
        lastWebSocketFailure: connection?.lastWebSocketFailure,
        lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
        lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    final activeAssignments = connection?.activeAssignmentCount ?? 0;
    final isConnected = connection?.isConnected ?? false;
    final stage = connection?.connectionStage;
    final isConnecting = stage == HostConnectionStage.validating ||
        stage == HostConnectionStage.connecting ||
        stage == HostConnectionStage.authenticating ||
        stage == HostConnectionStage.synchronizing ||
        stage == HostConnectionStage.reconnecting ||
        stage == HostConnectionStage.switchingToWebSocket;
    final isOffline = !isConnected && !isConnecting;
    final statusLabel = isConnecting
        ? (stage == HostConnectionStage.reconnecting
            ? 'Reconnecting'
            : stage == HostConnectionStage.switchingToWebSocket
                ? 'Switching to WebSocket'
                : 'Connecting')
        : isOffline
            ? 'Offline'
            : (connection?.isDraining ?? false)
                ? 'Draining'
                : !(connection?.acceptingNewWork ?? true)
                    ? 'Paused'
                    : 'Connected';

    return HostUiSnapshot(
      mode: isConnecting
          ? HostUiMode.starting
          : isOffline
              ? HostUiMode.offline
              : activeAssignments > 0
                  ? HostUiMode.active
                  : HostUiMode.ready,
      desiredRuntimeConnected: desiredRuntimeConnected,
      title: isConnecting
          ? 'Connecting Workspace'
          : isOffline
              ? 'Workspace is offline'
              : activeAssignments > 0
                  ? 'Work in progress'
                  : 'Workspace is ready',
      detail: isConnecting
          ? 'Checking this machine and connecting to Conclave.'
          : isOffline
              ? activeAssignments > 0
                  ? 'Cloud is disconnected. Active work remains on this computer while the Workspace retries.'
                  : 'The Workspace is registered, but Cloud has not authenticated this connection.'
              : activeAssignments > 0
                  ? 'The Workspace is running assigned work.'
                  : 'This computer is registered and ready to run assigned work.',
      issue: isConnecting
          ? null
          : isOffline
              ? (connection?.lastConnectionError ??
                  'No authenticated Cloud session. Recover the Workspace connection from Account.')
              : null,
      workspaceName: workspaceName,
      workspaceId: workspaceId,
      installationId: installationId,
      hostId: hostId,
      hostname: hostname,
      cloudUrl: cloudUrl,
      workRootPath: workRootPath,
      paired: true,
      ownerUserId: ownerUserId,
      workspaceReady: connection?.connectionStage == HostConnectionStage.ready,
      cloudConnected: isConnected,
      statusLabel: statusLabel,
      logsPath: WorkspacePaths(host.config.dataDirectory).logsFile.path,
      activeAssignments: activeAssignments,
      activeAssignmentIds: connection?.activeAssignmentIds ?? const [],
      reconnectCount: connection?.reconnectCount ?? 0,
      sessionId: connection?.sessionId,
      lastInventorySyncAt: connection?.lastInventorySyncAt,
      connectionStage: connection?.connectionStage,
      connectionError: connection?.lastConnectionError,
      connectionHttpStatus: connection?.lastHttpStatusCode,
      runtimeCredentialAvailable: host.config.authToken?.isNotEmpty == true,
      protocolHelloStatus: connection?.protocolHelloStatus,
      dnsTlsStatus: connection?.lastDnsTlsStatus,
      webSocketUpgradeStatus: _webSocketUpgradeStatus(connection),
      activeTransportMode: connection?.activeTransportMode,
      fallbackHealthStatus: connection?.fallbackHealthStatus,
      lastWebSocketFailure: connection?.lastWebSocketFailure,
      lastWebSocketHttpStatusCode: connection?.lastWebSocketHttpStatusCode,
      lastWebSocketFailureAt: connection?.lastWebSocketFailureAt,
      lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
    );
  }

  Future<void> launch() async {
    _startupError = null;
    try {
      await host.start();
    } catch (error) {
      _startupError = error;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> retryConnection() async {
    final connection = host.cloudConnection;
    if (!running || connection == null) {
      await launch();
      return;
    }
    _startupError = null;
    try {
      await connection.retryNow();
    } catch (error) {
      _startupError = error;
    }
    notifyListeners();
  }

  Future<void> replaceHost(Host nextHost) async {
    await host.stop();
    host = nextHost;
    _startupError = null;
    _hidden = false;
    notifyListeners();
    await launch();
  }

  void minimize() {
    if (_quitting) return;
    _hidden = true;
    notifyListeners();
  }

  void restore() {
    if (_quitting) return;
    _hidden = false;
    notifyListeners();
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    _statusTimer?.cancel();
    notifyListeners();
    await host.stop();
    notifyListeners();
  }

  Future<File> exportDiagnostics() async {
    final status = await host.statusProvider?.call() ?? const {};
    final update = await host.updateStatusProvider?.call() ?? const {};
    final checkAt =
        DateTime.tryParse(status['lastUpdateCheckAt'] as String? ?? '');
    return writeHostDiagnostics(
      config: host.config,
      connection: host.cloudConnection,
      journal: host.cloudConnection?.assignmentJournal,
      workerRegistry: host.localWorkerRegistry,
      adapterPackageStore: host.adapterPackageStore,
      lastUpdateCheckStatus: status['lastUpdateCheckStatus'] as String?,
      lastUpdateCheckAt: checkAt,
      updateStatus: update['phase'] as String?,
      workRootPath: host.workRoot?.path,
    );
  }
}

enum HostUiMode {
  firstLaunch,
  starting,
  ready,
  authNeeded,
  active,
  offline,
  installFailure,
  stopped,
}

class HostUiSnapshot {
  const HostUiSnapshot({
    required this.mode,
    required this.title,
    required this.detail,
    this.workspaceName,
    this.workspaceId,
    this.installationId,
    this.hostId,
    this.hostname,
    this.cloudUrl,
    this.workRootPath,
    this.statusLabel = 'Offline',
    this.paired = false,
    this.ownerUserId,
    this.desiredRuntimeConnected = false,
    this.workspaceReady = false,
    this.cloudConnected = false,
    this.accountsNeedingAction = const [],
    this.workerSummary = 'Worker diagnostics are available after sign-in',
    this.logsPath,
    this.updateSummary = 'Up to date',
    this.activeAssignments = 0,
    this.activeAssignmentIds = const [],
    this.reconnectCount = 0,
    this.sessionId,
    this.lastInventorySyncAt,
    this.connectionStage,
    this.connectionError,
    this.connectionHttpStatus,
    this.runtimeCredentialAvailable = false,
    this.protocolHelloStatus,
    this.dnsTlsStatus,
    this.webSocketUpgradeStatus,
    this.activeTransportMode,
    this.fallbackHealthStatus,
    this.lastWebSocketFailure,
    this.lastWebSocketHttpStatusCode,
    this.lastWebSocketFailureAt,
    this.lastConnectionAttemptAt,
    this.appVersion = conclaveWorkspaceAppVersion,
    this.issue,
  });

  final HostUiMode mode;
  final String title;
  final String detail;
  final String? workspaceName;
  final String? workspaceId;
  final String? installationId;
  final String? hostId;
  final String? hostname;
  final String? cloudUrl;
  final String? workRootPath;
  final String statusLabel;
  final bool paired;
  final String? ownerUserId;
  final bool desiredRuntimeConnected;
  final bool workspaceReady;
  final bool cloudConnected;
  final List<String> accountsNeedingAction;
  final String workerSummary;
  final String? logsPath;
  final String updateSummary;
  final int activeAssignments;
  final List<String> activeAssignmentIds;
  final int reconnectCount;
  final String? sessionId;
  final DateTime? lastInventorySyncAt;
  final HostConnectionStage? connectionStage;
  final String? connectionError;
  final int? connectionHttpStatus;
  final bool runtimeCredentialAvailable;
  final String? protocolHelloStatus;
  final String? dnsTlsStatus;
  final String? webSocketUpgradeStatus;
  final String? activeTransportMode;
  final String? fallbackHealthStatus;
  final String? lastWebSocketFailure;
  final int? lastWebSocketHttpStatusCode;
  final DateTime? lastWebSocketFailureAt;
  final DateTime? lastConnectionAttemptAt;
  final String appVersion;
  final String? issue;

  String get runtimeCredentialStatus => runtimeCredentialAvailable
      ? 'Available locally (value hidden)'
      : desiredRuntimeConnected
          ? 'Missing from secure storage'
          : 'Not needed while Workspace is disconnected';

  bool get hasLocalAction =>
      accountsNeedingAction.isNotEmpty ||
      mode == HostUiMode.authNeeded ||
      mode == HostUiMode.installFailure;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WorkspacePaths.migrateLegacyMacLayout(
    migrateState: Platform.environment['CONCLAVE_HOST_DATA_DIR'] == null,
  );
  const credentialStore = PlatformSecureCredentialStore(
    nativeKeychain: FlutterMacKeychainBridge(),
  );
  final dataDirectory = HostConfig.resolveDataDirectory(const []);
  final preferencesStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
  final registration = HostRegistrationStore(dataDirectory).readSync();
  var runtimeCredentialLoaded = false;
  var hasRuntimeCredential = false;
  if (preferencesStore.needsRuntimeCredentialMigrationCheck &&
      registration != null) {
    hasRuntimeCredential =
        (await credentialStore.readForSynchronousConfig(registration.hostId))
                ?.isNotEmpty ==
            true;
    runtimeCredentialLoaded = true;
  }
  try {
    await preferencesStore.migrateLegacyIfNeeded(
      hasRuntimeRegistrationAndCredential:
          registration != null && hasRuntimeCredential,
    );
  } on Object catch (error) {
    // A failed preference migration must not prevent the management shell from
    // opening. The unversioned state reader still preserves any valid explicit
    // intent; otherwise its safe default suppresses runtime auto-connect.
    debugPrint('Could not migrate Workspace lifecycle preferences: $error');
  }
  final startupPreferences = preferencesStore.readSync();
  final desiredRuntime = startupPreferences.desiredRuntime;
  if (shouldHideManagementWindowOnStartup(
    isMacOS: Platform.isMacOS,
    launchAtLogin: startupPreferences.launchAtLogin,
  )) {
    unawaited(const MethodChannel('com.conclave.workspace/desktop')
        .invokeMethod<void>('hideMainWindow')
        .catchError((_) {}));
  }
  if (registration != null &&
      desiredRuntime == DesiredRuntimeState.connected &&
      !runtimeCredentialLoaded) {
    await credentialStore.readForSynchronousConfig(registration.hostId);
  }
  await credentialStore.read(desktopHumanCredentialKey);
  final config = HostConfig.fromArgs(
    const [],
    credentialStore: credentialStore,
    ignoreSavedRegistration: desiredRuntime == DesiredRuntimeState.disconnected,
  );
  final host = await buildWorkspaceRuntime(
    config,
    credentialStore: credentialStore,
  );
  runApp(ConclaveHostApp(lifecycle: HostLifecycleController(host)));
}

class ConclaveHostApp extends StatefulWidget {
  const ConclaveHostApp({
    required this.lifecycle,
    this.localAuthenticator = const MethodChannelLocalManagementAuthenticator(),
    super.key,
  });

  final HostLifecycleController lifecycle;
  final LocalManagementAuthenticator localAuthenticator;

  @override
  State<ConclaveHostApp> createState() => _ConclaveHostAppState();
}

class _ConclaveHostAppState extends State<ConclaveHostApp>
    with WidgetsBindingObserver {
  int _workerRevision = 0;
  late final RecentLocalAuthenticationGate _stepUpGate;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stepUpGate = RecentLocalAuthenticationGate(
      authenticator: widget.localAuthenticator,
    );
    widget.lifecycle.addListener(_refresh);
    const desktopChannel = MethodChannel('com.conclave.workspace/desktop');
    desktopChannel.setMethodCallHandler((call) async {
      if (call.method == 'menuAction' && call.arguments is String) {
        final action = call.arguments as String;
        if (action == 'quit') {
          await _confirmQuit();
        } else {
          await widget.lifecycle.handleDesktopAction(action);
        }
      } else if (call.method == 'requestQuit') {
        await _confirmQuit();
      }
    });
    unawaited(widget.lifecycle.launch());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.lifecycle.removeListener(_refresh);
    unawaited(widget.lifecycle.quit());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.lifecycle.checkWorkerReadiness());
    }
  }

  void _refresh() => setState(() {});

  WorkspaceLifecyclePreferences get _preferences =>
      WorkspaceLifecyclePreferencesStore(
        widget.lifecycle.host.config.dataDirectory,
      ).readSync();

  Future<bool> _requireStepUp(String reason) async {
    var authenticated = false;
    try {
      authenticated = await _stepUpGate.require(reason);
    } on Object {
      authenticated = false;
    }
    if (!authenticated && mounted) {
      final context = _navigatorKey.currentContext;
      if (context != null) {
        showCopyableMessageSnackBar(
          context,
          'Local authentication was not completed.',
          isError: true,
        );
      }
    }
    return authenticated;
  }

  Future<void> _setLaunchAtLogin(bool enabled) async {
    try {
      await HostLifecycleController.setLaunchAtLogin(enabled);
    } catch (e) {
      debugPrint('Could not set launch at login via desktop channel: $e');
    }
    final store = WorkspaceLifecyclePreferencesStore(
      widget.lifecycle.host.config.dataDirectory,
    );
    final p = store.readSync();
    await store.write(WorkspaceLifecyclePreferences(
      desiredRuntime: p.desiredRuntime,
      launchAtLogin: enabled,
      managementLockPreference: p.managementLockPreference,
      autoLockTimeout: p.autoLockTimeout,
      ownerUserId: p.ownerUserId,
      ownerDisplayName: p.ownerDisplayName,
      customWorkspaceName: p.customWorkspaceName,
    ));
    if (mounted) setState(() {});
  }

  Future<void> _confirmQuit() async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final lifecycle = widget.lifecycle;
    final connection = lifecycle.host.cloudConnection;
    final initialCount = connection?.activeAssignmentCount ?? 0;
    if (initialCount > 0) {
      final drainAndQuit = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('Assignments are running'),
          content: CopyableMessageText(
            'There ${initialCount == 1 ? 'is 1 active assignment' : 'are $initialCount active assignments'}. '
            'Drain and quit stops accepting new work, waits for active assignments to finish, then closes the runtime. '
            'If they do not finish within 15 seconds, the Workspace stays open.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Drain and quit'),
            ),
          ],
        ),
      );
      if (drainAndQuit != true || !mounted) return;

      if (connection != null) {
        final acceptingBeforeDrain = connection.acceptingNewWork;
        final drained = await drainWorkspaceAssignments(
          activeAssignmentCount: () => connection.activeAssignmentCount,
          beginDrain: () {
            connection.beginDrain();
            lifecycle.refreshMenuStatus();
          },
          restoreNewWorkState: acceptingBeforeDrain
              ? () {
                  connection.resumeNewWork();
                  lifecycle.refreshMenuStatus();
                }
              : () {
                  connection.pauseNewWork();
                  lifecycle.refreshMenuStatus();
                },
        );
        if (!drained) {
          if (!mounted) return;
          await showDialog<void>(
            context: dialogContext,
            builder: (context) => AlertDialog(
              title: const Text('Assignments are still running'),
              content: CopyableMessageText(
                'The Workspace remains open with ${connection.activeAssignmentCount} active assignments. '
                '${acceptingBeforeDrain ? 'New work has resumed.' : 'New work remains paused.'}',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Keep Workspace running'),
                ),
              ],
            ),
          );
          return;
        }
      }
    } else {
      // Prevent an assignment racing the shutdown between the count check and
      // closing the transport.
      connection?.beginDrain();
      lifecycle.refreshMenuStatus();
    }

    try {
      await lifecycle.quit();
      const desktopChannel = MethodChannel('com.conclave.workspace/desktop');
      await desktopChannel.invokeMethod<void>('terminate');
    } catch (error) {
      if (mounted) {
        await showDialog<void>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: const Text('Unable to Quit'),
            content: CopyableMessageText(
              'An error occurred while stopping the Workspace: $error\n\n'
              'Conclave Workspace did not close.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _exportDiagnostics() async {
    final file = await widget.lifecycle.exportDiagnostics();
    final ctx = _navigatorKey.currentContext;
    if (!mounted || ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text('Diagnostics exported to ${file.path}')),
    );
  }

  Future<DesktopHumanSession?> _approveDesktopAuthInBrowser(
    DesktopAuthClient client,
    DesktopAuthIntent intent, {
    required String title,
    required String description,
  }) async {
    final context = _navigatorKey.currentContext;
    if (context == null) return null;
    var browserOpened = false;
    var browserOpening = false;
    var cancelled = false;
    var dialogOpen = true;
    String? browserError;
    final dialogResult = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(browserOpened
                  ? 'Complete sign-in and approve Conclave Workspace in your browser. This window will update automatically.'
                  : description),
              if (browserError != null) ...[
                const SizedBox(height: 12),
                SelectableText(browserError!),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: browserOpening
                  ? null
                  : () async {
                      setDialogState(() {
                        browserOpening = true;
                        browserError = null;
                      });
                      try {
                        await client.cancelIntent(intent);
                      } on Object catch (error) {
                        // The request may already have been approved or expired.
                        // Closing the desktop dialog still stops its local wait;
                        // browser tabs observe the server's terminal state.
                        browserError = error.toString();
                      }
                      cancelled = true;
                      dialogOpen = false;
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    },
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: browserOpening
                  ? null
                  : () async {
                      setDialogState(() {
                        browserOpening = true;
                        browserError = null;
                      });
                      try {
                        await client.openVerification(intent);
                        if (!dialogOpen) return;
                        setDialogState(() {
                          browserOpened = true;
                          browserOpening = false;
                        });
                      } on Object catch (error) {
                        if (!dialogOpen) return;
                        setDialogState(() {
                          browserOpening = false;
                          browserError = error.toString();
                        });
                      }
                    },
              icon: const Icon(Icons.open_in_browser),
              label: Text(browserOpening
                  ? 'Opening…'
                  : browserOpened
                      ? 'Open browser again'
                      : 'Open browser'),
            ),
          ],
        ),
      ),
    );
    try {
      return await Future.any<DesktopHumanSession>([
        client.waitForApprovalAndClaim(
          intent,
          isCancelled: () => cancelled,
        ),
        dialogResult
            .then((_) => throw StateError('Workspace sign-in was cancelled.')),
      ]);
    } on StateError {
      if (cancelled) return null;
      rethrow;
    } finally {
      if (mounted && dialogOpen) {
        dialogOpen = false;
        Navigator.of(context, rootNavigator: true).pop(false);
      }
    }
  }

  Future<void> _signInDesktopHuman() async {
    final lifecycle = widget.lifecycle;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    final registration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    final client = DesktopAuthClient(cloudUrl: cloudUrl);
    DesktopHumanSession? previousSession;
    var failureContext = 'creating the sign-in request';
    DesktopHumanSession? claimedSession;
    try {
      final previousRecord =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (previousRecord != null) {
        try {
          final decoded = jsonDecode(previousRecord);
          if (decoded is Map) {
            previousSession = DesktopHumanSession.fromSecureJson(
              Map<String, dynamic>.from(decoded),
            );
          }
        } on Object {
          // Replace malformed local session data after the new session succeeds.
        }
      }
      final intent = await client.createIntent();
      failureContext = 'waiting for browser approval';
      final session = await _approveDesktopAuthInBrowser(
        client,
        intent,
        title: 'Sign in to Conclave Workspace',
        description:
            'Open the secure sign-in request in your browser, then sign in to your Conclave account and approve Conclave Workspace.',
      );
      if (session == null) return;
      claimedSession = session;
      failureContext = 'validating the desktop session';
      await client.validateSession(session);
      final existingRegistration = HostRegistrationStore(
        lifecycle.host.config.dataDirectory,
      ).readSync();
      final identityStore =
          InstallationIdentityStore(lifecycle.host.config.dataDirectory);
      final installationId = existingRegistration?.installationId ??
          identityStore.readSync() ??
          (existingRegistration == null
              ? null
              : await identityStore.getOrCreate());
      if (installationId != null) {
        failureContext = 'checking Workspace account ownership';
        final cloudOwnerUserId = await client.checkWorkspaceOwnership(
          session: session,
          installationId: installationId,
          workspaceId: existingRegistration?.workspaceId,
          runtimeId: existingRegistration?.hostId,
        );
        if (cloudOwnerUserId != session.userId) {
          throw StateError(
            'This Workspace belongs to another Conclave account. Disconnect and release it from the current account before switching users.',
          );
        }
        if (previousSession != null &&
            previousSession.userId != session.userId &&
            !await _requireStepUp('Switch the Workspace account')) {
          throw StateError(
              'Local authentication is required to switch accounts.');
        }
        if (existingRegistration != null) {
          await HostRegistrationStore(
            lifecycle.host.config.dataDirectory,
          ).write(HostRegistration(
            hostId: existingRegistration.hostId,
            workspaceId: existingRegistration.workspaceId,
            cloudUrl: existingRegistration.cloudUrl,
            name: existingRegistration.name,
            hostname: existingRegistration.hostname,
            ownerUserId: cloudOwnerUserId,
            installationId: installationId,
            credentialRef: existingRegistration.credentialRef,
            pairedAt: existingRegistration.pairedAt,
          ));
        }
      }
      if (previousSession != null &&
          previousSession.userId != session.userId &&
          installationId == null &&
          !await _requireStepUp('Switch the Workspace account')) {
        throw StateError(
            'Local authentication is required to switch accounts.');
      }
      await lifecycle.host.credentialStore.write(
        desktopHumanCredentialKey,
        jsonEncode(session.toSecureJson()),
      );
      if (previousSession != null &&
          previousSession.sessionId != session.sessionId) {
        try {
          await client.revokeSession(previousSession);
        } on Object {
          // Replacing local state must not fail if the old session already expired.
        }
      }
      final preferenceStore = WorkspaceLifecyclePreferencesStore(
        lifecycle.host.config.dataDirectory,
      );
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: existingRegistration == null
            ? DesiredRuntimeState.disconnected
            : preferences.desiredRuntime,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
      ));
      if (!mounted) return;
      setState(() => _workerRevision++);
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        SnackBar(content: Text('Signed in as ${session.displayName}.')),
      );
    } catch (error) {
      if (claimedSession != null) {
        try {
          await client.revokeSession(claimedSession);
        } on Object {
          // A failed ownership check must never replace the stored session.
        }
      }
      if (mounted) {
        showCopyableErrorSnackBar(
          dialogContext,
          'Sign-in failed while $failureContext: $error',
        );
      }
    } finally {
      client.close();
    }
  }

  Future<void> _signOutDesktopHuman() async {
    final lifecycle = widget.lifecycle;
    final registration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    final desiredRuntime = WorkspaceLifecyclePreferencesStore(
      lifecycle.host.config.dataDirectory,
    ).readSync().desiredRuntime;
    final runtimeIntendedConnected =
        desiredRuntime == DesiredRuntimeState.connected;
    if (registration != null && runtimeIntendedConnected) {
      final dialogContext = _navigatorKey.currentContext;
      if (dialogContext == null) return;
      final choice = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('This Workspace is connected.'),
          content: const Text(
            'Disconnect this Workspace before signing out. Disconnecting keeps '
            'the installation owner and local Workers, credentials, adapters, '
            'and Work Root.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Disconnect and sign out'),
            ),
          ],
        ),
      );
      if (choice != true) return;
      await _disconnectWorkspace(confirmed: true);
      if (WorkspaceLifecyclePreferencesStore(
            lifecycle.host.config.dataDirectory,
          ).readSync().desiredRuntime !=
          DesiredRuntimeState.disconnected) {
        return;
      }
    }
    final stored =
        await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          final session = DesktopHumanSession.fromSecureJson(
            Map<String, dynamic>.from(decoded),
          );
          final client = DesktopAuthClient(
              cloudUrl: registration?.cloudUrl ?? conclaveProductionCloudUrl);
          try {
            await client.revokeSession(session);
          } finally {
            client.close();
          }
        }
      } on Object {
        // Local sign-out must remain available if Cloud is unreachable or the session expired.
      }
    }
    await lifecycle.host.credentialStore.delete(desktopHumanCredentialKey);
    if (mounted) setState(() => _workerRevision++);
  }

  Future<void> _registerWorkspace([String? name]) async {
    final lifecycle = widget.lifecycle;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final registration = HostRegistrationStore(dataDirectory).readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    try {
      final encoded =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (encoded == null) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final session = DesktopHumanSession.fromSecureJson(
        Map<String, dynamic>.from(decoded),
      );
      final authClient = DesktopAuthClient(cloudUrl: cloudUrl);
      try {
        await authClient.validateSession(session);
      } finally {
        authClient.close();
      }
      final installationId =
          await InstallationIdentityStore(dataDirectory).getOrCreate();
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final preferences = preferenceStore.readSync();
      final workspaceName = (name != null && name.trim().isNotEmpty)
          ? name.trim()
          : (registration?.name ??
              preferences.customWorkspaceName ??
              await resolveFriendlyComputerName());
      if (workspaceName.trim().isEmpty) {
        throw StateError('Workspace name cannot be empty.');
      }

      final facts = SafeMachineFacts.collect(
          installationId: installationId,
          name: workspaceName,
          hostname: Platform.localHostname);
      await WorkspacePairingService(
              dataDirectory: dataDirectory,
              credentialStore: lifecycle.host.credentialStore)
          .registerWithDesktopSession(
        cloudUrl: cloudUrl,
        desktopCredential: session.credential,
        facts: facts,
        expectedOwnerUserId: session.userId,
        existingWorkspaceId: registration?.workspaceId,
        existingRuntimeId: registration?.hostId,
      );
      try {
        await HostLifecycleController.setLaunchAtLogin(
            preferences.launchAtLogin);
      } catch (_) {}
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
        customWorkspaceName: workspaceName,
      ));
      final config = HostConfig.fromArgs(
        const [],
        credentialStore: lifecycle.host.credentialStore,
        ignoreSavedRegistration: true,
      );
      await lifecycle.replaceHost(await buildWorkspaceRuntime(
        config,
        credentialStore: lifecycle.host.credentialStore,
      ));
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Workspace registered.')));
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
            context, 'Could not register Workspace: $error');
      }
    }
  }

  Future<void> _connectWorkspace({String? name}) async {
    final lifecycle = widget.lifecycle;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    if (lifecycle.host.cloudConnection?.isConnected == true ||
        lifecycle.host.cloudConnection?.connectionStage ==
            HostConnectionStage.ready ||
        (lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      showCopyableErrorSnackBar(
        context,
        'Disconnect or let active work finish before connecting this Workspace again.',
      );
      return;
    }
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final registration = HostRegistrationStore(dataDirectory).readSync();
    if (registration == null) {
      await _registerWorkspace(name);
      return;
    }
    final cloudUrl = registration.cloudUrl;
    try {
      final encoded =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (encoded == null) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw StateError('Sign in to your Conclave account first.');
      }
      final session = DesktopHumanSession.fromSecureJson(
        Map<String, dynamic>.from(decoded),
      );
      final authClient = DesktopAuthClient(cloudUrl: cloudUrl);
      try {
        await authClient.validateSession(session);
      } finally {
        authClient.close();
      }
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final preferences = preferenceStore.readSync();
      try {
        await HostLifecycleController.setLaunchAtLogin(
            preferences.launchAtLogin);
      } catch (_) {}
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.connected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
        customWorkspaceName:
            preferences.customWorkspaceName ?? registration.name,
      ));
      final config = HostConfig.fromArgs(const [],
          credentialStore: lifecycle.host.credentialStore);
      await lifecycle.replaceHost(await buildWorkspaceRuntime(config,
          credentialStore: lifecycle.host.credentialStore));
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        final connection = lifecycle.host.cloudConnection;
        if (connection?.connectionStage == HostConnectionStage.ready) break;
        if (!lifecycle.running) {
          throw StateError('Workspace runtime stopped before becoming Ready.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (lifecycle.host.cloudConnection?.connectionStage !=
          HostConnectionStage.ready) {
        throw TimeoutException(
          'Workspace did not become Ready within 45 seconds.',
        );
      }
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Workspace is connected and Ready.')));
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
            context, 'Could not connect Workspace: $error');
      }
    }
  }

  Future<DesktopHumanSession?> _reauthenticateWorkspaceOwner(
    String expectedOwnerUserId, {
    bool revokeAfterVerification = true,
  }) async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return null;
    final registration = HostRegistrationStore(
      widget.lifecycle.host.config.dataDirectory,
    ).readSync();
    final cloudUrl = registration?.cloudUrl ?? conclaveProductionCloudUrl;
    final client = DesktopAuthClient(cloudUrl: cloudUrl);
    try {
      final intent = await client.createIntent();
      final session = await _approveDesktopAuthInBrowser(
        client,
        intent,
        title: 'Confirm your Conclave account',
        description:
            'Open the secure sign-in request in your browser and approve this action with the Workspace owner account.',
      );
      if (session == null) return null;
      await client.validateSession(session);
      if (session.userId != expectedOwnerUserId) {
        await client.revokeSession(session);
        throw StateError('Sign in as the Workspace owner to continue.');
      }
      if (revokeAfterVerification) await client.revokeSession(session);
      return session;
    } finally {
      client.close();
    }
  }

  Future<void> _releaseWorkspaceOwnership() async {
    final lifecycle = widget.lifecycle;
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final registration = HostRegistrationStore(dataDirectory).readSync();
    final dialogContext = _navigatorKey.currentContext;
    if (registration == null || dialogContext == null) return;
    if ((lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      showCopyableMessageSnackBar(
        dialogContext,
        'Wait for active work to finish before releasing Workspace ownership.',
        isError: true,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Release Workspace from this account?'),
        content: const Text(
          'This revokes the runtime credential, disconnects Cloud, and releases the installation owner binding so another Conclave account can connect it. Local Workers, provider credentials, adapters, and Work Root files remain on this computer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Release Workspace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final authClient = DesktopAuthClient(cloudUrl: registration.cloudUrl);
    try {
      final ownerUserId = registration.ownerUserId;
      if (ownerUserId == null) {
        throw StateError(
            'Verify this Workspace owner by reconnecting before release.');
      }
      DesktopHumanSession? session;
      final storedSessionData =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (storedSessionData != null) {
        try {
          final decoded = jsonDecode(storedSessionData);
          if (decoded is Map) {
            final candidate = DesktopHumanSession.fromSecureJson(
              Map<String, dynamic>.from(decoded),
            );
            await authClient.validateSession(candidate);
            if (candidate.userId != ownerUserId) {
              throw StateError('Sign in as the Workspace owner to release it.');
            }
            final issuedAt = candidate.issuedAt;
            final age = issuedAt == null
                ? null
                : DateTime.now().toUtc().difference(issuedAt.toUtc());
            if (age != null &&
                age >= Duration.zero &&
                age < const Duration(minutes: 4)) {
              session = candidate;
            }
          }
        } on Object {
          // An unavailable or stale session is renewed through browser approval.
        }
      }
      if (session == null) {
        // Cloud requires recent authentication for release. Browser approval
        // refreshes the desktop session without a native password prompt.
        session = await _reauthenticateWorkspaceOwner(
          ownerUserId,
          revokeAfterVerification: false,
        );
        if (session == null) return;
        await lifecycle.host.credentialStore.write(
          desktopHumanCredentialKey,
          jsonEncode(session.toSecureJson()),
        );
      }
      final installationId = registration.installationId ??
          await InstallationIdentityStore(dataDirectory).getOrCreate();
      await authClient.releaseWorkspace(
        session: session,
        installationId: installationId,
        workspaceId: registration.workspaceId,
        runtimeId: registration.hostId,
      );
      await lifecycle.host.credentialStore.delete(registration.hostId);
      await HostRegistrationStore(dataDirectory).clear();
      await LocalWorkspaceIdentityStore(dataDirectory).clear();
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
      ));
      final replacement = await buildWorkspaceRuntime(
        HostConfig.fromArgs(const [],
            credentialStore: lifecycle.host.credentialStore),
        credentialStore: lifecycle.host.credentialStore,
      );
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
              content: Text(
                  'Workspace ownership released. Local Workers and files are preserved.')),
        );
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
            dialogContext, 'Could not release Workspace ownership: $error');
      }
    } finally {
      authClient.close();
    }
  }

  Future<void> _disconnectWorkspace({bool confirmed = false}) async {
    final lifecycle = widget.lifecycle;
    final registration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    if (registration == null) return;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final accepted = confirmed ||
        (await showDialog<bool>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Disconnect Workspace?'),
                content: const Text(
                  'This computer will stop accepting Cloud work.\n\n'
                  'Active assignments will finish before it disconnects.\n\n'
                  'Local Worker credentials, configurations, and Workstream files remain on this machine unless '
                  'you explicitly choose to remove them.\n\n'
                  'You can reconnect to a Workspace at any time.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Disconnect Workspace'),
                  ),
                ],
              ),
            ) ??
            false);
    if (!accepted || !mounted) return;

    DesktopHumanSession? disconnectSession;
    var isTemporarySession = false;
    final authClient = DesktopAuthClient(cloudUrl: registration.cloudUrl);
    try {
      final ownerUserId = registration.ownerUserId;
      if (ownerUserId == null) {
        authClient.close();
        return;
      }
      final storedSessionData =
          await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
      if (storedSessionData != null) {
        try {
          final decoded = jsonDecode(storedSessionData);
          if (decoded is Map) {
            final parsedSession = DesktopHumanSession.fromSecureJson(
              Map<String, dynamic>.from(decoded),
            );
            await authClient.validateSession(parsedSession);
            if (parsedSession.userId == ownerUserId) {
              disconnectSession = parsedSession;
            }
          }
        } on Object {
          // Fall back to browser reauthentication
        }
      }
      if (disconnectSession == null) {
        disconnectSession = await _reauthenticateWorkspaceOwner(
          ownerUserId,
          revokeAfterVerification: false,
        );
        isTemporarySession = true;
        if (disconnectSession == null) {
          authClient.close();
          return;
        }
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
          dialogContext,
          'Could not verify the Workspace owner: $error',
        );
      }
      authClient.close();
      return;
    }

    try {
      final connection = lifecycle.host.cloudConnection;
      final drained = await drainWorkspaceAssignments(
        activeAssignmentCount: () => connection?.activeAssignmentCount ?? 0,
        beginDrain: () => connection?.beginDrain(),
        restoreNewWorkState: () => connection?.resumeNewWork(),
      );
      if (!drained) {
        throw StateError('Active assignments did not finish before timeout.');
      }
      final installationId = registration.installationId ??
          await InstallationIdentityStore(
            lifecycle.host.config.dataDirectory,
          ).getOrCreate();
      await authClient.disconnectWorkspace(
        session: disconnectSession,
        installationId: installationId,
        workspaceId: registration.workspaceId,
        runtimeId: registration.hostId,
      );
      await InstallationIdentityStore(lifecycle.host.config.dataDirectory)
          .authorizeRecovery();
      await lifecycle.host.credentialStore.delete(registration.hostId);
      final preferenceStore = WorkspaceLifecyclePreferencesStore(
        lifecycle.host.config.dataDirectory,
      );
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: preferences.launchAtLogin,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: preferences.ownerUserId ?? registration.ownerUserId,
        ownerDisplayName: preferences.ownerDisplayName,
        customWorkspaceName:
            preferences.customWorkspaceName ?? registration.name,
      ));
      final replacement = await buildWorkspaceRuntime(
        HostConfig.fromArgs(
          const [],
          credentialStore: lifecycle.host.credentialStore,
          ignoreSavedRegistration: true,
        ),
        credentialStore: lifecycle.host.credentialStore,
      );
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text(
              'Disconnected from Conclave AX. Local Workers and credentials are preserved.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      showCopyableErrorSnackBar(
        dialogContext,
        'Could not disconnect Workspace: $error',
      );
    } finally {
      if (isTemporarySession) {
        try {
          await authClient.revokeSession(disconnectSession);
        } on Object {
          // The temporary owner session expires automatically if revocation fails.
        }
      }
      authClient.close();
    }
  }

  Future<void> _resetLocalWorkspace() async {
    final lifecycle = widget.lifecycle;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    if ((lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      showCopyableMessageSnackBar(
        dialogContext,
        'Wait for active work to finish before resetting.',
        isError: true,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Reset Local Workspace?'),
        content: const Text(
          'Reset removes the local Workspace registration and runtime credential, '
          'configured Workers and their provider credentials, installed adapter '
          'packages, desktop sign-in session, and local runtime identity. It also '
          'disconnects the Cloud runtime when available.\n\n'
          'The persistent installation ID and its account ownership remain, so '
          'another account cannot claim this installation. Work Root metadata, '
          'Work Root contents, launch-at-login, management preferences, and '
          'other local files are kept. To transfer the '
          'installation, use the separate Release Workspace action.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset Local Workspace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final dataDir = lifecycle.host.config.dataDirectory;
      final registration = HostRegistrationStore(dataDir).readSync();
      if (registration != null) {
        final ownerUserId = registration.ownerUserId;
        if (ownerUserId == null) {
          return;
        }
        final resetAuthClient =
            DesktopAuthClient(cloudUrl: registration.cloudUrl);
        final resetSession = await _reauthenticateWorkspaceOwner(
          ownerUserId,
          revokeAfterVerification: false,
        );
        if (resetSession == null) {
          resetAuthClient.close();
          return;
        }
        if (!await _requireStepUp('Reset local Workspace')) return;
        final connection = lifecycle.host.cloudConnection;
        final drained = await drainWorkspaceAssignments(
          activeAssignmentCount: () => connection?.activeAssignmentCount ?? 0,
          beginDrain: () => connection?.beginDrain(),
          restoreNewWorkState: () => connection?.resumeNewWork(),
        );
        if (!drained) {
          throw StateError('Wait for active work to finish before resetting.');
        }
        final installationId = registration.installationId ??
            await InstallationIdentityStore(dataDir).getOrCreate();
        await resetAuthClient.disconnectWorkspace(
          session: resetSession,
          installationId: installationId,
          workspaceId: registration.workspaceId,
          runtimeId: registration.hostId,
        );
        try {
          await resetAuthClient.revokeSession(resetSession);
        } on Object {
          // This one-time session expires automatically if revocation fails.
        }
        resetAuthClient.close();
        await lifecycle.host.credentialStore.delete(registration.hostId);
      } else if (!await _requireStepUp('Reset local Workspace')) {
        return;
      }
      final workers = await lifecycle.host.localWorkerRegistry
              ?.list(includeRemoved: true) ??
          const [];
      for (final worker in workers) {
        if (worker.credentialRef != null && worker.credentialRef!.isNotEmpty) {
          await lifecycle.host.credentialStore.delete(worker.credentialRef!);
        }
      }
      await lifecycle.host.credentialStore.delete(desktopHumanCredentialKey);
      await HostRegistrationStore(dataDir).clear();
      await LocalWorkspaceIdentityStore(dataDir).clear();
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDir);
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(
        WorkspaceLifecyclePreferences.afterLocalWorkspaceReset(preferences),
      );
      final workersFile = File(
          '${dataDir.path}${Platform.pathSeparator}configured-workers.json');
      if (await workersFile.exists()) await workersFile.delete();
      final adaptersDir =
          Directory('${dataDir.path}${Platform.pathSeparator}adapters');
      if (await adaptersDir.exists()) await adaptersDir.delete(recursive: true);

      final replacement = await buildWorkspaceRuntime(
        HostConfig.fromArgs(
          const [],
          credentialStore: lifecycle.host.credentialStore,
        ),
        credentialStore: lifecycle.host.credentialStore,
      );
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(content: Text('Local Workspace has been reset.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      showCopyableErrorSnackBar(
        dialogContext,
        'Could not reset Workspace: $error',
      );
    }
  }

  Future<bool> _ensureAdapterAvailable(String workerTypeId) async {
    final host = widget.lifecycle.host;
    final packageStore = host.adapterPackageStore;
    // Seed a locally trusted fallback before asking Cloud about upgrades. A
    // catalog outage must not prevent first-party Worker setup.
    if (await packageStore.ensureFirstPartyAdapterAvailable(workerTypeId)) {
      // The background signed-release reconciler handles silent upgrades.
      return true;
    }
    final cloudUri =
        host.config.cloudUri ?? Uri.parse(conclaveProductionCloudUrl);
    final catalog = V7AdapterCatalogClient(
      cloudUri: cloudUri,
      authToken: host.config.authToken,
      packageStore: packageStore,
    );
    try {
      try {
        await catalog.installLatest(workerTypeId);
      } on Object {
        // The signed local release remains a usable baseline while Cloud is
        // unavailable or returns an invalid update.
      }
      return await packageStore.hasVerifiedActivePackage(workerTypeId);
    } finally {
      catalog.close();
    }
  }

  Future<void> _changeWorkRoot(String newPath) async {
    if (!await _requireStepUp('Change the Workspace Work Root')) return;
    final currentHost = widget.lifecycle.host;
    final updatedConfig = HostConfig(
      dataDirectory: currentHost.config.dataDirectory,
      cloudUri: currentHost.config.cloudUri,
      hostId: currentHost.config.hostId,
      installationId: currentHost.config.installationId,
      workspaceId: currentHost.config.workspaceId,
      repositoriesFile: currentHost.config.repositoriesFile,
      authToken: currentHost.config.authToken,
      workRootPath: newPath,
    );
    final replacement = await buildWorkspaceRuntime(
      updatedConfig,
      credentialStore: currentHost.credentialStore,
    );
    await widget.lifecycle.replaceHost(replacement);
    if (mounted) {
      setState(() {});
      final ctx = _navigatorKey.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Work Root changed to: $newPath')),
        );
      }
    }
  }

  Future<DesktopHumanSession?> _restoreDesktopSession(
    DesktopHumanSession session,
  ) async {
    final registration =
        HostRegistrationStore(widget.lifecycle.host.config.dataDirectory)
            .readSync();
    final cloudUrl = registration?.cloudUrl ??
        Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
        conclaveProductionCloudUrl;
    final client = DesktopAuthClient(cloudUrl: cloudUrl);
    try {
      await client.validateSession(session);
      final refreshWindow = DateTime.now().toUtc().add(
            const Duration(days: 5),
          );
      if (session.expiresAt.toUtc().isAfter(refreshWindow)) return session;
      try {
        return await client.rotateSession(session);
      } on Object {
        // Keep a still-valid session usable during transient refresh failures.
        // If Cloud revoked it during the rotation race, the second validation
        // fails and the management shell remains locked.
        await client.validateSession(session);
        return session;
      }
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _changeWorkspaceName(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final lifecycle = widget.lifecycle;
    final preferenceStore = WorkspaceLifecyclePreferencesStore(
      lifecycle.host.config.dataDirectory,
    );
    final preferences = preferenceStore.readSync();
    if (preferences.customWorkspaceName != trimmed) {
      await preferenceStore.write(
        preferences.copyWith(customWorkspaceName: trimmed),
      );
      if (mounted) setState(() {});
    }
  }

  Widget _buildManagementDashboard() {
    final lifecycle = widget.lifecycle;
    return HostDashboard(
      snapshot: lifecycle.uiSnapshot,
      launchAtLogin: _preferences.launchAtLogin,
      onLaunchAtLoginChanged: _setLaunchAtLogin,
      requireStepUp: _requireStepUp,
      onSignIn: _signInDesktopHuman,
      onSignOut: _signOutDesktopHuman,
      onConnect: () => _connectWorkspace(),
      onRegister: _registerWorkspace,
      onRecoverCredential: ([name]) => _connectWorkspace(name: name),
      onChangeWorkspaceName: _changeWorkspaceName,
      onDisconnect: _disconnectWorkspace,
      onRelease: _releaseWorkspaceOwnership,
      onReset: _resetLocalWorkspace,
      onQuit: _confirmQuit,
      onRetry: lifecycle.retryConnection,
      onExportDiagnostics: _exportDiagnostics,
      onChangeWorkRoot: _changeWorkRoot,
      onReadinessCheck: lifecycle.checkWorkerReadiness,
      workerRevision: _workerRevision,
      localWorkerRegistry: lifecycle.host.localWorkerRegistry,
      credentialStore: lifecycle.host.credentialStore,
      adapterPackageStore: lifecycle.host.adapterPackageStore,
      ensureAdapter: _ensureAdapterAvailable,
      signedIn: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final lifecycle = widget.lifecycle;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Conclave Workspace',
      debugShowCheckedModeBanner: false,
      theme: ConclaveBrand.lightTheme(),
      darkTheme: ConclaveBrand.darkTheme(),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 400, minHeight: 600),
          child: lifecycle.hidden
              ? const Center(
                  child: Text('Workspace is running in the background.'))
              : WorkspaceShellRouter(
                  snapshot: lifecycle.uiSnapshot,
                  credentialStore: lifecycle.host.credentialStore,
                  cloudUrl: lifecycle.uiSnapshot.cloudUrl ??
                      conclaveProductionCloudUrl,
                  refreshToken: _workerRevision,
                  restoreSession: _restoreDesktopSession,
                  onSignIn: _signInDesktopHuman,
                  onConnectWorkspace: () => _connectWorkspace(),
                  onSignOut: _signOutDesktopHuman,
                  onRelease: _releaseWorkspaceOwnership,
                  onQuit: _confirmQuit,
                  onManagementAuthRequiredChanged:
                      lifecycle.updateManagementAuthRequired,
                  managementShellBuilder: _buildManagementDashboard,
                ),
        ),
      ),
    );
  }
}

class _ShellAccess {
  const _ShellAccess(
    this.humanAuth, {
    this.session,
    this.signInRequired = false,
  });

  final HumanAuthState humanAuth;
  final DesktopHumanSession? session;
  final bool signInRequired;
}

/// Selects a shell only after validating the desktop management session.
/// The runtime is owned by [HostLifecycleController] and keeps running while
/// this widget checks or changes the management surface.
class WorkspaceShellRouter extends StatefulWidget {
  const WorkspaceShellRouter({
    required this.snapshot,
    required this.credentialStore,
    required this.cloudUrl,
    required this.refreshToken,
    required this.restoreSession,
    required this.onSignIn,
    required this.onConnectWorkspace,
    required this.onSignOut,
    this.onRelease,
    required this.onQuit,
    this.onRetry,
    this.onManagementAuthRequiredChanged,
    required this.managementShellBuilder,
    super.key,
  });

  final HostUiSnapshot snapshot;
  final SecureCredentialStore credentialStore;
  final String cloudUrl;
  final int refreshToken;
  final Future<DesktopHumanSession?> Function(DesktopHumanSession session)
      restoreSession;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onConnectWorkspace;
  final Future<void> Function() onSignOut;
  final Future<void> Function()? onRelease;
  final Future<void> Function() onQuit;
  final Future<void> Function()? onRetry;
  final ValueChanged<bool>? onManagementAuthRequiredChanged;
  final Widget Function() managementShellBuilder;

  @override
  State<WorkspaceShellRouter> createState() => _WorkspaceShellRouterState();
}

enum _HeaderMenuAction {
  openConclaveAX,
  checkForUpdates,
  about,
  signOut,
}

class _WorkspaceShellRouterState extends State<WorkspaceShellRouter> {
  late Future<_ShellAccess> _access;

  @override
  void initState() {
    super.initState();
    _access = _loadAccess();
  }

  @override
  void didUpdateWidget(covariant WorkspaceShellRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      _access = _loadAccess();
    }
  }

  Future<_ShellAccess> _loadAccess() async {
    final access = await _resolveAccess();
    widget.onManagementAuthRequiredChanged?.call(
      access.humanAuth == HumanAuthState.reauthRequired,
    );
    return access;
  }

  Future<_ShellAccess> _resolveAccess() async {
    final runtimeIntendedConnected = widget.snapshot.cloudConnected ||
        widget.snapshot.desiredRuntimeConnected;
    _ShellAccess invalidSession([DesktopHumanSession? session]) => _ShellAccess(
          runtimeIntendedConnected
              ? HumanAuthState.reauthRequired
              : HumanAuthState.signedOut,
          session: session,
          signInRequired: true,
        );

    final stored = await widget.credentialStore.read(desktopHumanCredentialKey);
    if (stored == null || stored.isEmpty) {
      return _ShellAccess(
        widget.snapshot.paired && runtimeIntendedConnected
            ? HumanAuthState.reauthRequired
            : HumanAuthState.signedOut,
      );
    }

    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) throw const FormatException('Invalid session data');
      final credential = decoded['credential'];
      final sessionId = decoded['sessionId'];
      final userId = decoded['userId'];
      final displayName = decoded['displayName'];
      final email = decoded['email'];
      final expiresAt =
          DateTime.tryParse(decoded['expiresAt']?.toString() ?? '');
      final issuedAt = DateTime.tryParse(decoded['issuedAt']?.toString() ?? '');
      if (credential is! String ||
          sessionId is! String ||
          userId is! String ||
          displayName is! String ||
          email is! String ||
          expiresAt == null) {
        throw const FormatException('Invalid session identity');
      }
      final session = DesktopHumanSession(
        credential: credential,
        sessionId: sessionId,
        userId: userId,
        displayName: displayName,
        email: email,
        expiresAt: expiresAt,
        issuedAt: issuedAt,
      );
      if (!expiresAt.isAfter(DateTime.now().toUtc())) {
        return invalidSession(session);
      }
      final ownerUserId = widget.snapshot.ownerUserId;
      if (widget.snapshot.paired &&
          (ownerUserId == null || ownerUserId != session.userId)) {
        return _ShellAccess(
          HumanAuthState.reauthRequired,
          session: session,
        );
      }
      final restored = await widget.restoreSession(session);
      if (restored == null ||
          restored.sessionId != session.sessionId ||
          restored.userId != session.userId) {
        return invalidSession(session);
      }
      if (restored.credential != session.credential) {
        await widget.credentialStore.write(
          desktopHumanCredentialKey,
          jsonEncode(restored.toSecureJson()),
        );
      }
      return _ShellAccess(HumanAuthState.signedIn, session: restored);
    } on Object {
      return runtimeIntendedConnected
          ? _ShellAccess(HumanAuthState.reauthRequired)
          : _ShellAccess(HumanAuthState.signedOut, signInRequired: true);
    }
  }

  WorkspaceLifecycleState _lifecycleState(HumanAuthState humanAuth) {
    final snapshot = widget.snapshot;
    final stage = snapshot.connectionStage;
    final connecting = snapshot.mode == HostUiMode.starting ||
        stage == HostConnectionStage.validating ||
        stage == HostConnectionStage.connecting ||
        stage == HostConnectionStage.authenticating ||
        stage == HostConnectionStage.synchronizing ||
        stage == HostConnectionStage.reconnecting ||
        stage == HostConnectionStage.switchingToWebSocket;
    final participation = snapshot.cloudConnected
        ? WorkspaceParticipationState.connected
        : snapshot.desiredRuntimeConnected && connecting
            ? WorkspaceParticipationState.connecting
            : WorkspaceParticipationState.disconnected;
    return WorkspaceLifecycleState(
      humanAuth: humanAuth,
      participation: participation,
      managementLock: ManagementLockState.unlocked,
      desiredRuntime: snapshot.desiredRuntimeConnected
          ? DesiredRuntimeState.connected
          : DesiredRuntimeState.disconnected,
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Conclave Workspace',
      applicationVersion: 'v${widget.snapshot.appVersion}',
      applicationIcon: ConclaveBrand.logoMark(size: 40),
      children: const [
        Text('Conclave Workspace Runtime and Local Worker Manager.'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_ShellAccess>(
        future: _access,
        builder: (context, result) {
          final access = result.data;
          if (access == null) {
            return const _MinimalShell(
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final lifecycle = _lifecycleState(access.humanAuth);
          switch (lifecycle.humanAuth) {
            case HumanAuthState.signedOut:
              return _MinimalShell(
                onAbout: _showAbout,
                onRetry: widget.onRetry,
                child: _SignedOutShell(
                  onSignIn: widget.onSignIn,
                  signInRequired: access.signInRequired,
                ),
              );
            case HumanAuthState.reauthRequired:
              return _MinimalShell(
                onAbout: _showAbout,
                onRetry: widget.onRetry,
                child: _ReauthRequiredShell(
                  runtimeConnected: widget.snapshot.cloudConnected,
                  onSignIn: widget.onSignIn,
                ),
              );
            case HumanAuthState.signedIn:
              return widget.managementShellBuilder();
          }
        },
      );
}

class _MinimalShell extends StatelessWidget {
  const _MinimalShell({
    required this.child,
    this.onAbout,
    this.onRetry,
  });

  final Widget child;
  final VoidCallback? onAbout;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(children: [
            ConclaveBrand.logoMark(size: 26),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Conclave Workspace',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<_HeaderMenuAction>(
              icon: const Icon(Icons.menu, size: 20),
              tooltip: 'Menu',
              constraints: const BoxConstraints(minWidth: 200),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              onSelected: (action) {
                switch (action) {
                  case _HeaderMenuAction.openConclaveAX:
                    HostLifecycleController.openAX();
                    break;
                  case _HeaderMenuAction.checkForUpdates:
                    onRetry?.call();
                    break;
                  case _HeaderMenuAction.about:
                    onAbout?.call();
                    break;
                  case _HeaderMenuAction.signOut:
                    break;
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _HeaderMenuAction.openConclaveAX,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.open_in_new, size: 16),
                      SizedBox(width: 10),
                      Text('Open Conclave AX'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: _HeaderMenuAction.checkForUpdates,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.system_update_alt, size: 16),
                      SizedBox(width: 10),
                      Text('Check for Updates'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: _HeaderMenuAction.about,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.info_outline, size: 16),
                      SizedBox(width: 10),
                      Text('About'),
                    ],
                  ),
                ),
              ],
            ),
          ]),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _SignedOutShell extends StatelessWidget {
  const _SignedOutShell({required this.onSignIn, this.signInRequired = false});

  final Future<void> Function() onSignIn;
  final bool signInRequired;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ConclaveBrand.logoMark(size: 48),
                const SizedBox(height: 18),
                Text(
                    signInRequired
                        ? 'Sign in required'
                        : 'Sign in to Conclave Workspace',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                const Text(
                  'Sign in with your Conclave account to manage this computer.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => unawaited(onSignIn()),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _ReauthRequiredShell extends StatelessWidget {
  const _ReauthRequiredShell({
    required this.runtimeConnected,
    required this.onSignIn,
  });

  final bool runtimeConnected;
  final Future<void> Function() onSignIn;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline, size: 42),
                const SizedBox(height: 16),
                Text('Sign in again to manage Workspace',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text(runtimeConnected
                    ? 'The runtime remains connected. Sign in as the Workspace owner to manage it.'
                    : 'Sign in as the Workspace owner to continue managing this computer.'),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => unawaited(onSignIn()),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
              ]),
            ),
          ),
        ),
      );
}

class HostDashboard extends StatefulWidget {
  const HostDashboard({
    required this.snapshot,
    this.onSignIn,
    this.onSignOut,
    this.onConnect,
    this.onRegister,
    this.onRecoverCredential,
    this.onChangeWorkspaceName,
    this.onDisconnect,
    this.onRelease,
    this.onReset,
    this.onAccountAction,
    this.launchAtLogin = false,
    this.onLaunchAtLoginChanged,
    this.requireStepUp,
    this.onQuit,
    this.onRetry,
    this.onExportDiagnostics,
    this.onChangeWorkRoot,
    this.onReadinessCheck,
    this.workerRevision = 0,
    this.localWorkerRegistry,
    this.credentialStore = const PlatformSecureCredentialStore(),
    this.adapterPackageStore,
    this.ensureAdapter,
    this.signedIn = false,
    super.key,
  });

  final HostUiSnapshot snapshot;
  final Future<void> Function()? onSignIn;
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onConnect;
  final Future<void> Function([String? name])? onRegister;
  final Future<void> Function([String? name])? onRecoverCredential;
  final Future<void> Function(String name)? onChangeWorkspaceName;
  final VoidCallback? onDisconnect;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final VoidCallback? onAccountAction;
  final bool launchAtLogin;
  final ValueChanged<bool>? onLaunchAtLoginChanged;
  final LocalConfiguredWorkerRegistry? localWorkerRegistry;
  final Future<bool> Function(String reason)? requireStepUp;
  final VoidCallback? onQuit;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;
  final int workerRevision;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final bool signedIn;

  @override
  State<HostDashboard> createState() => _HostDashboardState();
}

enum HostSurface { workspace, workers }

class _HostDashboardState extends State<HostDashboard> {
  HostSurface _selectedSurface = HostSurface.workspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = widget.snapshot;
    final effectiveSignedIn = widget.signedIn ||
        _hasValidCachedDesktopSession(widget.credentialStore);
    final userEmail = effectiveSignedIn
        ? _readUserEmailFromCredentialStore(widget.credentialStore)
        : null;

    final isConnected = snapshot.cloudConnected;
    final stage = snapshot.connectionStage;
    final isConnecting = snapshot.mode == HostUiMode.starting ||
        stage == HostConnectionStage.validating ||
        stage == HostConnectionStage.connecting ||
        stage == HostConnectionStage.authenticating ||
        stage == HostConnectionStage.synchronizing ||
        stage == HostConnectionStage.reconnecting;
    final connectionLabel =
        snapshot.activeTransportMode == 'switching_to_websocket' ||
                stage == HostConnectionStage.switchingToWebSocket
            ? 'Switching to WebSocket…'
            : isConnected
                ? switch (snapshot.activeTransportMode) {
                    'websocket' => 'Connected · WebSocket',
                    'http_long_poll' => 'Connected · HTTPS fallback',
                    'switching_to_websocket' => 'Switching to WebSocket…',
                    _ => 'Connected',
                  }
                : isConnecting
                    ? (stage == HostConnectionStage.reconnecting
                        ? 'Reconnecting...'
                        : 'Connecting...')
                    : 'Offline';

    return Column(
      children: [
        // App Header Bar
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    ConclaveBrand.logoMark(size: 26),
                    const SizedBox(width: 12),
                    const Text(
                      'Conclave Workspace',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isConnected ? Colors.green : Colors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        connectionLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isConnected
                              ? (theme.brightness == Brightness.dark
                                  ? Colors.greenAccent
                                  : Colors.green.shade700)
                              : Colors.orange.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (userEmail != null && userEmail.isNotEmpty) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    userEmail,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              PopupMenuButton<_HeaderMenuAction>(
                icon: const Icon(Icons.menu, size: 20),
                tooltip: 'Menu',
                constraints: const BoxConstraints(minWidth: 200),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                onSelected: (action) {
                  switch (action) {
                    case _HeaderMenuAction.openConclaveAX:
                      HostLifecycleController.openAX();
                      break;
                    case _HeaderMenuAction.checkForUpdates:
                      widget.onRetry?.call();
                      break;
                    case _HeaderMenuAction.about:
                      showAboutDialog(
                        context: context,
                        applicationName: 'Conclave Workspace',
                        applicationVersion: 'v${snapshot.appVersion}',
                        applicationIcon: ConclaveBrand.logoMark(size: 40),
                        children: const [
                          Text(
                            'Conclave Workspace Runtime and Local Worker Manager.',
                          ),
                        ],
                      );
                      break;
                    case _HeaderMenuAction.signOut:
                      widget.onSignOut?.call();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _HeaderMenuAction.openConclaveAX,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.open_in_new, size: 16),
                        SizedBox(width: 10),
                        Text('Open Conclave AX'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _HeaderMenuAction.checkForUpdates,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.system_update_alt, size: 16),
                        SizedBox(width: 10),
                        Text('Check for Updates'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: _HeaderMenuAction.about,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline, size: 16),
                        SizedBox(width: 10),
                        Text('About'),
                      ],
                    ),
                  ),
                  if (effectiveSignedIn && widget.onSignOut != null) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: _HeaderMenuAction.signOut,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.logout, size: 16),
                          SizedBox(width: 10),
                          Text('Sign out'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        // Two-Surface Horizontal Tab Switcher
        if (snapshot.workspaceReady || effectiveSignedIn)
          Container(
            width: double.infinity,
            color: theme.colorScheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SurfaceTabButton(
                  icon: Icons.computer_outlined,
                  selectedIcon: Icons.computer,
                  label: 'Workspace',
                  selected: _selectedSurface == HostSurface.workspace,
                  onTap: () =>
                      setState(() => _selectedSurface = HostSurface.workspace),
                ),
                const SizedBox(width: 16),
                _SurfaceTabButton(
                  icon: Icons.memory_outlined,
                  selectedIcon: Icons.memory,
                  label: 'Workers',
                  selected: _selectedSurface == HostSurface.workers,
                  onTap: () =>
                      setState(() => _selectedSurface = HostSurface.workers),
                ),
              ],
            ),
          ),

        // Content Area
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: IndexedStack(
                index: _selectedSurface.index,
                children: [
                  _WorkspaceTab(
                    snapshot: snapshot,
                    signedIn: effectiveSignedIn,
                    credentialStore: widget.credentialStore,
                    localWorkerRegistry: widget.localWorkerRegistry,
                    adapterPackageStore: widget.adapterPackageStore,
                    onConnect: widget.onConnect,
                    onRegister: widget.onRegister,
                    onRecoverCredential: widget.onRecoverCredential,
                    onChangeWorkspaceName: widget.onChangeWorkspaceName,
                    onRetry: widget.onRetry,
                    onExportDiagnostics: widget.onExportDiagnostics,
                    onChangeWorkRoot: widget.onChangeWorkRoot,
                    launchAtLogin: widget.launchAtLogin,
                    onLaunchAtLoginChanged: widget.onLaunchAtLoginChanged,
                    onDisconnect:
                        snapshot.workspaceReady ? widget.onDisconnect : null,
                    onRelease: widget.onRelease,
                    onReset: widget.onReset,
                  ),
                  _WorkersTab(
                    key: ValueKey(widget.workerRevision),
                    registry: widget.localWorkerRegistry,
                    adapterPackageStore: widget.adapterPackageStore,
                    ensureAdapter: widget.ensureAdapter,
                    onReadinessCheck: widget.onReadinessCheck,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SurfaceTabButton extends StatelessWidget {
  const _SurfaceTabButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? activeColor : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? selectedIcon : icon,
              size: 18,
              color:
                  selected ? activeColor : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color:
                    selected ? activeColor : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceTab extends StatefulWidget {
  const _WorkspaceTab({
    required this.snapshot,
    this.signedIn = false,
    this.onConnect,
    this.onRegister,
    this.onRecoverCredential,
    this.onChangeWorkspaceName,
    required this.credentialStore,
    this.localWorkerRegistry,
    this.adapterPackageStore,
    this.onRetry,
    this.onExportDiagnostics,
    this.onChangeWorkRoot,
    this.onDisconnect,
    this.onRelease,
    this.onReset,
    this.launchAtLogin = false,
    this.onLaunchAtLoginChanged,
  });

  final HostUiSnapshot snapshot;
  final bool signedIn;
  final Future<void> Function()? onConnect;
  final Future<void> Function([String? name])? onRegister;
  final Future<void> Function([String? name])? onRecoverCredential;
  final Future<void> Function(String name)? onChangeWorkspaceName;
  final SecureCredentialStore credentialStore;
  final LocalConfiguredWorkerRegistry? localWorkerRegistry;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final VoidCallback? onDisconnect;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final bool launchAtLogin;
  final ValueChanged<bool>? onLaunchAtLoginChanged;

  @override
  State<_WorkspaceTab> createState() => _WorkspaceTabState();
}

class _WorkspaceTabState extends State<_WorkspaceTab> {
  late final TextEditingController _nameController;
  late final TextEditingController _workRootController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.snapshot.workspaceName ??
          widget.snapshot.hostname ??
          'Conclave Workspace',
    );
    _workRootController = TextEditingController(
      text: widget.snapshot.workRootPath ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _WorkspaceTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldName = oldWidget.snapshot.workspaceName ??
        oldWidget.snapshot.hostname ??
        'Conclave Workspace';
    final newName = widget.snapshot.workspaceName ??
        widget.snapshot.hostname ??
        'Conclave Workspace';
    if (oldName != newName && widget.snapshot.workspaceReady) {
      _nameController.text = newName;
    }
    if (oldWidget.snapshot.workRootPath != widget.snapshot.workRootPath) {
      _workRootController.text = widget.snapshot.workRootPath ?? '';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _workRootController.dispose();
    super.dispose();
  }

  Future<void> _browseWorkRoot() async {
    final selected = await HostLifecycleController.chooseDirectory(
      initialPath: widget.snapshot.workRootPath,
    );
    if (selected != null && selected.isNotEmpty) {
      if (widget.onChangeWorkRoot != null) {
        await widget.onChangeWorkRoot!(selected);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveSignedIn = widget.signedIn ||
        _hasValidCachedDesktopSession(widget.credentialStore);
    final isRegistered = widget.snapshot.paired ||
        (widget.snapshot.workspaceId != null &&
            widget.snapshot.workspaceId!.isNotEmpty);
    final stage = widget.snapshot.connectionStage;
    final isConnecting = widget.snapshot.mode == HostUiMode.starting ||
        stage == HostConnectionStage.validating ||
        stage == HostConnectionStage.connecting ||
        stage == HostConnectionStage.authenticating ||
        stage == HostConnectionStage.synchronizing ||
        stage == HostConnectionStage.reconnecting;
    final isError = (widget.snapshot.mode == HostUiMode.offline ||
            widget.snapshot.mode == HostUiMode.installFailure) &&
        !isConnecting &&
        widget.snapshot.desiredRuntimeConnected;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (isError) ...[
          _HostRecoveryPanel(
            issue: widget.snapshot.issue,
            retryLabel: widget.snapshot.mode == HostUiMode.offline
                ? 'Retry connection'
                : 'Retry update',
            onRetry: widget.onRetry,
          ),
          const SizedBox(height: 24),
        ],
        TextField(
          controller: _nameController,
          enabled: !isRegistered,
          readOnly: isRegistered,
          maxLength: 200,
          onChanged: widget.onChangeWorkspaceName,
          decoration: const InputDecoration(
            labelText: 'Workspace name',
            border: OutlineInputBorder(),
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _workRootController,
          enabled: !widget.snapshot.workspaceReady,
          readOnly: true,
          decoration: InputDecoration(
            labelText: 'Work Root',
            hintText: 'Not configured',
            border: const OutlineInputBorder(),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton.icon(
                onPressed:
                    widget.snapshot.workspaceReady ? null : _browseWorkRoot,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Browse'),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: widget.launchAtLogin,
          onChanged: widget.onLaunchAtLoginChanged,
          title: const Text('Start at login'),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            // Button 1: Connect / Disconnect
            if (widget.snapshot.workspaceReady ||
                widget.snapshot.cloudConnected)
              FilledButton.icon(
                onPressed: widget.onDisconnect,
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Disconnect'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              )
            else
              FilledButton.icon(
                onPressed: (!isRegistered || isConnecting)
                    ? null
                    : () {
                        if (widget.onConnect != null) {
                          unawaited(widget.onConnect!());
                        } else if (widget.onRecoverCredential != null) {
                          unawaited(widget.onRecoverCredential!(
                            _nameController.text.trim(),
                          ));
                        }
                      },
                icon: isConnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.sync, size: 16),
                label: Text(
                  isConnecting ? 'Connecting…' : 'Connect',
                ),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),

            // Button 2: Register / Release
            if (isRegistered)
              OutlinedButton.icon(
                onPressed: widget.onRelease != null
                    ? () => unawaited(widget.onRelease!())
                    : null,
                icon: const Icon(Icons.person_remove_outlined, size: 16),
                label: const Text('Release'),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              )
            else
              FilledButton.icon(
                onPressed: (isConnecting || !effectiveSignedIn)
                    ? null
                    : () {
                        if (widget.onRegister != null) {
                          unawaited(widget.onRegister!(
                            _nameController.text.trim(),
                          ));
                        } else if (widget.onRecoverCredential != null) {
                          unawaited(widget.onRecoverCredential!(
                            _nameController.text.trim(),
                          ));
                        }
                      },
                icon: const Icon(Icons.app_registration, size: 16),
                label: const Text('Register'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),

            // Button 3: Reset
            if (widget.onReset != null)
              OutlinedButton.icon(
                onPressed: widget.onReset,
                icon: Icon(Icons.delete_forever_outlined,
                    size: 16, color: theme.colorScheme.error),
                label: Text('Reset',
                    style: TextStyle(color: theme.colorScheme.error)),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  side: BorderSide(
                      color: theme.colorScheme.error.withValues(alpha: 0.5)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        _WorkspaceDiagnosticsSection(
          snapshot: widget.snapshot,
          onExportDiagnostics: widget.onExportDiagnostics,
          workerRegistry: widget.localWorkerRegistry,
          adapterPackageStore: widget.adapterPackageStore,
        ),
      ],
    );
  }
}

class _WorkspaceDiagnosticsSection extends StatelessWidget {
  const _WorkspaceDiagnosticsSection({
    required this.snapshot,
    this.onExportDiagnostics,
    this.workerRegistry,
    this.adapterPackageStore,
  });

  final HostUiSnapshot snapshot;
  final Future<void> Function()? onExportDiagnostics;
  final LocalConfiguredWorkerRegistry? workerRegistry;
  final V7AdapterPackageStore? adapterPackageStore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.analytics_outlined, size: 20),
          title: const Text(
            'Advanced Diagnostics',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            const Divider(height: 16),
            // Connection
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Connection',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Gateway state',
              value: snapshot.cloudConnected
                  ? switch (snapshot.activeTransportMode) {
                      'websocket' => 'Connected · WebSocket',
                      'http_long_poll' => 'Connected · HTTPS fallback',
                      'switching_to_websocket' => 'Switching to WebSocket',
                      _ => 'Connected',
                    }
                  : 'Disconnected',
            ),
            if (snapshot.cloudConnected &&
                snapshot.activeTransportMode == 'http_long_poll')
              const _DetailRow(
                label: 'Fallback status',
                value: 'WebSocket is unavailable. Work can continue.',
              ),
            if (snapshot.fallbackHealthStatus != null)
              _DetailRow(
                label: 'HTTPS fallback health',
                value: snapshot.fallbackHealthStatus!,
              ),
            if (snapshot.lastWebSocketFailure != null)
              _DetailRow(
                label: 'Last WSS failure',
                value: snapshot.lastWebSocketHttpStatusCode == null
                    ? snapshot.lastWebSocketFailure!
                    : '${snapshot.lastWebSocketFailure} (HTTP ${snapshot.lastWebSocketHttpStatusCode})',
              ),
            _DetailRow(
              label: 'Gateway URL',
              value: snapshot.cloudUrl ?? 'Not configured',
            ),
            _DetailRow(
              label: 'Connection stage',
              value: snapshot.connectionStage?.name ?? 'Offline',
            ),
            _DetailRow(
              label: 'Runtime credential',
              value: snapshot.runtimeCredentialStatus,
            ),
            _DetailRow(
              label: 'DNS / TLS',
              value: snapshot.dnsTlsStatus ?? 'not checked',
            ),
            _DetailRow(
              label: 'WebSocket upgrade',
              value: snapshot.webSocketUpgradeStatus ?? 'not completed',
            ),
            _DetailRow(
              label: 'Protocol hello',
              value: snapshot.protocolHelloStatus ?? 'not started',
            ),
            _DetailRow(
              label: 'Last attempt',
              value: snapshot.lastConnectionAttemptAt?.toLocal().toString() ??
                  'Never',
            ),
            if (snapshot.connectionError != null)
              _DetailRow(
                label: 'Connection detail',
                value: snapshot.connectionError!,
              ),
            _DetailRow(
              label: 'Session ID',
              value: snapshot.sessionId ?? 'No active session',
            ),
            _DetailRow(
              label: 'Reconnect count',
              value: '${snapshot.reconnectCount}',
            ),
            _DetailRow(
              label: 'Last inventory sync',
              value: snapshot.lastInventorySyncAt != null
                  ? '${snapshot.lastInventorySyncAt!.toLocal()}'
                  : 'Never',
            ),
            _DetailRow(
              label: 'Active assignments',
              value: '${snapshot.activeAssignments}',
            ),
            if (snapshot.activeAssignmentIds.isNotEmpty) ...[
              const SizedBox(height: 4),
              for (final id in snapshot.activeAssignmentIds)
                Padding(
                  padding: const EdgeInsets.only(left: 138, bottom: 2),
                  child: Text(id,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11)),
                ),
            ],
            const SizedBox(height: 12),

            _WorkerPackageDiagnostics(
              registry: workerRegistry,
              adapterPackageStore: adapterPackageStore,
            ),
            const SizedBox(height: 12),

            // Identity
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Identity',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            if (snapshot.installationId != null)
              _CopyableDetailRow(
                label: 'Installation ID',
                value: snapshot.installationId!,
              ),
            _CopyableDetailRow(
              label: 'Workspace ID',
              value: snapshot.workspaceId ?? snapshot.hostId ?? 'Not paired',
            ),
            _CopyableDetailRow(
              label: 'Runtime ID',
              value: snapshot.hostId ?? 'Not assigned',
            ),
            const SizedBox(height: 12),

            // System
            Align(
              alignment: Alignment.centerLeft,
              child: Text('System',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            _CopyableDetailRow(
              label: 'Hostname',
              value: snapshot.hostname ?? Platform.localHostname,
            ),
            _DetailRow(
              label: 'OS',
              value:
                  '${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
            ),
            const SizedBox(height: 12),

            // Logs
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Logs',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: Text(
                    'Logs Path',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    snapshot.logsPath ?? 'Not available',
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
                if (snapshot.logsPath != null)
                  TextButton.icon(
                    onPressed: () =>
                        HostLifecycleController.openPath(snapshot.logsPath!),
                    icon: const Icon(Icons.open_in_new, size: 14),
                    label: const Text('Open Log File',
                        style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final uri = Uri.tryParse(snapshot.cloudUrl ?? '');
                    final origin = uri == null
                        ? 'Not configured'
                        : Uri(
                            scheme: uri.scheme == 'wss'
                                ? 'https'
                                : uri.scheme == 'ws'
                                    ? 'http'
                                    : uri.scheme,
                            host: uri.host,
                            port: uri.hasPort ? uri.port : null,
                          ).toString();
                    final report = [
                      'Cloud origin: $origin',
                      'WebSocket endpoint: ${uri == null ? 'Not configured' : Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path)}',
                      'Workspace runtime ID: ${snapshot.hostId ?? 'Not assigned'}',
                      'Runtime credential: ${snapshot.runtimeCredentialAvailable ? 'available locally (value withheld)' : snapshot.desiredRuntimeConnected ? 'missing from secure storage (runtime desired connected)' : 'not present (runtime desired disconnected; expected)'}',
                      'DNS/TLS: ${snapshot.dnsTlsStatus ?? 'not checked'}',
                      'WebSocket upgrade: ${snapshot.webSocketUpgradeStatus ?? 'not completed'}',
                      'Active transport: ${snapshot.activeTransportMode ?? 'offline'}',
                      'HTTPS fallback health: ${snapshot.fallbackHealthStatus ?? 'not configured'}',
                      'Last WSS failure: ${snapshot.lastWebSocketFailure ?? 'none'}${snapshot.lastWebSocketHttpStatusCode == null ? '' : ' (HTTP ${snapshot.lastWebSocketHttpStatusCode})'}',
                      'Last WSS failure at: ${snapshot.lastWebSocketFailureAt?.toUtc().toIso8601String() ?? 'never'}',
                      'Protocol hello: ${snapshot.protocolHelloStatus ?? 'not started'}',
                      'Connection stage: ${snapshot.connectionStage?.name ?? 'offline'}',
                      'HTTP status: ${snapshot.connectionHttpStatus ?? 'none'}',
                      'Last attempt: ${snapshot.lastConnectionAttemptAt?.toUtc().toIso8601String() ?? 'never'}',
                      'Last error: ${snapshot.connectionError ?? 'none'}',
                    ].join('\n');
                    await Clipboard.setData(ClipboardData(text: report));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Connection diagnostics copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy connection details'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onExportDiagnostics,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('Export Report'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkerPackageDiagnostics extends StatefulWidget {
  const _WorkerPackageDiagnostics({
    required this.registry,
    required this.adapterPackageStore,
  });

  final LocalConfiguredWorkerRegistry? registry;
  final V7AdapterPackageStore? adapterPackageStore;

  @override
  State<_WorkerPackageDiagnostics> createState() =>
      _WorkerPackageDiagnosticsState();
}

class _WorkerPackageDiagnosticsState extends State<_WorkerPackageDiagnostics> {
  Future<List<({LocalConfiguredWorker worker, Map<String, Object?>? package})>>?
      _details;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _WorkerPackageDiagnostics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry ||
        oldWidget.adapterPackageStore != widget.adapterPackageStore) {
      _load();
    }
  }

  void _load() {
    _details = _readDetails();
  }

  Future<List<({LocalConfiguredWorker worker, Map<String, Object?>? package})>>
      _readDetails() async {
    final registry = widget.registry;
    if (registry == null) return const [];
    final workers = await registry.list(includeRemoved: true);
    return Future.wait(workers.map((worker) async {
      Map<String, Object?>? package;
      try {
        package =
            await widget.adapterPackageStore?.activeManifestSummary(worker);
      } on Object {
        // Package admission failures are useful here and remain local.
      }
      return (worker: worker, package: package);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Worker Packages',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        FutureBuilder<
            List<
                ({
                  LocalConfiguredWorker worker,
                  Map<String, Object?>? package
                })>>(
          future: _details,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              );
            }
            final records = snapshot.data ?? const [];
            if (records.isEmpty) {
              return Text(
                widget.registry == null
                    ? 'Local Worker diagnostics are unavailable.'
                    : 'No local Workers are configured.',
                style: theme.textTheme.bodySmall,
              );
            }
            return Column(
              children: [
                for (final record in records)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(record.worker.name),
                    subtitle: Text(
                      '${FirstPartyWorkerPackage.forProductWorkerTypeId(record.worker.workerTypeId)?.packageId ?? record.worker.workerTypeId} · ${record.package?['adapterVersion'] ?? 'Package unavailable'}',
                    ),
                    children: [
                      _DetailRow(
                        label: 'Package ID',
                        value: FirstPartyWorkerPackage.forProductWorkerTypeId(
                              record.worker.workerTypeId,
                            )?.packageId ??
                            record.worker.workerTypeId,
                      ),
                      _DetailRow(
                        label: 'CLI version',
                        value: record.worker.toolVersion ?? 'Not detected',
                      ),
                      _DetailRow(
                        label: 'Readiness',
                        value:
                            '${record.worker.readinessState.wireValue}${record.worker.readinessIssueCode == null ? '' : ' · ${record.worker.readinessIssueCode}'}',
                      ),
                      _DetailRow(
                        label: 'Publisher',
                        value:
                            '${record.package?['publisher'] ?? 'Unavailable'}',
                      ),
                      _DetailRow(
                        label: 'Signing key',
                        value:
                            '${record.package?['signingKeyId'] ?? 'Unavailable'}',
                      ),
                      _DetailRow(
                        label: 'Signature verified',
                        value:
                            '${record.package?['signatureVerified'] ?? false}',
                      ),
                      _DetailRow(
                        label: 'Release channel',
                        value:
                            '${record.package?['releaseChannel'] ?? 'Unavailable'}',
                      ),
                      _DetailRow(
                        label: 'Last Test',
                        value: _lastLiveTestLabel(record.worker),
                      ),
                      if (record.worker.lastLiveTestDetails != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 138, bottom: 8),
                          child: CopyableMessageText(
                            record.worker.lastLiveTestDetails!,
                            style: theme.textTheme.bodySmall,
                            tooltip: 'Copy Worker diagnostic',
                          ),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.registry,
    required this.adapterPackageStore,
    this.ensureAdapter,
    this.onReadinessCheck,
    super.key,
  });

  final LocalConfiguredWorkerRegistry? registry;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  Future<List<LocalConfiguredWorker>>? _workers;
  final Set<String> _updatingWorkerTypes = {};

  @override
  void initState() {
    super.initState();
    _loadWorkers();
  }

  @override
  void didUpdateWidget(covariant _WorkersTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) _loadWorkers();
  }

  void _loadWorkers() {
    _workers = widget.registry?.list();
  }

  Future<void> _setDisabled(LocalConfiguredWorker worker, bool disabled) async {
    final registry = widget.registry;
    if (registry == null) return;
    await registry.update(
      worker.id,
      (current) => current.copyWith(
        status: disabled
            ? LocalWorkerStatus.disabled
            : LocalWorkerStatus.needsAttention,
      ),
    );
    if (!disabled) {
      await widget.onReadinessCheck?.call(workerTypeId: worker.workerTypeId);
    }
    if (mounted) setState(_loadWorkers);
  }

  Future<void> _configureOrTest(
    FirstPartyWorkerPackage entry,
    LocalConfiguredWorker? worker,
  ) async {
    if (!_updatingWorkerTypes.add(entry.productWorkerTypeId)) return;
    setState(() {});
    try {
      final registry = widget.registry;
      if (registry == null) return;
      if (worker != null) {
        await registry.update(
          worker.id,
          (current) => current.copyWith(
            status: LocalWorkerStatus.needsAttention,
          ),
        );
      } else {
        final store = widget.adapterPackageStore;
        final packageReady = await store?.hasVerifiedActivePackage(
              entry.packageId,
              firstPartyWorkerLocalPermissions,
            ) ??
            false;
        if (!packageReady && widget.ensureAdapter != null) {
          await widget.ensureAdapter!(entry.packageId);
        }
        await LocalWorkerSetupService(registry: registry).create(
          type: entry,
          permissions: firstPartyWorkerLocalPermissions,
        );
      }
      await widget.onReadinessCheck?.call(
        mode: LocalWorkerProbeMode.live,
        workerTypeId: entry.productWorkerTypeId,
      );
      if (mounted) setState(_loadWorkers);
    } on Object {
      if (!mounted) return;
      showCopyableErrorSnackBar(
        context,
        'Could not finish setting up ${entry.productName}. Check Advanced Diagnostics for details.',
      );
    } finally {
      _updatingWorkerTypes.remove(entry.productWorkerTypeId);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Worker Packages check their provider tools and report readiness to Workspace.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        FutureBuilder<List<LocalConfiguredWorker>>(
          future: _workers,
          builder: (context, snapshot) {
            final records = snapshot.data ?? const <LocalConfiguredWorker>[];
            final canConfigure = widget.registry != null && snapshot.hasData;
            return Column(
              children: [
                for (final entry in FirstPartyWorkerPackage.all)
                  Builder(builder: (context) {
                    final worker = records
                        .where((record) =>
                            record.workerTypeId == entry.productWorkerTypeId)
                        .firstOrNull;
                    final pending = _updatingWorkerTypes
                        .contains(entry.productWorkerTypeId);
                    final status = pending
                        ? 'Checking…'
                        : snapshot.hasError
                            ? 'Needs attention'
                            : !snapshot.hasData
                                ? 'Checking…'
                                : worker == null
                                    ? 'Setup required'
                                    : deriveLocalWorkerHealth(worker);
                    return Card(
                      key: Key('worker-catalog-${entry.productWorkerTypeId}'),
                      margin: const EdgeInsets.only(bottom: 12),
                      color: theme.colorScheme.surfaceContainerLow,
                      child: ListTile(
                        leading: Icon(
                          _workerTypeIcon(entry.productWorkerTypeId),
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(entry.productName,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                _CatalogStatusBadge(label: status),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                'CLI version: ${worker?.toolVersion ?? 'Not detected'}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                'Last Test: ${_lastLiveTestLabel(worker)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                        trailing: pending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : worker == null
                                ? TextButton(
                                    onPressed: canConfigure
                                        ? () => _configureOrTest(entry, null)
                                        : null,
                                    child: const Text('Configure'),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: canConfigure
                                            ? () =>
                                                _configureOrTest(entry, worker)
                                            : null,
                                        child: const Text('Test'),
                                      ),
                                      Switch(
                                        value: worker.status !=
                                            LocalWorkerStatus.disabled,
                                        onChanged: canConfigure
                                            ? (enabled) => enabled
                                                ? _configureOrTest(
                                                    entry, worker)
                                                : _setDisabled(worker, true)
                                            : null,
                                      ),
                                    ],
                                  ),
                      ),
                    );
                  }),
                if (snapshot.hasError)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: CopyableMessageText(
                      'Worker status could not be loaded: ${snapshot.error}',
                      style: TextStyle(color: theme.colorScheme.error),
                      iconColor: theme.colorScheme.error,
                    ),
                  ),
                if (widget.registry == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: CopyableMessageText(
                      'Local Worker setup is unavailable. Restart Workspace and check Advanced Diagnostics.',
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  static IconData _workerTypeIcon(String id) => switch (id) {
        'chatgpt' => Icons.terminal,
        'gemini' => Icons.auto_awesome,
        _ => Icons.smart_toy_outlined,
      };

  String _lastLiveTestLabel(LocalConfiguredWorker? worker) {
    final testedAt = worker?.lastLiveTestAt;
    if (testedAt == null) return 'Not run';
    final date = DateTime.tryParse(testedAt)?.toLocal();
    final when = date == null ? testedAt : date.toString().split('.').first;
    final result = worker?.lastLiveTestPassed == true ? 'Passed' : 'Failed';
    return '$result · $when';
  }
}

class _CatalogStatusBadge extends StatelessWidget {
  const _CatalogStatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      'Ready' => ConclaveBrand.success,
      'Disabled' => Colors.grey,
      'Setup required' || 'Not installed' => ConclaveBrand.warning,
      _ => ConclaveBrand.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

String deriveLocalWorkerHealth(LocalConfiguredWorker worker) {
  if (worker.status == LocalWorkerStatus.disabled) return 'Disabled';
  final issueCode = worker.lastLiveTestPassed == false
      ? worker.lastLiveTestIssueCode ?? worker.readinessIssueCode
      : worker.readinessIssueCode;
  if (issueCode == 'cli_not_found') return 'Not installed';
  if (worker.status == LocalWorkerStatus.ready) {
    if (worker.workerTypeId == 'gemini' && worker.lastLiveTestPassed != true) {
      return 'Setup required';
    }
    return 'Ready';
  }
  if (issueCode == 'setup_required' ||
      issueCode == 'authentication_required' ||
      worker.readinessState == WorkerReadinessState.setupRequired ||
      worker.readinessState == WorkerReadinessState.signInRequired) {
    return 'Setup required';
  }
  return 'Needs attention';
}

String _lastLiveTestLabel(LocalConfiguredWorker? worker) {
  final testedAt = worker?.lastLiveTestAt;
  if (testedAt == null) return 'Not run';
  final date = DateTime.tryParse(testedAt)?.toLocal();
  final when = date == null ? testedAt : date.toString().split('.').first;
  final result = worker?.lastLiveTestPassed == true ? 'Passed' : 'Failed';
  return '$result · $when';
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableDetailRow extends StatelessWidget {
  const _CopyableDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 14),
            tooltip: 'Copy $label',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('$label copied to clipboard'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _HostRecoveryPanel extends StatelessWidget {
  const _HostRecoveryPanel({
    this.issue,
    required this.retryLabel,
    this.onRetry,
  });

  final String? issue;
  final String retryLabel;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What happened',
              style: TextStyle(
                  color: colors.onErrorContainer, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          CopyableMessageText(
            issue ?? 'The Workspace needs attention.',
            style: TextStyle(color: colors.onErrorContainer),
            iconColor: colors.onErrorContainer,
            tooltip: 'Copy error message',
          ),
          const SizedBox(height: 8),
          Text(
              'Your work is safe. The Workspace will not discard an assignment.',
              style: TextStyle(color: colors.onErrorContainer)),
          const SizedBox(height: 4),
          Text(
              '$retryLabel is available. Automatic retry depends on the error.',
              style: TextStyle(color: colors.onErrorContainer)),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => unawaited(onRetry!()),
              icon: const Icon(Icons.refresh),
              label: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

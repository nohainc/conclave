import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'adapter_prerequisite.dart';
import 'cloud_connection.dart';
import 'diagnostics.dart';
import 'desktop_auth.dart';
import 'friendly_computer_name.dart';
import 'host.dart';
import 'host_configuration.dart';
import 'local_worker_setup.dart';
import 'secure_credentials.dart';
import 'secure_credentials_flutter.dart';
import 'v7_adapter_package_store.dart';
import 'v7_adapter_catalog.dart';
import 'workspace_enrollment.dart';
import 'workspace_runtime.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_lifecycle.dart';
import 'local_management_authenticator.dart';

void showCopyableErrorSnackBar(BuildContext context, String message) {
  final colors = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 20),
      backgroundColor: colors.error,
      content: Row(
        children: [
          Expanded(child: SelectableText(message)),
          IconButton(
            tooltip: 'Copy error message',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 18),
            color: colors.onError,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Error message copied')),
              );
            },
          ),
        ],
      ),
    ),
  );
}

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

Future<AdapterPrerequisiteResult> _probeLocalWorkerPrerequisite(
    String workerTypeId) async {
  final types =
      LocalWorkerTypeOption.supported.where((type) => type.id == workerTypeId);
  if (types.isEmpty) {
    return const AdapterPrerequisiteResult(
      satisfied: false,
      message: 'Worker Type is unavailable.',
    );
  }
  final prerequisite = types.first.executablePrerequisite;
  if (prerequisite == null) {
    return AdapterPrerequisiteResult(
      satisfied: false,
      message:
          'Required component is not available: ${types.first.prerequisite}.',
    );
  }
  final checks = [prerequisite, ...types.first.additionalPrerequisites];
  for (final check in checks) {
    final result = await probeAdapterExecutable(check);
    if (!result.satisfied) return result;
  }
  return const AdapterPrerequisiteResult(
    satisfied: true,
    message: 'Required local tools are available.',
  );
}

Future<bool> _validateLocalWorkerAuthentication(String workerTypeId) async {
  if (workerTypeId == 'codex') {
    try {
      final result =
          await Process.run('codex', ['login', 'status'], runInShell: false)
              .timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }
  if (workerTypeId == 'antigravity') {
    try {
      final result =
          await Process.run('agy', ['-p', '/usage'], runInShell: false)
              .timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }
  if (workerTypeId == 'claude-code') {
    try {
      final result =
          await Process.run('claude', ['auth', 'status'], runInShell: false)
              .timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }
  return false;
}

Future<List<String>> _validateLocalApiCredential(
  V7AdapterPackageStore? packageStore,
  String workerTypeId,
  String apiKey,
  String endpointUrl,
  List<String> permissions,
) async {
  if (packageStore == null) return const [];
  try {
    return await packageStore.validateApiCredential(
      workerTypeId: workerTypeId,
      apiKey: apiKey,
      endpointUrl: endpointUrl,
      localPermissions: permissions,
    );
  } on Object {
    return const [];
  }
}

Future<void> _launchLocalWorkerAuthentication(String workerTypeId) async {
  if (workerTypeId == 'codex') {
    await Process.start('codex', ['login'],
        runInShell: false, mode: ProcessStartMode.detached);
    return;
  }
  if (workerTypeId == 'antigravity') {
    await Process.start('agy', const [],
        runInShell: false, mode: ProcessStartMode.detached);
    return;
  }
  if (workerTypeId == 'claude-code') {
    await Process.start('claude', ['auth', 'login'],
        runInShell: false, mode: ProcessStartMode.detached);
    return;
  }
  throw StateError('Sign-in setup is not available for this Worker Type yet.');
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
  bool _draining = false;
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
  bool get draining => _draining;

  void updateManagementAuthRequired(bool required) {
    if (_managementAuthRequired == required) return;
    _managementAuthRequired = required;
    _publishMenuStatus();
  }

  Future<void> handleDesktopAction(String action) async {
    switch (action) {
      case 'openWorkspace':
        restore();
        break;
      case 'pause':
        host.cloudConnection?.pauseNewWork();
        _draining = false;
        break;
      case 'resume':
        host.cloudConnection?.resumeNewWork();
        break;
      case 'togglePause':
        final connection = host.cloudConnection;
        if (connection?.acceptingNewWork == true) {
          connection?.pauseNewWork();
        } else if (connection?.isConnected == true) {
          connection?.resumeNewWork();
        }
        break;
      case 'drain':
        final connection = host.cloudConnection;
        if (connection == null) break;
        connection.beginDrain();
        _draining = true;
        notifyListeners();
        while (connection.activeAssignmentCount > 0 && !_quitting) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        _draining = false;
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
      case 'quit':
        final connection = host.cloudConnection;
        if (connection != null && connection.activeAssignmentCount > 0) {
          connection.beginDrain();
          var elapsed = 0;
          while (connection.activeAssignmentCount > 0 &&
              !_quitting &&
              elapsed < 15000) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            elapsed += 250;
          }
          if (connection.activeAssignmentCount > 0) {
            break;
          }
        }
        await quit();
        await _desktopChannel.invokeMethod<void>('terminate');
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
      'draining': _draining,
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
    final workspaceName = registration?.name ?? 'Conclave Workspace';
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
        detail: 'Active local work is being reconciled safely.',
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
      return HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        desiredRuntimeConnected: desiredRuntimeConnected,
        title: 'Connect this Workspace',
        detail: 'Sign in to register this computer with Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        hostId: hostId,
        paired: registration != null,
        ownerUserId: ownerUserId,
        installationId: installationId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Not paired',
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
    final statusLabel = !isConnected
        ? 'Offline'
        : _draining
            ? 'Draining'
            : !(connection?.acceptingNewWork ?? true)
                ? 'Paused'
                : 'Connected';
    final isOffline = !isConnected;

    return HostUiSnapshot(
      mode: isOffline
          ? HostUiMode.offline
          : activeAssignments > 0
              ? HostUiMode.active
              : HostUiMode.ready,
      desiredRuntimeConnected: desiredRuntimeConnected,
      title: isOffline
          ? 'Workspace is offline'
          : activeAssignments > 0
              ? 'Work in progress'
              : 'Workspace is ready',
      detail: isOffline
          ? activeAssignments > 0
              ? 'Cloud is disconnected. Active work remains on this computer while the Workspace retries.'
              : 'The Workspace is registered, but Cloud has not authenticated this connection.'
          : activeAssignments > 0
              ? 'The Workspace is running assigned work.'
              : 'This computer is registered and ready to run assigned work.',
      issue: isOffline
          ? 'No authenticated Cloud session. Recover the Workspace connection from Account.'
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

class _ConclaveHostAppState extends State<ConclaveHostApp> {
  int _workerRevision = 0;
  late bool _managementLocked;
  late final RecentLocalAuthenticationGate _stepUpGate;
  Timer? _autoLockTimer;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _stepUpGate = RecentLocalAuthenticationGate(
      authenticator: widget.localAuthenticator,
    );
    _managementLocked = WorkspaceLifecyclePreferencesStore(
          widget.lifecycle.host.config.dataDirectory,
        ).readSync().managementLockPreference ==
        ManagementLockState.locked;
    unawaited(const MethodChannel('com.conclave.workspace/desktop')
        .invokeMethod<void>('setManagementLocked', _managementLocked)
        .catchError((_) {}));
    widget.lifecycle.addListener(_refresh);
    const desktopChannel = MethodChannel('com.conclave.workspace/desktop');
    desktopChannel.setMethodCallHandler((call) async {
      if (call.method == 'menuAction' && call.arguments is String) {
        final action = call.arguments as String;
        if (action == 'quit') {
          await _confirmQuit();
        } else if (action == 'lock') {
          await _lockManagement();
        } else {
          await widget.lifecycle.handleDesktopAction(action);
        }
      } else if (call.method == 'managementLockRequested') {
        await _lockManagement();
      }
    });
    _armAutoLockTimer();
    unawaited(widget.lifecycle.launch());
  }

  @override
  void dispose() {
    _autoLockTimer?.cancel();
    widget.lifecycle.removeListener(_refresh);
    unawaited(widget.lifecycle.quit());
    super.dispose();
  }

  void _refresh() => setState(() {});

  WorkspaceLifecyclePreferences get _preferences =>
      WorkspaceLifecyclePreferencesStore(
        widget.lifecycle.host.config.dataDirectory,
      ).readSync();

  WorkspaceManagementLock get _managementLock => WorkspaceManagementLock(
        preferences: WorkspaceLifecyclePreferencesStore(
          widget.lifecycle.host.config.dataDirectory,
        ),
        authenticator: widget.localAuthenticator,
      );

  Future<void> _lockManagement() async {
    if (_managementLocked) return;
    try {
      if (!await _managementLock.lock()) return;
    } on Object {
      return;
    }
    if (!mounted) return;
    _stepUpGate.invalidate();
    setState(() => _managementLocked = true);
    _autoLockTimer?.cancel();
    unawaited(const MethodChannel('com.conclave.workspace/desktop')
        .invokeMethod<void>('setManagementLocked', true)
        .catchError((_) {}));
  }

  Future<void> _unlockManagement() async {
    var authenticated = false;
    try {
      authenticated =
          await _managementLock.unlock('Unlock Conclave Workspace management');
    } on Object {
      authenticated = false;
    }
    if (!mounted) return;
    if (!authenticated) return;
    _stepUpGate.invalidate();
    setState(() {
      _managementLocked = false;
      _workerRevision++;
    });
    unawaited(const MethodChannel('com.conclave.workspace/desktop')
        .invokeMethod<void>('setManagementLocked', false)
        .catchError((_) {}));
    _armAutoLockTimer();
  }

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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Local authentication was not completed.')),
        );
      }
    }
    return authenticated;
  }

  void _armAutoLockTimer() {
    _autoLockTimer?.cancel();
    final timeout = _preferences.autoLockTimeout;
    if (_managementLocked || timeout == null || timeout <= Duration.zero) {
      return;
    }
    _autoLockTimer = Timer(timeout, () => unawaited(_lockManagement()));
  }

  Future<void> _setAutoLockTimeout(Duration? timeout) async {
    final store = WorkspaceLifecyclePreferencesStore(
      widget.lifecycle.host.config.dataDirectory,
    );
    final p = store.readSync();
    await store.write(WorkspaceLifecyclePreferences(
      desiredRuntime: p.desiredRuntime,
      launchAtLogin: p.launchAtLogin,
      managementLockPreference: p.managementLockPreference,
      autoLockTimeout: timeout,
      ownerUserId: p.ownerUserId,
      ownerDisplayName: p.ownerDisplayName,
    ));
    _armAutoLockTimer();
    if (mounted) setState(() {});
  }

  Future<void> _setLaunchAtLogin(bool enabled) async {
    if (enabled &&
        _preferences.desiredRuntime != DesiredRuntimeState.connected) {
      return;
    }
    await HostLifecycleController.setLaunchAtLogin(enabled);
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
    ));
    if (mounted) setState(() {});
  }

  Future<void> _confirmQuit() async {
    // Use the navigator's context (below MaterialApp) so showDialog can find
    // a valid Overlay.  The state's own `context` sits *above* MaterialApp and
    // has no Navigator ancestor, which silently prevents the dialog from being
    // shown.
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final activeCount =
        widget.lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0;
    final shouldQuit = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Quit Conclave Workspace?'),
        content: Text(
          activeCount > 0
              ? 'There ${activeCount == 1 ? 'is 1 active assignment running' : 'are $activeCount active assignments running'}.\n\n'
                  'Assignments will be safely reconciled and drained before the Workspace disconnects.'
              : 'Active work will be reconciled safely before this machine disconnects. You can start the Workspace again anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep running'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Quit Workspace'),
          ),
        ],
      ),
    );
    if (shouldQuit != true || !mounted) return;

    if (activeCount > 0) {
      final connection = widget.lifecycle.host.cloudConnection;
      connection?.beginDrain();
      var drained = false;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        if ((connection?.activeAssignmentCount ?? 0) == 0) {
          drained = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      if (!drained && (connection?.activeAssignmentCount ?? 0) > 0) {
        if (mounted) {
          await showDialog<void>(
            context: dialogContext,
            builder: (context) => AlertDialog(
              title: const Text('Unable to Close Safely'),
              content: Text(
                'Running processes could not be safely stopped within the timeout (${connection?.activeAssignmentCount ?? 0} active assignments remaining).\n\n'
                'Conclave Workspace did not close to protect your work and files from corruption.',
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
        return;
      }
    }

    try {
      await widget.lifecycle.quit();
      const desktopChannel = MethodChannel('com.conclave.workspace/desktop');
      await desktopChannel.invokeMethod<void>('terminate');
    } catch (error) {
      if (mounted) {
        await showDialog<void>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: const Text('Unable to Close Safely'),
            content: Text(
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
      final openBrowser = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('Sign in to Conclave Workspace'),
          content: SelectableText(
            'Open the secure sign-in request in your browser, sign in to your Conclave account, then enter this code to approve the desktop app:\n\n${intent.userCode}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Open browser'),
            ),
          ],
        ),
      );
      if (openBrowser != true) return;
      await client.openVerification(intent);
      if (!mounted) return;
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(content: Text('Waiting for browser sign-in approval…')),
      );
      failureContext = 'waiting for browser approval';
      final session = await client.waitForApprovalAndClaim(intent);
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
    if (!await _requireStepUp('Sign out of this Workspace account')) return;
    final stored =
        await lifecycle.host.credentialStore.read(desktopHumanCredentialKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          final session =
              DesktopHumanSession.fromJson(Map<String, dynamic>.from(decoded));
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

  Future<void> _connectWorkspace() async {
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
      final session = DesktopHumanSession.fromJson(
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
      final suggestedName =
          registration?.name ?? await resolveFriendlyComputerName();
      final nameController = TextEditingController(text: suggestedName);
      final existingPreferences =
          WorkspaceLifecyclePreferencesStore(dataDirectory).readSync();
      var launchAtLogin = Platform.isMacOS &&
          (registration == null || existingPreferences.launchAtLogin);
      final connectOptions = await showDialog<(String, bool)>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Connect Workspace'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameController,
                autofocus: true,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Workspace name',
                  border: OutlineInputBorder(),
                ),
              ),
              if (Platform.isMacOS)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: launchAtLogin,
                  onChanged: (value) =>
                      setDialogState(() => launchAtLogin = value),
                  title: const Text('Start Conclave Workspace at login'),
                  subtitle: const Text(
                    'Reconnect this computer in the background after you sign in to macOS.',
                  ),
                ),
            ]),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  (nameController.text.trim(), launchAtLogin),
                ),
                child: const Text('Connect Workspace'),
              ),
            ],
          ),
        ),
      );
      nameController.dispose();
      if (connectOptions == null) return;
      final workspaceName = connectOptions.$1;
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
      await HostLifecycleController.setLaunchAtLogin(connectOptions.$2);
      final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final preferences = preferenceStore.readSync();
      await preferenceStore.write(WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.connected,
        launchAtLogin: connectOptions.$2,
        managementLockPreference: preferences.managementLockPreference,
        autoLockTimeout: preferences.autoLockTimeout,
        ownerUserId: session.userId,
        ownerDisplayName: session.displayName,
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
      final openBrowser = await showDialog<bool>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('Confirm your Conclave account'),
          content: SelectableText(
            'Open the secure sign-in request in your browser and approve this '
            'action with the Workspace owner account.\n\n${intent.userCode}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Open browser'),
            ),
          ],
        ),
      );
      if (openBrowser != true) return null;
      await client.openVerification(intent);
      final session = await client.waitForApprovalAndClaim(intent);
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
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(
            content: Text(
                'Wait for active work to finish before releasing Workspace ownership.')),
      );
      return;
    }
    var acknowledgedLocalCredentials = false;
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Release Workspace from this account?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'This revokes the runtime credential, disconnects Cloud, and releases the installation owner binding so another Conclave account can connect it. Local Workers, provider credentials, adapters, and Work Root files remain on this computer.'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: acknowledgedLocalCredentials,
              onChanged: (value) => setDialogState(
                  () => acknowledgedLocalCredentials = value == true),
              title: const Text(
                  'I understand local Worker/provider credentials will remain here.'),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError),
              onPressed: acknowledgedLocalCredentials
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Release Workspace'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    DesktopHumanSession? freshSession;
    final authClient = DesktopAuthClient(cloudUrl: registration.cloudUrl);
    try {
      final ownerUserId = registration.ownerUserId;
      if (ownerUserId == null) {
        throw StateError(
            'Verify this Workspace owner by reconnecting before release.');
      }
      freshSession = await _reauthenticateWorkspaceOwner(
        ownerUserId,
        revokeAfterVerification: false,
      );
      if (freshSession == null) return;
      if (!await _requireStepUp('Release Workspace ownership')) return;
      final installationId = registration.installationId ??
          await InstallationIdentityStore(dataDirectory).getOrCreate();
      await authClient.releaseWorkspace(
        session: freshSession,
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
      if (freshSession != null) {
        try {
          await authClient.revokeSession(freshSession);
        } on Object {
          // The temporary session expires on its own if revocation fails.
        }
      }
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

    try {
      final ownerUserId = registration.ownerUserId;
      if (ownerUserId == null ||
          await _reauthenticateWorkspaceOwner(ownerUserId) == null) {
        return;
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
          dialogContext,
          'Could not verify the Workspace owner: $error',
        );
      }
      return;
    }

    try {
      await lifecycle.handleDesktopAction('drain');
      final token =
          await lifecycle.host.credentialStore.read(registration.hostId);
      if (token == null) {
        throw StateError('Workspace credential is missing; reconnect first.');
      }
      if (!await _requireStepUp('Disconnect Workspace')) return;
      await WorkspacePairingService.unpair(
        cloudUrl: registration.cloudUrl,
        token: token,
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
    }
  }

  Future<void> _resetLocalWorkspace() async {
    final lifecycle = widget.lifecycle;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    if ((lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(
          content: Text('Wait for active work to finish before resetting.'),
        ),
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
        if (ownerUserId == null ||
            await _reauthenticateWorkspaceOwner(ownerUserId) == null) {
          return;
        }
        await lifecycle.handleDesktopAction('drain');
        if ((lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
          throw StateError('Wait for active work to finish before resetting.');
        }
        if (!await _requireStepUp('Reset local Workspace')) return;
        final desiredRuntime = WorkspaceLifecyclePreferencesStore(dataDir)
            .readSync()
            .desiredRuntime;
        if (desiredRuntime == DesiredRuntimeState.connected) {
          final token =
              await lifecycle.host.credentialStore.read(registration.hostId);
          if (token == null) {
            throw StateError(
              'The runtime credential is missing. Reconnect before resetting so Cloud can revoke it.',
            );
          }
          await WorkspacePairingService.unpair(
            cloudUrl: registration.cloudUrl,
            token: token,
          );
        }
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

  Future<void> _addLocalWorker(BuildContext _) async {
    final registry = widget.lifecycle.host.localWorkerRegistry;
    if (registry == null) return;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    final added = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AddLocalWorkerDialog(
        registry: registry,
        credentialStore: widget.lifecycle.host.credentialStore,
        adapterAvailable: (workerTypeId, permissions) => widget
            .lifecycle.host.adapterPackageStore
            .hasVerifiedActivePackage(workerTypeId, permissions),
        probePrerequisite: _probeLocalWorkerPrerequisite,
        launchAuthentication: _launchLocalWorkerAuthentication,
        validateAuthentication: _validateLocalWorkerAuthentication,
        validateApiCredential:
            (workerTypeId, apiKey, endpointUrl, permissions) =>
                _validateLocalApiCredential(
          widget.lifecycle.host.adapterPackageStore,
          workerTypeId,
          apiKey,
          endpointUrl,
          permissions,
        ),
        ensureAdapter: _ensureAdapterAvailable,
      ),
    );
    if (added == true && mounted) setState(() => _workerRevision++);
  }

  Future<bool> _ensureAdapterAvailable(String workerTypeId) async {
    final host = widget.lifecycle.host;
    final cloudUri =
        host.config.cloudUri ?? Uri.parse(conclaveProductionCloudUrl);
    final catalog = V7AdapterCatalogClient(
      cloudUri: cloudUri,
      authToken: host.config.authToken,
      packageStore: host.adapterPackageStore,
    );
    try {
      return await catalog.installLatest(workerTypeId) != null;
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

  Widget _buildManagementDashboard() {
    final lifecycle = widget.lifecycle;
    return HostDashboard(
      snapshot: lifecycle.uiSnapshot,
      autoLockTimeout: _preferences.autoLockTimeout,
      onAutoLockTimeoutChanged: _setAutoLockTimeout,
      launchAtLogin: _preferences.launchAtLogin,
      onLaunchAtLoginChanged: _setLaunchAtLogin,
      onLock: () => unawaited(_lockManagement()),
      requireStepUp: _requireStepUp,
      onSignIn: _signInDesktopHuman,
      onSignOut: _signOutDesktopHuman,
      onRecoverCredential: _connectWorkspace,
      onDisconnect: _disconnectWorkspace,
      onRelease: _releaseWorkspaceOwnership,
      onReset: _resetLocalWorkspace,
      onQuit: _confirmQuit,
      onRetry: lifecycle.retryConnection,
      onExportDiagnostics: _exportDiagnostics,
      onChangeWorkRoot: _changeWorkRoot,
      workerRevision: _workerRevision,
      localWorkerRegistry: lifecycle.host.localWorkerRegistry,
      credentialStore: lifecycle.host.credentialStore,
      adapterPackageStore: lifecycle.host.adapterPackageStore,
      ensureAdapter: _ensureAdapterAvailable,
      onAddWorker: () => _addLocalWorker(context),
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
      home: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _armAutoLockTimer(),
        onPointerMove: (_) => _armAutoLockTimer(),
        child: Focus(
          onKeyEvent: (_, __) {
            _armAutoLockTimer();
            return KeyEventResult.ignored;
          },
          child: Scaffold(
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
                      onConnectWorkspace: _connectWorkspace,
                      onSignOut: _signOutDesktopHuman,
                      onRelease: _releaseWorkspaceOwnership,
                      onQuit: _confirmQuit,
                      onLock: _lockManagement,
                      managementLocked: _managementLocked,
                      onUnlock: _unlockManagement,
                      onActivity: _armAutoLockTimer,
                      onManagementAuthRequiredChanged:
                          lifecycle.updateManagementAuthRequired,
                      managementShellBuilder: _buildManagementDashboard,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ShellAccessMode {
  checking,
  signedOut,
  signInRequired,
  signedIn,
  reauthRequired,
}

class _ShellAccess {
  const _ShellAccess(this.mode, [this.session]);

  final _ShellAccessMode mode;
  final DesktopHumanSession? session;
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
    this.managementLocked = false,
    this.onUnlock,
    this.onActivity,
    this.onManagementAuthRequiredChanged,
    this.onLock,
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
  final bool managementLocked;
  final Future<void> Function()? onUnlock;
  final VoidCallback? onActivity;
  final ValueChanged<bool>? onManagementAuthRequiredChanged;
  final Future<void> Function()? onLock;
  final Widget Function() managementShellBuilder;

  @override
  State<WorkspaceShellRouter> createState() => _WorkspaceShellRouterState();
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
      access.mode == _ShellAccessMode.reauthRequired,
    );
    return access;
  }

  Future<_ShellAccess> _resolveAccess() async {
    final runtimeIntendedConnected = widget.snapshot.cloudConnected ||
        widget.snapshot.desiredRuntimeConnected;
    _ShellAccess invalidSession([DesktopHumanSession? session]) => _ShellAccess(
          runtimeIntendedConnected
              ? _ShellAccessMode.reauthRequired
              : _ShellAccessMode.signInRequired,
          session,
        );

    final stored = await widget.credentialStore.read(desktopHumanCredentialKey);
    if (stored == null || stored.isEmpty) {
      return _ShellAccess(widget.snapshot.paired && runtimeIntendedConnected
          ? _ShellAccessMode.reauthRequired
          : _ShellAccessMode.signedOut);
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
      );
      if (!expiresAt.isAfter(DateTime.now().toUtc())) {
        return invalidSession(session);
      }
      final ownerUserId = widget.snapshot.ownerUserId;
      if (widget.snapshot.paired &&
          (ownerUserId == null || ownerUserId != session.userId)) {
        return _ShellAccess(_ShellAccessMode.reauthRequired, session);
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
      return _ShellAccess(_ShellAccessMode.signedIn, restored);
    } on Object {
      return runtimeIntendedConnected
          ? _ShellAccess(_ShellAccessMode.reauthRequired)
          : _ShellAccess(_ShellAccessMode.signInRequired);
    }
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
          if (access == null || access.mode == _ShellAccessMode.checking) {
            return const _MinimalShell(
              version: conclaveWorkspaceAppVersion,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          switch (access.mode) {
            case _ShellAccessMode.checking:
              return const _MinimalShell(
                version: conclaveWorkspaceAppVersion,
                child: Center(child: CircularProgressIndicator()),
              );
            case _ShellAccessMode.signedOut:
              return _MinimalShell(
                version: widget.snapshot.appVersion,
                onAbout: _showAbout,
                onQuit: widget.onQuit,
                child: _SignedOutShell(onSignIn: widget.onSignIn),
              );
            case _ShellAccessMode.signInRequired:
              return _MinimalShell(
                version: widget.snapshot.appVersion,
                onAbout: _showAbout,
                onQuit: widget.onQuit,
                child: _SignedOutShell(
                  onSignIn: widget.onSignIn,
                  signInRequired: true,
                ),
              );
            case _ShellAccessMode.reauthRequired:
              return _MinimalShell(
                version: widget.snapshot.appVersion,
                onAbout: _showAbout,
                onQuit: widget.onQuit,
                child: _ReauthRequiredShell(
                  runtimeConnected: widget.snapshot.cloudConnected,
                  onSignIn: widget.onSignIn,
                ),
              );
            case _ShellAccessMode.signedIn:
              if (widget.managementLocked) {
                return _MinimalShell(
                  version: widget.snapshot.appVersion,
                  onAbout: _showAbout,
                  onQuit: widget.onQuit,
                  child: _LockedShell(
                    runtimeConnected: widget.snapshot.cloudConnected,
                    onUnlock: widget.onUnlock,
                  ),
                );
              }
              if (widget.snapshot.workspaceReady) {
                return widget.managementShellBuilder();
              }
              return _MinimalShell(
                version: widget.snapshot.appVersion,
                onAbout: _showAbout,
                onQuit: widget.onQuit,
                child: _SignedInDisconnectedShell(
                  session: access.session!,
                  computerName: widget.snapshot.hostname ??
                      widget.snapshot.workspaceName ??
                      'This computer',
                  isRegistered: widget.snapshot.paired,
                  runtimeIntendedConnected: widget.snapshot.cloudConnected ||
                      widget.snapshot.desiredRuntimeConnected,
                  onConnect: widget.onConnectWorkspace,
                  onSignOut: widget.onSignOut,
                  onRelease: widget.onRelease,
                  onLock: widget.onLock,
                ),
              );
          }
        },
      );
}

class _LockedShell extends StatelessWidget {
  const _LockedShell({required this.runtimeConnected, this.onUnlock});

  final bool runtimeConnected;
  final Future<void> Function()? onUnlock;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 42),
              const SizedBox(height: 16),
              Text('Conclave Workspace',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text('Workspace is locked.'),
              const SizedBox(height: 4),
              Text(runtimeConnected
                  ? 'Runtime is still connected.'
                  : 'Runtime is disconnected.'),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed:
                    onUnlock == null ? null : () => unawaited(onUnlock!()),
                icon: const Icon(Icons.lock_open),
                label: const Text('Unlock'),
              ),
            ]),
          ),
        ),
      );
}

class _MinimalShell extends StatelessWidget {
  const _MinimalShell({
    required this.version,
    required this.child,
    this.onAbout,
    this.onQuit,
  });

  final String version;
  final Widget child;
  final VoidCallback? onAbout;
  final Future<void> Function()? onQuit;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
            child: Row(children: [
              ConclaveBrand.logoMark(size: 26),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Conclave Workspace',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              Text('v$version'),
              PopupMenuButton<String>(
                tooltip: 'Menu',
                onSelected: (value) {
                  if (value == 'about') onAbout?.call();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'about', child: Text('About')),
                ],
              ),
              IconButton(
                tooltip: 'Quit Conclave Workspace',
                onPressed: onQuit == null ? null : () => unawaited(onQuit!()),
                icon: const Icon(Icons.power_settings_new),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      );
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

class _SignedInDisconnectedShell extends StatelessWidget {
  const _SignedInDisconnectedShell({
    required this.session,
    required this.computerName,
    required this.isRegistered,
    required this.runtimeIntendedConnected,
    required this.onConnect,
    required this.onSignOut,
    this.onRelease,
    this.onLock,
  });

  final DesktopHumanSession session;
  final String computerName;
  final bool isRegistered;
  final bool runtimeIntendedConnected;
  final Future<void> Function() onConnect;
  final Future<void> Function() onSignOut;
  final Future<void> Function()? onRelease;
  final Future<void> Function()? onLock;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Workspace',
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 20),
                      Text('Account',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text('Signed in as ${session.displayName}',
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(session.email),
                      const SizedBox(height: 18),
                      Text('Computer',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(computerName),
                      const SizedBox(height: 18),
                      Text(
                        runtimeIntendedConnected
                            ? 'Workspace is reconnecting. Worker management will be available when it is Ready.'
                            : 'Not connected as a Workspace.',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (!runtimeIntendedConnected) ...[
                        const SizedBox(height: 6),
                        Text(
                            'Connect this computer before configuring Workers.',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                      const SizedBox(height: 22),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        FilledButton.icon(
                          onPressed: () => unawaited(onConnect()),
                          icon: const Icon(Icons.link),
                          label: const Text('Connect Workspace'),
                        ),
                        TextButton(
                          onPressed: () => unawaited(onSignOut()),
                          child: const Text('Sign out'),
                        ),
                        if (onLock != null)
                          OutlinedButton.icon(
                            onPressed: () => unawaited(onLock!()),
                            icon: const Icon(Icons.lock_outline),
                            label: const Text('Lock Workspace'),
                          ),
                      ]),
                      if (isRegistered && onRelease != null) ...[
                        const SizedBox(height: 8),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('Advanced & Diagnostics'),
                          children: [
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Release removes this Workspace from the account and allows another account to claim it.',
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () => unawaited(onRelease!()),
                                child: const Text(
                                    'Release Workspace from account'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ]),
              ),
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
    this.onRecoverCredential,
    this.onDisconnect,
    this.onRelease,
    this.onReset,
    this.onAccountAction,
    this.onLock,
    this.autoLockTimeout,
    this.onAutoLockTimeoutChanged,
    this.launchAtLogin = false,
    this.onLaunchAtLoginChanged,
    this.requireStepUp,
    this.onQuit,
    this.onRetry,
    this.onExportDiagnostics,
    this.onChangeWorkRoot,
    this.workerRevision = 0,
    this.localWorkerRegistry,
    this.credentialStore = const PlatformSecureCredentialStore(),
    this.adapterPackageStore,
    this.ensureAdapter,
    this.onAddWorker,
    super.key,
  });

  final HostUiSnapshot snapshot;
  final Future<void> Function()? onSignIn;
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onRecoverCredential;
  final VoidCallback? onDisconnect;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final VoidCallback? onAccountAction;
  final VoidCallback? onLock;
  final Duration? autoLockTimeout;
  final ValueChanged<Duration?>? onAutoLockTimeoutChanged;
  final bool launchAtLogin;
  final ValueChanged<bool>? onLaunchAtLoginChanged;
  final LocalConfiguredWorkerRegistry? localWorkerRegistry;
  final Future<bool> Function(String reason)? requireStepUp;
  final VoidCallback? onQuit;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final int workerRevision;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onAddWorker;

  @override
  State<HostDashboard> createState() => _HostDashboardState();
}

enum HostSurface { workspace, workers }

enum _HeaderMenuAction {
  openConclaveAX,
  checkForUpdates,
  about,
}

class _HostDashboardState extends State<HostDashboard> {
  HostSurface _selectedSurface = HostSurface.workspace;

  @override
  void didUpdateWidget(covariant HostDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.snapshot.workspaceReady &&
        oldWidget.snapshot.workspaceReady &&
        _selectedSurface != HostSurface.workspace) {
      _selectedSurface = HostSurface.workspace;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = widget.snapshot;

    final statusColor = switch (snapshot.statusLabel) {
      'Connected' => ConclaveBrand.success,
      'Starting' => ConclaveBrand.info,
      'Paused' || 'Draining' => ConclaveBrand.warning,
      _ => snapshot.mode == HostUiMode.offline ||
              snapshot.mode == HostUiMode.installFailure
          ? ConclaveBrand.error
          : theme.colorScheme.onSurface.withValues(alpha: 0.4),
    };

    return Column(
      children: [
        // App Header Bar
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
          child: Row(
            children: [
              ConclaveBrand.logoMark(size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    const Text(
                      'Conclave Workspace',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    if (snapshot.paired) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.circle, size: 7, color: statusColor),
                      const SizedBox(width: 4),
                      Text(
                        snapshot.statusLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                  Icons.power_settings_new,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
                tooltip: 'Quit Conclave Workspace',
                onPressed: widget.onQuit,
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
                ],
              ),
            ],
          ),
        ),

        // Two-Surface Horizontal Tab Switcher
        if (snapshot.workspaceReady)
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
                children: snapshot.workspaceReady
                    ? [
                        _WorkspaceTab(
                          snapshot: snapshot,
                          onSignIn: widget.onSignIn,
                          credentialStore: widget.credentialStore,
                          accountRefreshToken: widget.workerRevision,
                          onRecoverCredential: widget.onRecoverCredential,
                          onRetry: widget.onRetry,
                          onExportDiagnostics: widget.onExportDiagnostics,
                          onChangeWorkRoot: widget.onChangeWorkRoot,
                          launchAtLogin: widget.launchAtLogin,
                          onLaunchAtLoginChanged: widget.onLaunchAtLoginChanged,
                          autoLockTimeout: widget.autoLockTimeout,
                          onAutoLockTimeoutChanged:
                              widget.onAutoLockTimeoutChanged,
                          localWorkerRegistry: widget.localWorkerRegistry,
                          workerRevision: widget.workerRevision,
                          onViewWorkers: () => setState(
                              () => _selectedSurface = HostSurface.workers),
                          onDisconnect: widget.onDisconnect,
                          onRelease: widget.onRelease,
                          onReset: widget.onReset,
                          onSignOut: widget.onSignOut,
                        ),
                        _WorkersTab(
                          key: ValueKey(widget.workerRevision),
                          registry: widget.localWorkerRegistry,
                          credentialStore: widget.credentialStore,
                          adapterPackageStore: widget.adapterPackageStore,
                          ensureAdapter: widget.ensureAdapter,
                          onAddWorker: widget.onAddWorker,
                          requireStepUp: widget.requireStepUp,
                          isPaired: snapshot.workspaceReady,
                          onSwitchToWorkspace: () => setState(
                              () => _selectedSurface = HostSurface.workspace),
                        ),
                      ]
                    : [
                        _WorkspaceTab(
                          snapshot: snapshot,
                          onSignIn: widget.onSignIn,
                          credentialStore: widget.credentialStore,
                          accountRefreshToken: widget.workerRevision,
                          onRecoverCredential: widget.onRecoverCredential,
                          onRetry: widget.onRetry,
                          onExportDiagnostics: widget.onExportDiagnostics,
                          onChangeWorkRoot: widget.onChangeWorkRoot,
                          onLock: widget.onLock,
                          autoLockTimeout: widget.autoLockTimeout,
                          onAutoLockTimeoutChanged:
                              widget.onAutoLockTimeoutChanged,
                          launchAtLogin: widget.launchAtLogin,
                          onLaunchAtLoginChanged: widget.onLaunchAtLoginChanged,
                          localWorkerRegistry: widget.localWorkerRegistry,
                          workerRevision: widget.workerRevision,
                          onViewWorkers: () => setState(
                              () => _selectedSurface = HostSurface.workers),
                          onDisconnect: widget.onDisconnect,
                          onRelease: widget.onRelease,
                          onReset: widget.onReset,
                          onSignOut: widget.onSignOut,
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

class _ConnectedAccountSection extends StatelessWidget {
  const _ConnectedAccountSection({
    required this.credentialStore,
    required this.refreshToken,
    this.onLock,
  });

  final SecureCredentialStore credentialStore;
  final int refreshToken;
  final VoidCallback? onLock;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Account',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  _DesktopHumanAccountStatus(
                      key: ValueKey(refreshToken),
                      credentialStore: credentialStore),
                ],
              ),
            ),
            if (onLock != null)
              OutlinedButton.icon(
                onPressed: onLock,
                icon: const Icon(Icons.lock_outline),
                label: const Text('Lock'),
              ),
          ]),
        ),
      );
}

class _WorkspaceStartupSection extends StatelessWidget {
  const _WorkspaceStartupSection({required this.launchAtLogin, this.onChanged});
  final bool launchAtLogin;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
            child:
                Text('Startup', style: Theme.of(context).textTheme.titleMedium),
          ),
          SwitchListTile(
            value: launchAtLogin,
            onChanged: onChanged,
            title: const Text('Start at login'),
            subtitle: Text(launchAtLogin ? 'On' : 'Off'),
          ),
        ]),
      );
}

class _CurrentWorkSection extends StatelessWidget {
  const _CurrentWorkSection({required this.activeAssignments});
  final int activeAssignments;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          title: const Text('Current work'),
          subtitle: Text('$activeAssignments assignments'),
          leading: const Icon(Icons.work_outline),
        ),
      );
}

class _WorkspaceWorkerSummary extends StatefulWidget {
  const _WorkspaceWorkerSummary({
    required this.registry,
    required this.revision,
    this.onViewWorkers,
  });
  final LocalConfiguredWorkerRegistry? registry;
  final int revision;
  final VoidCallback? onViewWorkers;

  @override
  State<_WorkspaceWorkerSummary> createState() =>
      _WorkspaceWorkerSummaryState();
}

class _WorkspaceWorkerSummaryState extends State<_WorkspaceWorkerSummary> {
  late Future<List<LocalConfiguredWorker>?> _workers;

  Future<List<LocalConfiguredWorker>?> _load() =>
      widget.registry?.list() ?? Future.value(null);

  @override
  void initState() {
    super.initState();
    _workers = _load();
  }

  @override
  void didUpdateWidget(covariant _WorkspaceWorkerSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry ||
        oldWidget.revision != widget.revision) {
      _workers = _load();
    }
  }

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: FutureBuilder<List<LocalConfiguredWorker>?>(
          future: _workers,
          builder: (context, result) {
            final workers = result.data;
            final summary = workers == null
                ? (result.connectionState == ConnectionState.done
                    ? 'Worker status unavailable'
                    : 'Loading Workers…')
                : '${workers.length} configured · ${workers.where((w) => deriveLocalWorkerHealth(w) == 'Ready').length} ready';
            return ListTile(
              leading: const Icon(Icons.memory_outlined),
              title: const Text('Workers'),
              subtitle: Text(summary),
              trailing: TextButton(
                onPressed: widget.onViewWorkers,
                child: const Text('View Workers'),
              ),
            );
          },
        ),
      );
}

class _WorkspaceApplicationSection extends StatelessWidget {
  const _WorkspaceApplicationSection({required this.snapshot});
  final HostUiSnapshot snapshot;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Application', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _DetailRow(label: 'Version', value: snapshot.appVersion),
            _DetailRow(label: 'Update', value: snapshot.updateSummary),
          ]),
        ),
      );
}

class _WorkspaceTab extends StatelessWidget {
  const _WorkspaceTab({
    required this.snapshot,
    this.onSignIn,
    this.onSignOut,
    this.onRecoverCredential,
    required this.credentialStore,
    required this.accountRefreshToken,
    this.onRetry,
    this.onExportDiagnostics,
    this.onChangeWorkRoot,
    this.onDisconnect,
    this.onRelease,
    this.onReset,
    this.onLock,
    this.autoLockTimeout,
    this.onAutoLockTimeoutChanged,
    this.launchAtLogin = false,
    this.onLaunchAtLoginChanged,
    this.localWorkerRegistry,
    this.workerRevision = 0,
    this.onViewWorkers,
  });

  final HostUiSnapshot snapshot;
  final Future<void> Function()? onSignIn;
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onRecoverCredential;
  final SecureCredentialStore credentialStore;
  final int accountRefreshToken;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final VoidCallback? onDisconnect;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final VoidCallback? onLock;
  final Duration? autoLockTimeout;
  final ValueChanged<Duration?>? onAutoLockTimeoutChanged;
  final bool launchAtLogin;
  final ValueChanged<bool>? onLaunchAtLoginChanged;
  final LocalConfiguredWorkerRegistry? localWorkerRegistry;
  final int workerRevision;
  final VoidCallback? onViewWorkers;

  @override
  Widget build(BuildContext context) {
    final isError = snapshot.mode == HostUiMode.offline ||
        snapshot.mode == HostUiMode.installFailure;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (isError) ...[
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _HostRecoveryPanel(
                issue: snapshot.issue,
                retryLabel: snapshot.mode == HostUiMode.offline
                    ? 'Retry connection'
                    : 'Retry update',
                onRetry: onRetry,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (snapshot.workspaceReady) ...[
          Text('Workspace', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          _ConnectedAccountSection(
            credentialStore: credentialStore,
            refreshToken: accountRefreshToken,
            onLock: onLock,
          ),
          const SizedBox(height: 12),
          _PairedWorkspaceCard(snapshot: snapshot),
          const SizedBox(height: 12),
          _WorkspaceStartupSection(
            launchAtLogin: launchAtLogin,
            onChanged: onLaunchAtLoginChanged,
          ),
          const SizedBox(height: 12),
          _CurrentWorkSection(activeAssignments: snapshot.activeAssignments),
          const SizedBox(height: 12),
          _WorkspaceWorkerSummary(
            registry: localWorkerRegistry,
            revision: workerRevision,
            onViewWorkers: onViewWorkers,
          ),
          const SizedBox(height: 12),
          _WorkRootSection(
            workRootPath: snapshot.workRootPath,
            onChangeWorkRoot: onChangeWorkRoot,
          ),
          const SizedBox(height: 12),
          _WorkspaceApplicationSection(snapshot: snapshot),
          const SizedBox(height: 12),
          _WorkspaceDiagnosticsSection(
            snapshot: snapshot,
            onRetry: onRetry,
            onExportDiagnostics: onExportDiagnostics,
            onDisconnect: onDisconnect,
            onRelease: onRelease,
            onReset: onReset,
            onSignOut: onSignOut,
            autoLockTimeout: autoLockTimeout,
            onAutoLockTimeoutChanged: onAutoLockTimeoutChanged,
          ),
        ] else ...[
          _WorkspaceAccountSection(
            snapshot: snapshot,
            credentialStore: credentialStore,
            refreshToken: accountRefreshToken,
            onSignIn: onSignIn,
            onSignOut: onSignOut,
            onRecoverCredential: onRecoverCredential,
            onLock: onLock,
          ),
        ],
      ],
    );
  }
}

class _WorkspaceAccountSection extends StatelessWidget {
  const _WorkspaceAccountSection({
    required this.snapshot,
    required this.credentialStore,
    required this.refreshToken,
    this.onSignIn,
    this.onSignOut,
    this.onRecoverCredential,
    this.onLock,
  });

  final HostUiSnapshot snapshot;
  final SecureCredentialStore credentialStore;
  final int refreshToken;
  final Future<void> Function()? onSignIn;
  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onRecoverCredential;
  final VoidCallback? onLock;

  @override
  Widget build(BuildContext context) {
    final signedIn = _hasValidCachedDesktopSession(credentialStore);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Account', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _DesktopHumanAccountStatus(
              key: ValueKey(refreshToken), credentialStore: credentialStore),
          if (!snapshot.workspaceReady) ...[
            const SizedBox(height: 14),
            const Text(
              'This computer is not connected as a Workspace.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
                'Computer\n${snapshot.hostname ?? snapshot.workspaceName ?? 'This computer'}'),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!signedIn && onSignIn != null)
              OutlinedButton.icon(
                  onPressed: () => unawaited(onSignIn!()),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in')),
            if (signedIn && onSignOut != null)
              OutlinedButton.icon(
                  onPressed: () => unawaited(onSignOut!()),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out')),
            if (signedIn && onLock != null)
              OutlinedButton.icon(
                onPressed: onLock,
                icon: const Icon(Icons.lock_outline),
                label: const Text('Lock Workspace'),
              ),
            if (signedIn &&
                onRecoverCredential != null &&
                !snapshot.workspaceReady)
              OutlinedButton.icon(
                  onPressed: () => unawaited(onRecoverCredential!()),
                  icon: const Icon(Icons.sync),
                  label: const Text('Connect Workspace')),
          ]),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

class _WorkRootSection extends StatefulWidget {
  const _WorkRootSection({
    required this.workRootPath,
    this.onChangeWorkRoot,
  });

  final String? workRootPath;
  final Future<void> Function(String path)? onChangeWorkRoot;

  @override
  State<_WorkRootSection> createState() => _WorkRootSectionState();
}

class _WorkRootSectionState extends State<_WorkRootSection> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.workRootPath ?? '');
  }

  @override
  void didUpdateWidget(covariant _WorkRootSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workRootPath != widget.workRootPath) {
      _controller.text = widget.workRootPath ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final selected = await HostLifecycleController.chooseDirectory(
      initialPath: widget.workRootPath,
    );
    if (selected != null && selected.isNotEmpty) {
      if (widget.onChangeWorkRoot != null) {
        await widget.onChangeWorkRoot!(selected);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPath =
        widget.workRootPath != null && widget.workRootPath!.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              readOnly: true,
              decoration: InputDecoration(
                labelText: 'Work Root',
                hintText: 'Not configured',
                border: const OutlineInputBorder(),
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: TextButton.icon(
                    onPressed: _browse,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('Browse'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: hasPath
                  ? () => HostLifecycleController.openPath(widget.workRootPath!)
                  : null,
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('Open folder'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopHumanAccountStatus extends StatefulWidget {
  const _DesktopHumanAccountStatus({
    required this.credentialStore,
    super.key,
  });

  final SecureCredentialStore credentialStore;

  @override
  State<_DesktopHumanAccountStatus> createState() =>
      _DesktopHumanAccountStatusState();
}

class _DesktopHumanAccountStatusState
    extends State<_DesktopHumanAccountStatus> {
  late Future<Map<String, String>?> _session;

  @override
  void initState() {
    super.initState();
    _session = _loadSession();
  }

  Future<Map<String, String>?> _loadSession() async {
    try {
      final stored =
          await widget.credentialStore.read(desktopHumanCredentialKey);
      if (stored == null || stored.isEmpty) return null;
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return null;
      final expiresAt =
          DateTime.tryParse(decoded['expiresAt']?.toString() ?? '');
      if (expiresAt == null || !expiresAt.isAfter(DateTime.now().toUtc())) {
        return null;
      }
      final displayName = decoded['displayName'];
      final email = decoded['email'];
      return {
        'displayName': displayName is String && displayName.isNotEmpty
            ? displayName
            : 'Conclave account',
        'email': email is String ? email : '',
      };
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, String>?>(
        future: _session,
        builder: (context, result) {
          final session = result.data;
          if (!result.hasData) {
            return Text(
              result.connectionState == ConnectionState.done
                  ? 'Not signed in'
                  : 'Checking Conclave account…',
              style: Theme.of(context).textTheme.bodyMedium,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Signed in as'),
              Text(session!['displayName']!,
                  style: Theme.of(context).textTheme.titleSmall),
              Text(session['email']!,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          );
        },
      );
}

class _PairedWorkspaceCard extends StatelessWidget {
  const _PairedWorkspaceCard({
    required this.snapshot,
  });

  final HostUiSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workspaceName =
        snapshot.workspaceName ?? snapshot.hostname ?? 'Conclave Workspace';
    final isConnected = snapshot.cloudConnected;
    final connectionLabel =
        snapshot.activeTransportMode == 'switching_to_websocket'
            ? 'Switching to WebSocket…'
            : isConnected
                ? switch (snapshot.activeTransportMode) {
                    'websocket' => 'Connected · WebSocket',
                    'http_long_poll' => 'Connected · HTTPS fallback',
                    'switching_to_websocket' => 'Switching to WebSocket…',
                    _ => 'Connected',
                  }
                : snapshot.mode == HostUiMode.starting
                    ? 'Connecting...'
                    : 'Offline';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Connection', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(workspaceName, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isConnected ? Colors.green : Colors.orange,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                connectionLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isConnected
                      ? (theme.brightness == Brightness.dark
                          ? Colors.greenAccent
                          : Colors.green.shade700)
                      : Colors.orange.shade700,
                ),
              ),
            ],
          ),
          if (isConnected &&
              snapshot.activeTransportMode == 'http_long_poll') ...[
            const SizedBox(height: 4),
            Text(
              'WebSocket is unavailable. Work can continue.',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _WorkspaceDiagnosticsSection extends StatelessWidget {
  const _WorkspaceDiagnosticsSection({
    required this.snapshot,
    this.onRetry,
    this.onExportDiagnostics,
    this.onDisconnect,
    this.onRelease,
    this.onReset,
    this.onSignOut,
    this.autoLockTimeout,
    this.onAutoLockTimeoutChanged,
  });

  final HostUiSnapshot snapshot;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final VoidCallback? onDisconnect;
  final Future<void> Function()? onRelease;
  final VoidCallback? onReset;
  final Future<void> Function()? onSignOut;
  final Duration? autoLockTimeout;
  final ValueChanged<Duration?>? onAutoLockTimeoutChanged;

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
            'Advanced & Diagnostics',
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
              value: snapshot.runtimeCredentialAvailable
                  ? 'Available locally (value hidden)'
                  : 'Missing from secure storage',
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
                      'Runtime credential: ${snapshot.runtimeCredentialAvailable ? 'available locally (value withheld)' : 'missing'}',
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
                if (onRetry != null)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(onRetry!()),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry connection'),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Workspace management',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (onAutoLockTimeoutChanged != null)
              Row(children: [
                const Expanded(child: Text('Lock after inactivity')),
                DropdownButton<int>(
                  value: autoLockTimeout?.inMinutes ?? 0,
                  items: const [0, 5, 15, 30, 60]
                      .map((minutes) => DropdownMenuItem<int>(
                            value: minutes,
                            child: Text(minutes == 0 ? 'Off' : '$minutes min'),
                          ))
                      .toList(),
                  onChanged: (minutes) => onAutoLockTimeoutChanged!(
                    minutes == null || minutes == 0
                        ? null
                        : Duration(minutes: minutes),
                  ),
                ),
              ]),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 8, children: [
              if (onDisconnect != null)
                OutlinedButton.icon(
                  onPressed: onDisconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect Workspace'),
                ),
              if (onSignOut != null)
                TextButton.icon(
                  onPressed: () => unawaited(onSignOut!()),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              if (onRelease != null)
                TextButton.icon(
                  onPressed: () => unawaited(onRelease!()),
                  icon: const Icon(Icons.person_remove_outlined),
                  label: const Text('Release Workspace from account'),
                ),
              if (onReset != null)
                TextButton.icon(
                  onPressed: onReset,
                  icon: Icon(Icons.delete_forever_outlined,
                      color: theme.colorScheme.error),
                  label: Text('Reset local Workspace',
                      style: TextStyle(color: theme.colorScheme.error)),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.registry,
    required this.credentialStore,
    required this.adapterPackageStore,
    this.ensureAdapter,
    required this.onAddWorker,
    this.isPaired = true,
    this.onSwitchToWorkspace,
    this.requireStepUp,
    super.key,
  });

  final LocalConfiguredWorkerRegistry? registry;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onAddWorker;
  final bool isPaired;
  final VoidCallback? onSwitchToWorkspace;
  final Future<bool> Function(String reason)? requireStepUp;

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  Future<List<LocalConfiguredWorker>>? _workers;

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
    if (mounted) setState(_loadWorkers);
  }

  Future<void> _remove(LocalConfiguredWorker worker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${worker.name}?'),
        content: const Text(
            'This removes the Worker from this Workspace and deletes its locally stored credential.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove Worker'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final requireStepUp = widget.requireStepUp;
    if (requireStepUp == null ||
        !await requireStepUp('Remove a local Worker')) {
      return;
    }
    if (!mounted) return;
    final registry = widget.registry;
    if (registry == null) return;
    await registry.remove(worker.id);
    final credentialRef = worker.credentialRef;
    if (credentialRef != null) {
      await widget.credentialStore.delete(credentialRef);
    }
    if (mounted) setState(_loadWorkers);
  }

  Future<void> _edit(LocalConfiguredWorker worker) async {
    final registry = widget.registry;
    if (registry == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AddLocalWorkerDialog(
        registry: registry,
        credentialStore: widget.credentialStore,
        worker: worker,
        requireStepUp: widget.requireStepUp,
        adapterAvailable: (workerTypeId, permissions) =>
            widget.adapterPackageStore
                ?.hasVerifiedActivePackage(workerTypeId, permissions) ??
            Future.value(false),
        probePrerequisite: _probeLocalWorkerPrerequisite,
        launchAuthentication: _launchLocalWorkerAuthentication,
        validateAuthentication: _validateLocalWorkerAuthentication,
        validateApiCredential:
            (workerTypeId, apiKey, endpointUrl, permissions) =>
                _validateLocalApiCredential(
          widget.adapterPackageStore,
          workerTypeId,
          apiKey,
          endpointUrl,
          permissions,
        ),
        ensureAdapter: widget.ensureAdapter,
      ),
    );
    if (saved == true && mounted) setState(_loadWorkers);
  }

  void _showDetail(LocalConfiguredWorker worker) {
    showDialog<void>(
      context: context,
      builder: (context) => _WorkerDetailDialog(
        worker: worker,
        onEdit: () {
          Navigator.pop(context);
          _edit(worker);
        },
        onToggleDisable: (disabled) {
          Navigator.pop(context);
          _setDisabled(worker, disabled);
        },
        onRemove: () {
          Navigator.pop(context);
          _remove(worker);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Local AI models and execution adapters running on this machine.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: widget.registry == null ? null : widget.onAddWorker,
              icon: const Icon(Icons.add),
              label: const Text('Add Worker'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.registry == null)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                  'Local Worker setup is unavailable. Restart Workspace and check Diagnostics.'),
            ),
          )
        else
          FutureBuilder<List<LocalConfiguredWorker>>(
            future: _workers,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Worker registry needs repair: ${snapshot.error}',
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              final workers = snapshot.data!;
              if (workers.isEmpty) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: [
                        Icon(Icons.memory,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(
                          'No local Workers configured',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Add a Worker to configure local CLI tools, model endpoints, or API keys.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonalIcon(
                          onPressed: widget.onAddWorker,
                          icon: const Icon(Icons.add),
                          label: const Text('Add Worker'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  for (final worker in workers)
                    Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _showDetail(worker),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: theme
                                      .colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  _workerTypeIcon(worker.workerTypeId),
                                  size: 20,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          worker.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        _WorkerStatusBadge(worker: worker),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${_friendlyTypeName(worker.workerTypeId)}'
                                      '${worker.defaultModel == null ? '' : ' · ${worker.defaultModel}'}',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    if (_healthReasonExplanation(
                                            deriveLocalWorkerHealth(worker)) !=
                                        null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        _healthReasonExplanation(
                                            deriveLocalWorkerHealth(worker))!,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: theme.colorScheme.error,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Worker actions',
                                onSelected: (action) {
                                  if (action == 'detail') {
                                    _showDetail(worker);
                                  } else if (action == 'edit') {
                                    unawaited(_edit(worker));
                                  } else if (action == 'disable') {
                                    unawaited(_setDisabled(worker, true));
                                  } else if (action == 'enable') {
                                    unawaited(_setDisabled(worker, false));
                                  } else if (action == 'remove') {
                                    unawaited(_remove(worker));
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'detail',
                                    child: Text('View details'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit configuration'),
                                  ),
                                  if (worker.status ==
                                      LocalWorkerStatus.disabled)
                                    const PopupMenuItem(
                                      value: 'enable',
                                      child: Text('Enable locally'),
                                    )
                                  else
                                    const PopupMenuItem(
                                      value: 'disable',
                                      child: Text('Disable locally'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Remove Worker'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
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
        'codex' => Icons.terminal,
        'antigravity' => Icons.auto_awesome,
        'claude-code' => Icons.code,
        'openai-api' || 'gemini-api' || 'anthropic-api' => Icons.cloud_queue,
        'ollama' => Icons.memory,
        _ => Icons.smart_toy_outlined,
      };

  static String _friendlyTypeName(String id) => switch (id) {
        'codex' => 'Codex',
        'antigravity' => 'Antigravity',
        'claude-code' => 'Claude Code',
        'openai-api' => 'OpenAI API',
        'gemini-api' => 'Gemini API',
        'anthropic-api' => 'Anthropic API',
        'ollama' => 'Ollama',
        _ => id,
      };
}

String deriveLocalWorkerHealth(LocalConfiguredWorker worker) {
  if (worker.status == LocalWorkerStatus.disabled ||
      worker.status == LocalWorkerStatus.removed) {
    return 'Disabled';
  }

  // Explicit health reason if set
  final reason = worker.adapterConfig['healthReason'] as String? ??
      worker.adapterConfig['reason'] as String?;
  if (reason != null) {
    switch (reason) {
      case 'cli_missing':
        return 'CLI missing';
      case 'adapter_unavailable':
        return 'Adapter unavailable';
      case 'endpoint_unavailable':
        return 'Endpoint unavailable';
      case 'credential_invalid':
        return 'Credential invalid';
      case 'permission_required':
        return 'Permission required';
      case 'sign_in_required':
        return 'Sign in required';
    }
  }

  if (worker.adapterConfig['cliMissing'] == true ||
      worker.adapterConfig['prerequisiteMissing'] == true) {
    return 'CLI missing';
  }
  if (worker.adapterConfig['adapterMissing'] == true ||
      worker.adapterConfig['adapterUnavailable'] == true) {
    return 'Adapter unavailable';
  }
  if (worker.adapterConfig['endpointUnavailable'] == true) {
    return 'Endpoint unavailable';
  }

  // Credentials & auth
  if (worker.credentialStatus ==
          LocalWorkerCredentialStatus.needsAuthentication ||
      worker.credentialStatus == LocalWorkerCredentialStatus.expired) {
    return 'Sign in required';
  }
  if (worker.credentialStatus == LocalWorkerCredentialStatus.error) {
    if (worker.authStrategy == 'local_endpoint') {
      return 'Endpoint unavailable';
    }
    return 'Credential invalid';
  }

  // Permissions
  if (worker.localPermissions.isEmpty) {
    return 'Permission required';
  }

  if (worker.status == LocalWorkerStatus.needsAttention) {
    if (worker.authStrategy == 'browser_auth') {
      return 'Sign in required';
    }
    if (worker.authStrategy == 'local_endpoint') {
      return 'Endpoint unavailable';
    }
    if (worker.authStrategy == 'api_key') {
      return 'Credential invalid';
    }
    return 'Sign in required';
  }

  return 'Ready';
}

String? _healthReasonExplanation(String health) => switch (health) {
      'Sign in required' => 'Sign in via browser or CLI to enable execution.',
      'CLI missing' => 'Required CLI tool is missing or not in PATH.',
      'Adapter unavailable' =>
        'Local adapter is missing or failed verification.',
      'Endpoint unavailable' => 'Local service endpoint is unreachable.',
      'Credential invalid' => 'Stored API key is missing or invalid.',
      'Permission required' => 'Local workspace permissions must be granted.',
      _ => null,
    };

class _WorkerStatusBadge extends StatelessWidget {
  const _WorkerStatusBadge({
    required this.worker,
  });

  final LocalConfiguredWorker worker;

  @override
  Widget build(BuildContext context) {
    final label = deriveLocalWorkerHealth(worker);
    final color = switch (label) {
      'Ready' => ConclaveBrand.success,
      'Disabled' => Colors.grey,
      'Sign in required' => ConclaveBrand.warning,
      'Permission required' => ConclaveBrand.warning,
      'CLI missing' => ConclaveBrand.error,
      'Adapter unavailable' => ConclaveBrand.error,
      'Endpoint unavailable' => ConclaveBrand.error,
      'Credential invalid' => ConclaveBrand.error,
      _ => ConclaveBrand.warning,
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

class _WorkerDetailDialog extends StatelessWidget {
  const _WorkerDetailDialog({
    required this.worker,
    required this.onEdit,
    required this.onToggleDisable,
    required this.onRemove,
  });

  final LocalConfiguredWorker worker;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggleDisable;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friendlyType =
        _WorkersTabState._friendlyTypeName(worker.workerTypeId);
    final health = deriveLocalWorkerHealth(worker);
    final option = LocalWorkerTypeOption.supported
        .where((opt) => opt.id == worker.workerTypeId)
        .firstOrNull;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _WorkersTabState._workerTypeIcon(worker.workerTypeId),
            size: 24,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              worker.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _WorkerStatusBadge(worker: worker),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailRow(label: 'Worker Type', value: friendlyType),
              _DetailRow(
                label: 'Model',
                value: worker.defaultModel ?? 'Auto',
              ),
              if (worker.allowedModels.isNotEmpty)
                _DetailRow(
                  label: 'Allowed Models',
                  value: worker.allowedModels.join(', '),
                ),
              _DetailRow(
                label: 'Credential',
                value: switch (worker.authStrategy) {
                  'api_key' => 'Encrypted API key on this machine',
                  'browser_auth' => 'Signed in locally via browser / CLI',
                  'local_endpoint' => 'Local service endpoint',
                  _ => worker.authStrategy,
                },
              ),
              _DetailRow(
                label: 'Adapter version',
                value: worker.adapterVersionPolicy ??
                    'Default (active verified release)',
              ),
              _DetailRow(
                label: 'CLI / Prerequisite',
                value: option?.prerequisite ?? 'None required',
              ),
              if (worker.adapterConfig['endpointUrl'] != null)
                _DetailRow(
                  label: 'Endpoint URL',
                  value: worker.adapterConfig['endpointUrl'] as String,
                ),
              _DetailRow(
                label: 'Permissions',
                value: worker.localPermissions.isEmpty
                    ? 'None granted'
                    : worker.localPermissions.join(', '),
              ),
              _DetailRow(
                label: 'Concurrency',
                value: '${worker.localConcurrencyLimit} concurrent runs',
              ),
              _DetailRow(
                label: 'Local status',
                value: health,
              ),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  'Advanced Technical Details',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                children: [
                  _CopyableDetailRow(label: 'Worker ID', value: worker.id),
                  if (worker.credentialRef != null)
                    _CopyableDetailRow(
                      label: 'Credential Reference',
                      value: worker.credentialRef!,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () =>
              onToggleDisable(worker.status != LocalWorkerStatus.disabled),
          child: Text(worker.status == LocalWorkerStatus.disabled
              ? 'Enable locally'
              : 'Disable locally'),
        ),
        TextButton(
          onPressed: onRemove,
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
          child: const Text('Remove'),
        ),
        FilledButton.icon(
          onPressed: onEdit,
          icon: const Icon(Icons.edit, size: 16),
          label: const Text('Edit Worker'),
        ),
      ],
    );
  }
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  issue ?? 'The Workspace needs attention.',
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
              if (issue != null && issue!.isNotEmpty)
                IconButton(
                  tooltip: 'Copy error message',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  icon: const Icon(Icons.copy, size: 18),
                  color: colors.onErrorContainer,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: issue!));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Error message copied')),
                    );
                  },
                ),
            ],
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

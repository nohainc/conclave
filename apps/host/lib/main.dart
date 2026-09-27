import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'adapter_prerequisite.dart';
import 'cloud_connection.dart';
import 'diagnostics.dart';
import 'friendly_computer_name.dart';
import 'host.dart';
import 'host_configuration.dart';
import 'local_worker_setup.dart';
import 'secure_credentials.dart';
import 'secure_credentials_flutter.dart';
import 'v7_adapter_package_store.dart';
import 'v7_adapter_catalog.dart';
import 'workspace_enrollment.dart';
import 'workspace_pairing_dialog.dart';
import 'workspace_runtime.dart';

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
  static const _desktopChannel =
      MethodChannel('com.conclave.workspace/desktop');

  bool get hidden => _hidden;
  bool get quitting => _quitting;
  bool get running => host.isRunning;
  Object? get startupError => _startupError;
  bool get acceptingNewWork => host.cloudConnection?.acceptingNewWork ?? false;
  bool get draining => _draining;

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
    final attention = startupError != null || !running;
    final state = attention
        ? 'Attention'
        : _draining
            ? 'Draining'
            : !(connection?.acceptingNewWork ?? false)
                ? 'Paused'
                : connection?.isConnected == true
                    ? 'Connected'
                    : 'Offline';
    unawaited(_desktopChannel.invokeMethod<void>('status', {
      'state': state,
      'active': connection?.activeAssignmentCount ?? 0,
      'accepting': connection?.acceptingNewWork ?? false,
      'draining': _draining,
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
    final cloudUrl = host.config.cloudUri?.toString() ?? registration?.cloudUrl;
    final workRootPath = host.workRoot?.path ?? host.config.workRootPath;

    if (quitting) {
      return HostUiSnapshot(
        mode: HostUiMode.stopped,
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
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    if (startupError != null) {
      return HostUiSnapshot(
        mode: HostUiMode.offline,
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
        // A saved token can be present and still be revoked in Cloud. Offer
        // explicit recovery for every paired startup failure; the dialog
        // tells the user to unpair in AX before clearing this local identity.
        canRecoverPairing: hostId != null && workspaceId != null,
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
        lastConnectionAttemptAt: connection?.lastConnectionAttemptAt,
      );
    }
    if (host.config.hostId == null) {
      return HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Pair this Workspace',
        detail: 'Connect this machine to Conclave to begin.',
        workspaceName: workspaceName,
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
      );
    }
    if (!running) {
      return HostUiSnapshot(
        mode: HostUiMode.starting,
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
      title: isOffline
          ? 'Workspace is offline'
          : activeAssignments > 0
              ? 'Work in progress'
              : 'Workspace is ready',
      detail: isOffline
          ? activeAssignments > 0
              ? 'Cloud is disconnected. Active work remains on this computer while the Workspace retries.'
              : 'The Workspace is paired, but Cloud has not authenticated this connection.'
          : activeAssignments > 0
              ? 'The Workspace is running assigned work.'
              : 'This machine is paired and ready to run assigned work.',
      issue: isOffline
          ? 'No authenticated Cloud session. Check the saved runtime credential or prepare to pair again.'
          : null,
      workspaceName: workspaceName,
      workspaceId: workspaceId,
      installationId: installationId,
      hostId: hostId,
      hostname: hostname,
      cloudUrl: cloudUrl,
      workRootPath: workRootPath,
      paired: true,
      canRecoverPairing: isOffline && hostId != null && workspaceId != null,
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
    this.canRecoverPairing = false,
    this.cloudConnected = false,
    this.accountsNeedingAction = const [],
    this.workerSummary = 'Worker diagnostics are available after pairing',
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
  final bool canRecoverPairing;
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
  final registration = HostRegistrationStore(dataDirectory).readSync();
  if (registration != null) {
    await credentialStore.readForSynchronousConfig(registration.hostId);
  }
  final config = HostConfig.fromArgs(
    const [],
    credentialStore: credentialStore,
  );
  final host = await buildWorkspaceRuntime(
    config,
    credentialStore: credentialStore,
  );
  runApp(ConclaveHostApp(lifecycle: HostLifecycleController(host)));
}

class ConclaveHostApp extends StatefulWidget {
  const ConclaveHostApp({required this.lifecycle, super.key});

  final HostLifecycleController lifecycle;

  @override
  State<ConclaveHostApp> createState() => _ConclaveHostAppState();
}

class _ConclaveHostAppState extends State<ConclaveHostApp> {
  int _workerRevision = 0;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
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
      }
    });
    unawaited(widget.lifecycle.launch());
  }

  @override
  void dispose() {
    widget.lifecycle.removeListener(_refresh);
    unawaited(widget.lifecycle.quit());
    super.dispose();
  }

  void _refresh() => setState(() {});

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

  Future<void> _pairWorkspace([WorkspacePairingRequest? directRequest]) async {
    final lifecycle = widget.lifecycle;
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final currentRegistration = HostRegistrationStore(dataDirectory).readSync();

    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    if (currentRegistration != null && lifecycle.uiSnapshot.paired) {
      if (mounted) {
        await showDialog<void>(
          context: dialogContext,
          builder: (context) => AlertDialog(
            title: const Text('Already Connected'),
            content: const Text(
              'This installation is already connected to a Workspace.\n\n'
              'Disconnect the current Workspace before connecting to another account.',
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

    final proposedName = await resolveFriendlyComputerName();

    final request = directRequest ??
        await showWorkspacePairingDialog(
          dialogContext,
          initialCloudUrl: currentRegistration?.cloudUrl ??
              Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
              conclaveProductionCloudUrl,
          initialWorkspaceName: proposedName,
        );
    if (request == null || !mounted) return;

    var pairingClaimCompleted = false;
    try {
      final service = WorkspacePairingService(
        dataDirectory: dataDirectory,
        credentialStore: lifecycle.host.credentialStore,
      );
      final installationIdStore = InstallationIdentityStore(dataDirectory);
      final installationId = await installationIdStore.getOrCreate();
      final allowRecovery = installationIdStore.recoveryAuthorizedSync();

      await service.pair(
        cloudUrl: request.cloudUrl,
        token: request.token,
        hostname: Platform.localHostname,
        proposedWorkspaceName: request.workspaceName,
        installationId: installationId,
        allowRecovery: allowRecovery,
      );
      pairingClaimCompleted = true;
      final config = HostConfig.fromArgs(
        const [],
        credentialStore: lifecycle.host.credentialStore,
      );
      final replacement = await buildWorkspaceRuntime(
        config,
        credentialStore: lifecycle.host.credentialStore,
      );
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(content: Text('Workspace paired and connected.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      final displayMessage = pairingClaimCompleted
          ? 'Workspace pairing completed, but the Cloud connection failed:\n$error'
          : error is WorkspacePairingException
              ? '${error.message}\n${error.action}'
              : 'Pairing failed: $error';
      showCopyableErrorSnackBar(dialogContext, displayMessage);
      if (pairingClaimCompleted) throw StateError(displayMessage);
      rethrow;
    }
  }

  Future<void> _disconnectWorkspace() async {
    final lifecycle = widget.lifecycle;
    final registration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    if (registration == null) return;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    if ((lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0) > 0) {
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(
          content: Text('Wait for active work to finish before disconnecting.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect from Conclave AX?'),
        content: const Text(
          'This computer will stop accepting Cloud work.\n\n'
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
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final token =
          await lifecycle.host.credentialStore.read(registration.hostId);
      if (token == null) {
        throw StateError('Workspace credential is missing; reconnect first.');
      }
      await WorkspacePairingService.unpair(
        cloudUrl: registration.cloudUrl,
        token: token,
      );
      await InstallationIdentityStore(lifecycle.host.config.dataDirectory)
          .authorizeRecovery();
      await lifecycle.host.credentialStore.delete(registration.hostId);
      await HostRegistrationStore(lifecycle.host.config.dataDirectory).clear();
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

  Future<void> _preparePairingRecovery() async {
    final lifecycle = widget.lifecycle;
    final dataDirectory = lifecycle.host.config.dataDirectory;
    final registration = HostRegistrationStore(dataDirectory).readSync();
    if (registration == null) return;
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Prepare to pair again?'),
        content: const Text(
          'If this Workspace still appears in Conclave AX, unpair it there '
          'first. If it is already absent, continue here. This clears the '
          'saved Cloud connection so this computer can use a new pairing '
          'code. Local Workers, their credentials, the installation identity, '
          'and Work Root will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Prepare pairing'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await WorkspacePairingService(
        dataDirectory: dataDirectory,
        credentialStore: lifecycle.host.credentialStore,
      ).preparePairingRecovery();
      final replacement = await buildWorkspaceRuntime(
          HostConfig(
            dataDirectory: dataDirectory,
            installationId: registration.installationId ??
                lifecycle.host.config.installationId,
            repositoriesFile: lifecycle.host.config.repositoriesFile,
            workRootPath: lifecycle.host.config.workRootPath,
          ),
          credentialStore: lifecycle.host.credentialStore);
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved connection cleared. Enter a new pairing code from Conclave AX.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        showCopyableErrorSnackBar(
          dialogContext,
          'Could not prepare pairing recovery: $error',
        );
      }
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
          'This completely resets this Conclave Workspace installation on this machine.\n\n'
          'This will revoke Cloud pairing and permanently remove:\n'
          '• Runtime identity & registration\n'
          '• All configured local Workers\n'
          '• All stored credentials and API keys\n'
          '• Installed adapter packages\n\n'
          'This action cannot be undone.',
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
            child: const Text('Reset Everything'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final registration =
          HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
      if (registration != null) {
        final token =
            await lifecycle.host.credentialStore.read(registration.hostId);
        if (token != null) {
          try {
            await WorkspacePairingService.unpair(
              cloudUrl: registration.cloudUrl,
              token: token,
            );
          } catch (_) {
            // Proceed with local reset even if cloud endpoint is unreachable
          }
        }
        await lifecycle.host.credentialStore.delete(registration.hostId);
      }
      final workers = await lifecycle.host.localWorkerRegistry
              ?.list(includeRemoved: true) ??
          const [];
      for (final worker in workers) {
        if (worker.credentialRef != null && worker.credentialRef!.isNotEmpty) {
          await lifecycle.host.credentialStore.delete(worker.credentialRef!);
        }
      }
      final dataDir = lifecycle.host.config.dataDirectory;
      await HostRegistrationStore(dataDir).clear();
      await InstallationIdentityStore(dataDir).clear();
      await LocalWorkspaceIdentityStore(dataDir).clear();
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
              : HostDashboard(
                  snapshot: lifecycle.uiSnapshot,
                  onPair: () => _pairWorkspace(),
                  onPairRequest: _pairWorkspace,
                  onRecoverPairing: _preparePairingRecovery,
                  onDisconnect: _disconnectWorkspace,
                  onUnpair: _disconnectWorkspace,
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
                ),
        ),
      ),
    );
  }
}

class HostDashboard extends StatefulWidget {
  const HostDashboard({
    required this.snapshot,
    this.onPair,
    this.onPairRequest,
    this.onRecoverPairing,
    this.onDisconnect,
    this.onUnpair,
    this.onReset,
    this.onAccountAction,
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
    this.resolveComputerName,
    super.key,
  });

  final HostUiSnapshot snapshot;
  final VoidCallback? onPair;
  final Future<void> Function(WorkspacePairingRequest request)? onPairRequest;
  final Future<void> Function()? onRecoverPairing;
  final VoidCallback? onDisconnect;
  final VoidCallback? onUnpair;
  final VoidCallback? onReset;
  final VoidCallback? onAccountAction;
  final VoidCallback? onQuit;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final int workerRevision;
  final LocalConfiguredWorkerRegistry? localWorkerRegistry;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onAddWorker;
  final Future<String> Function()? resolveComputerName;

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
                    onPair: widget.onPair,
                    onPairRequest: widget.onPairRequest,
                    onRecoverPairing: widget.onRecoverPairing,
                    resolveComputerName: widget.resolveComputerName,
                    onRetry: widget.onRetry,
                    onExportDiagnostics: widget.onExportDiagnostics,
                    onChangeWorkRoot: widget.onChangeWorkRoot,
                    onDisconnect: widget.onDisconnect,
                    onUnpair: widget.onUnpair,
                    onReset: widget.onReset,
                  ),
                  _WorkersTab(
                    key: ValueKey(widget.workerRevision),
                    registry: widget.localWorkerRegistry,
                    credentialStore: widget.credentialStore,
                    adapterPackageStore: widget.adapterPackageStore,
                    ensureAdapter: widget.ensureAdapter,
                    onAddWorker: widget.onAddWorker,
                    isPaired: snapshot.paired,
                    onSwitchToWorkspace: () => setState(
                        () => _selectedSurface = HostSurface.workspace),
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

class _WorkspaceTab extends StatelessWidget {
  const _WorkspaceTab({
    required this.snapshot,
    this.onPair,
    this.onPairRequest,
    this.onRecoverPairing,
    this.resolveComputerName,
    this.onRetry,
    this.onExportDiagnostics,
    this.onChangeWorkRoot,
    this.onDisconnect,
    this.onUnpair,
    this.onReset,
  });

  final HostUiSnapshot snapshot;
  final VoidCallback? onPair;
  final Future<void> Function(WorkspacePairingRequest request)? onPairRequest;
  final Future<void> Function()? onRecoverPairing;
  final Future<String> Function()? resolveComputerName;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final Future<void> Function(String path)? onChangeWorkRoot;
  final VoidCallback? onDisconnect;
  final VoidCallback? onUnpair;
  final VoidCallback? onReset;

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
                canRecoverPairing: snapshot.canRecoverPairing,
                onRecoverPairing: onRecoverPairing,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Section 1: Pairing / Connection Section (Flat light design)
        if (!snapshot.paired)
          _ConnectWorkspaceCard(
            snapshot: snapshot,
            onPair: onPair,
            onPairRequest: onPairRequest,
            resolveComputerName: resolveComputerName,
          )
        else
          _PairedWorkspaceCard(
            snapshot: snapshot,
          ),
        const SizedBox(height: 24),

        // Section 2: Work Root Path with Browse & Open Folder Button (Flat light design)
        _WorkRootSection(
          workRootPath: snapshot.workRootPath,
          onChangeWorkRoot: onChangeWorkRoot,
        ),

        const SizedBox(height: 24),

        // Section 3: Advanced & Diagnostics (Expandable Accordion)
        _WorkspaceDiagnosticsSection(
          snapshot: snapshot,
          onRetry: onRetry,
          onExportDiagnostics: onExportDiagnostics,
          onDisconnect: onDisconnect,
          onUnpair: onUnpair,
          onReset: onReset,
        ),
      ],
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

    return Column(
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
      ],
    );
  }
}

class _ConnectWorkspaceCard extends StatefulWidget {
  const _ConnectWorkspaceCard({
    required this.snapshot,
    this.onPair,
    this.onPairRequest,
    this.resolveComputerName,
  });

  final HostUiSnapshot snapshot;
  final VoidCallback? onPair;
  final Future<void> Function(WorkspacePairingRequest request)? onPairRequest;
  final Future<String> Function()? resolveComputerName;

  @override
  State<_ConnectWorkspaceCard> createState() => _ConnectWorkspaceCardState();
}

class _ConnectWorkspaceCardState extends State<_ConnectWorkspaceCard> {
  late final TextEditingController _nameController;
  late final TextEditingController _codeController;
  bool _isConnecting = false;
  bool _workspaceNameWasEdited = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // This form is shown only while unpaired: use this computer's name, not a
    // stale Workspace display name. Resolve the OS-friendly name asynchronously
    // and retain a fallback immediately while the OS lookup completes.
    final defaultName = resolveFriendlyComputerNameSync(
      localHostname: widget.snapshot.hostname,
    );
    _nameController = TextEditingController(text: defaultName);
    _nameController.addListener(_onWorkspaceNameEdited);
    _codeController = TextEditingController();
    // Only resolve the OS name when this card can actually initiate pairing.
    // Read-only dashboard states (including recovery panels) should not spawn
    // a subprocess just to populate an unused form field.
    if (widget.onPair != null || widget.onPairRequest != null) {
      unawaited(_loadComputerName());
    }
  }

  void _onWorkspaceNameEdited() => _workspaceNameWasEdited = true;

  Future<void> _loadComputerName() async {
    try {
      final resolver = widget.resolveComputerName ??
          () => resolveFriendlyComputerName(
                localHostname: widget.snapshot.hostname,
              );
      final computerName = await resolver();
      final proposedName = computerName.trim();
      if (!mounted || _workspaceNameWasEdited || proposedName.isEmpty) return;
      _nameController.value = TextEditingValue(
        text: proposedName,
        selection: TextSelection.collapsed(offset: proposedName.length),
      );
    } on Object {
      // Keep the cleaned hostname fallback if the OS name cannot be read.
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final code = _codeController.text.trim();
    final cloudUrl = widget.snapshot.cloudUrl ??
        Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
        conclaveProductionCloudUrl;

    if (name.isEmpty) {
      setState(() => _error = 'Enter a workspace name.');
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = 'Enter the pairing code from Conclave AX.');
      return;
    }

    setState(() {
      _isConnecting = true;
      _error = null;
    });

    final request = WorkspacePairingRequest(
      cloudUrl: cloudUrl,
      token: code,
      workspaceName: name,
    );

    try {
      if (widget.onPairRequest != null) {
        await widget.onPairRequest!(request);
      } else if (widget.onPair != null) {
        widget.onPair!();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (e is WorkspacePairingException) {
            _error = '${e.message}\n\n${e.action}';
            if (e.kind == WorkspacePairingErrorKind.invalidCode ||
                e.kind == WorkspacePairingErrorKind.expiredCode ||
                e.kind == WorkspacePairingErrorKind.alreadyUsed) {
              _codeController.clear();
            }
          } else {
            _error = e
                .toString()
                .replaceFirst('Exception: ', '')
                .replaceFirst('StateError: ', '');
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameController,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Workspace name',
            helperText: 'Suggested from this computer. You can change it.',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _codeController,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: 'Pairing code',
            hintText: 'Enter pairing code from Conclave AX',
            border: OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.error.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.3,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy pairing error',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  color: theme.colorScheme.onErrorContainer,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _error!));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Error message copied')),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _isConnecting ? null : _submit,
          icon: _isConnecting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link, size: 16),
          label: Text(_isConnecting ? 'Connecting...' : 'Connect'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
      ],
    );
  }
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
    final connectionLabel = isConnected
        ? 'Connected'
        : snapshot.mode == HostUiMode.starting
            ? 'Connecting...'
            : 'Offline';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Workspace',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          workspaceName,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
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
      ],
    );
  }
}

class _WorkspaceDiagnosticsSection extends StatelessWidget {
  const _WorkspaceDiagnosticsSection({
    required this.snapshot,
    this.onRetry,
    this.onExportDiagnostics,
    this.onDisconnect,
    this.onUnpair,
    this.onReset,
  });

  final HostUiSnapshot snapshot;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final VoidCallback? onDisconnect;
  final VoidCallback? onUnpair;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disconnectAction = onDisconnect ?? onUnpair;

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
              value: snapshot.cloudConnected ? 'Connected' : 'Disconnected',
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
                if (snapshot.paired && disconnectAction != null)
                  OutlinedButton.icon(
                    onPressed: disconnectAction,
                    icon: const Icon(Icons.link_off, size: 14),
                    label: const Text(
                      'Disconnect from Conclave AX',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                if (onReset != null)
                  TextButton.icon(
                    onPressed: onReset,
                    icon: Icon(Icons.delete_forever_outlined,
                        size: 14, color: theme.colorScheme.error),
                    label: Text(
                      'Reset local Workspace',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
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
    super.key,
  });

  final LocalConfiguredWorkerRegistry? registry;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onAddWorker;
  final bool isPaired;
  final VoidCallback? onSwitchToWorkspace;

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
    this.canRecoverPairing = false,
    this.onRecoverPairing,
  });

  final String? issue;
  final String retryLabel;
  final Future<void> Function()? onRetry;
  final bool canRecoverPairing;
  final Future<void> Function()? onRecoverPairing;

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
          if (canRecoverPairing && onRecoverPairing != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => unawaited(onRecoverPairing!()),
              icon: const Icon(Icons.link_off),
              label: const Text('Prepare to pair again'),
            ),
          ],
        ],
      ),
    );
  }
}

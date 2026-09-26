import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'adapter_prerequisite.dart';
import 'diagnostics.dart';
import 'host.dart';
import 'host_configuration.dart';
import 'local_worker_setup.dart';
import 'secure_credentials.dart';
import 'v7_adapter_package_store.dart';
import 'v7_adapter_catalog.dart';
import 'workspace_enrollment.dart';
import 'workspace_pairing_dialog.dart';
import 'workspace_runtime.dart';

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
        await openPath('${host.config.dataDirectory.path}/logs/host.log');
        break;
      case 'openAX':
        await openAX();
        break;
      case 'quit':
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
    final registration =
        HostRegistrationStore(host.config.dataDirectory).readSync();
    final workspaceName = registration?.name ?? 'Conclave Workspace';
    final workspaceId = host.config.workspaceId ?? registration?.workspaceId;
    final hostId = host.config.hostId ?? registration?.hostId;
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
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Stopping',
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
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Offline',
      );
    }
    if (host.config.hostId == null) {
      return HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Pair this Workspace',
        detail: 'Connect this machine to Conclave to begin.',
        workspaceName: workspaceName,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Not paired',
      );
    }
    if (!running) {
      return HostUiSnapshot(
        mode: HostUiMode.starting,
        title: 'Starting Workspace',
        detail: 'Checking this machine and reconnecting to Conclave.',
        workspaceName: workspaceName,
        workspaceId: workspaceId,
        hostId: hostId,
        hostname: hostname,
        cloudUrl: cloudUrl,
        workRootPath: workRootPath,
        statusLabel: 'Starting',
      );
    }
    final connection = host.cloudConnection;
    final activeAssignments = connection?.activeAssignmentCount ?? 0;
    final isConnected = connection?.isConnected ?? false;
    final statusLabel = _draining
        ? 'Draining'
        : !(connection?.acceptingNewWork ?? true)
            ? 'Paused'
            : isConnected
                ? 'Connected'
                : 'Offline';

    return HostUiSnapshot(
      mode: activeAssignments > 0 ? HostUiMode.active : HostUiMode.ready,
      title: activeAssignments > 0 ? 'Work in progress' : 'Workspace is ready',
      detail: activeAssignments > 0
          ? 'The Workspace is running assigned work.'
          : 'This machine is paired and ready to run assigned work.',
      workspaceName: workspaceName,
      workspaceId: workspaceId,
      hostId: hostId,
      hostname: hostname,
      cloudUrl: cloudUrl,
      workRootPath: workRootPath,
      paired: true,
      cloudConnected: isConnected,
      statusLabel: statusLabel,
      logsPath: '${host.config.dataDirectory.path}/logs/host.log',
      activeAssignments: activeAssignments,
      activeAssignmentIds: connection?.activeAssignmentIds ?? const [],
      reconnectCount: connection?.reconnectCount ?? 0,
      sessionId: connection?.sessionId,
      lastInventorySyncAt: connection?.lastInventorySyncAt,
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
    this.hostId,
    this.hostname,
    this.cloudUrl,
    this.workRootPath,
    this.statusLabel = 'Offline',
    this.paired = false,
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
    this.appVersion = conclaveWorkspaceAppVersion,
    this.issue,
  });

  final HostUiMode mode;
  final String title;
  final String detail;
  final String? workspaceName;
  final String? workspaceId;
  final String? hostId;
  final String? hostname;
  final String? cloudUrl;
  final String? workRootPath;
  final String statusLabel;
  final bool paired;
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
  final String appVersion;
  final String? issue;

  bool get hasLocalAction =>
      accountsNeedingAction.isNotEmpty ||
      mode == HostUiMode.authNeeded ||
      mode == HostUiMode.installFailure;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = HostConfig.fromArgs(const []);
  final host = await buildWorkspaceRuntime(config);
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

  @override
  void initState() {
    super.initState();
    widget.lifecycle.addListener(_refresh);
    const desktopChannel = MethodChannel('com.conclave.workspace/desktop');
    desktopChannel.setMethodCallHandler((call) async {
      if (call.method == 'menuAction' && call.arguments is String) {
        await widget.lifecycle.handleDesktopAction(call.arguments as String);
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
    final activeCount = widget.lifecycle.host.cloudConnection?.activeAssignmentCount ?? 0;
    final shouldQuit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quit Conclave Workspace?'),
        content: Text(
          activeCount > 0
              ? 'There ${activeCount == 1 ? 'is 1 active assignment running' : 'are $activeCount active assignments running'}. '
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
    if (shouldQuit == true) await widget.lifecycle.quit();
  }

  Future<void> _exportDiagnostics() async {
    final file = await widget.lifecycle.exportDiagnostics();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Diagnostics exported to ${file.path}')),
    );
  }

  Future<void> _pairWorkspace() async {
    final lifecycle = widget.lifecycle;
    final currentRegistration =
        HostRegistrationStore(lifecycle.host.config.dataDirectory).readSync();
    final request = await showWorkspacePairingDialog(
      context,
      initialCloudUrl: currentRegistration?.cloudUrl ??
          Platform.environment['CONCLAVE_HOST_CLOUD_URL'] ??
          conclaveProductionCloudUrl,
    );
    if (request == null || !mounted) return;

    try {
      final service = WorkspacePairingService(
        dataDirectory: lifecycle.host.config.dataDirectory,
        credentialStore: lifecycle.host.credentialStore,
      );
      await service.pair(
        cloudUrl: request.cloudUrl,
        token: request.token,
        hostname: Platform.localHostname,
      );
      final config = HostConfig.fromArgs(
        const [],
        credentialStore: lifecycle.host.credentialStore,
      );
      final replacement = await buildWorkspaceRuntime(config);
      await lifecycle.replaceHost(replacement);
      if (mounted) {
        setState(() => _workerRevision++);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workspace paired and connected.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pairing failed: $error')),
      );
    }
  }

  Future<void> _addLocalWorker(BuildContext context) async {
    final registry = widget.lifecycle.host.localWorkerRegistry;
    if (registry == null) return;
    final added = await showDialog<bool>(
      context: context,
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
    final cloudUri = host.config.cloudUri;
    if (cloudUri == null) return false;
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

  @override
  Widget build(BuildContext context) {
    final lifecycle = widget.lifecycle;
    return MaterialApp(
      title: 'Conclave Workspace',
      debugShowCheckedModeBanner: false,
      theme: ConclaveBrand.lightTheme(),
      darkTheme: ConclaveBrand.darkTheme(),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: lifecycle.hidden
            ? const Center(
                child: Text('Workspace is running in the background.'))
            : HostDashboard(
                snapshot: lifecycle.uiSnapshot,
                onPair: _pairWorkspace,
                onQuit: _confirmQuit,
                onRetry: lifecycle.launch,
                onExportDiagnostics: _exportDiagnostics,
                workerRevision: _workerRevision,
                localWorkerRegistry: lifecycle.host.localWorkerRegistry,
                credentialStore: lifecycle.host.credentialStore,
                adapterPackageStore: lifecycle.host.adapterPackageStore,
                ensureAdapter: _ensureAdapterAvailable,
                onAddWorker: () => _addLocalWorker(context),
              ),
      ),
    );
  }
}

class HostDashboard extends StatefulWidget {
  const HostDashboard({
    required this.snapshot,
    this.onPair,
    this.onAccountAction,
    this.onQuit,
    this.onRetry,
    this.onExportDiagnostics,
    this.workerRevision = 0,
    this.localWorkerRegistry,
    this.credentialStore = const PlatformSecureCredentialStore(),
    this.adapterPackageStore,
    this.ensureAdapter,
    this.onAddWorker,
    super.key,
  });

  final HostUiSnapshot snapshot;
  final VoidCallback? onPair;
  final VoidCallback? onAccountAction;
  final VoidCallback? onQuit;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExportDiagnostics;
  final int workerRevision;
  final LocalConfiguredWorkerRegistry? localWorkerRegistry;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onAddWorker;

  @override
  State<HostDashboard> createState() => _HostDashboardState();
}

class _HostDashboardState extends State<HostDashboard> {
  int _selectedTabIndex = 0;

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
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
              ConclaveBrand.logoMark(size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        snapshot.workspaceName ?? 'Conclave Workspace',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 7, color: statusColor),
                          const SizedBox(width: 5),
                          Text(
                            snapshot.statusLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => HostLifecycleController.openAX(),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('Open Conclave AX',
                    style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Quit Workspace',
                icon: const Icon(Icons.power_settings_new, size: 18),
                onPressed: widget.onQuit,
              ),
            ],
          ),
        ),

        // Navigation and Content Area
        Expanded(
          child: Row(
            children: [
              NavigationRail(
                selectedIndex: _selectedTabIndex,
                onDestinationSelected: (index) =>
                    setState(() => _selectedTabIndex = index),
                labelType: NavigationRailLabelType.all,
                minWidth: 72,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: Text('Overview'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.memory_outlined),
                    selectedIcon: Icon(Icons.memory),
                    label: Text('Workers'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('Settings'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.analytics_outlined),
                    selectedIcon: Icon(Icons.analytics),
                    label: Text('Diagnostics'),
                  ),
                ],
              ),
              const VerticalDivider(thickness: 1, width: 1),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: switch (_selectedTabIndex) {
                      0 => _OverviewTab(
                          snapshot: snapshot,
                          onPair: widget.onPair,
                          onRetry: widget.onRetry,
                          onAccountAction: widget.onAccountAction,
                          onNavigateToWorkers: () =>
                              setState(() => _selectedTabIndex = 1),
                          localWorkerRegistry: widget.localWorkerRegistry,
                          credentialStore: widget.credentialStore,
                          adapterPackageStore: widget.adapterPackageStore,
                          ensureAdapter: widget.ensureAdapter,
                          onAddWorker: widget.onAddWorker,
                          workerRevision: widget.workerRevision,
                        ),
                      1 => _WorkersTab(
                          key: ValueKey(widget.workerRevision),
                          registry: widget.localWorkerRegistry,
                          credentialStore: widget.credentialStore,
                          adapterPackageStore: widget.adapterPackageStore,
                          ensureAdapter: widget.ensureAdapter,
                          onAddWorker: widget.onAddWorker,
                        ),
                      2 => _SettingsTab(
                          snapshot: snapshot,
                          onPair: widget.onPair,
                          onQuit: widget.onQuit,
                        ),
                      3 => _DiagnosticsTab(
                          snapshot: snapshot,
                          onExportDiagnostics: widget.onExportDiagnostics,
                        ),
                      _ => const SizedBox.shrink(),
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.snapshot,
    this.onPair,
    this.onRetry,
    this.onAccountAction,
    required this.onNavigateToWorkers,
    this.localWorkerRegistry,
    required this.credentialStore,
    this.adapterPackageStore,
    this.ensureAdapter,
    this.onAddWorker,
    this.workerRevision = 0,
  });

  final HostUiSnapshot snapshot;
  final VoidCallback? onPair;
  final Future<void> Function()? onRetry;
  final VoidCallback? onAccountAction;
  final VoidCallback onNavigateToWorkers;
  final LocalConfiguredWorkerRegistry? localWorkerRegistry;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onAddWorker;
  final int workerRevision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = snapshot.mode == HostUiMode.offline ||
        snapshot.mode == HostUiMode.installFailure;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Semantics(
          header: true,
          child: Text('Machine status', style: theme.textTheme.labelLarge),
        ),
        const SizedBox(height: 8),

        // Main Machine Status Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      snapshot.cloudConnected
                          ? Icons.cloud_done
                          : Icons.cloud_off,
                      size: 20,
                      color: snapshot.cloudConnected
                          ? ConclaveBrand.success
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        snapshot.title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  snapshot.detail,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isError)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _HostRecoveryPanel(
                      issue: snapshot.issue,
                      retryLabel: snapshot.mode == HostUiMode.offline
                          ? 'Retry connection'
                          : 'Retry update',
                      onRetry: onRetry,
                    ),
                  ),
                if (snapshot.mode == HostUiMode.firstLaunch) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: onPair,
                    icon: const Icon(Icons.link),
                    label: const Text('Start pairing'),
                  ),
                ],
              ],
            ),
          ),
        ),

        if (snapshot.hasLocalAction) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Accounts needing attention',
            icon: Icons.key,
            summary: snapshot.accountsNeedingAction.isEmpty
                ? 'Complete local sign-in to run work.'
                : snapshot.accountsNeedingAction.join(', '),
            actionLabel: 'Open account setup',
            onAction: onAccountAction,
          ),
        ],

        const SizedBox(height: 16),

        // Current Work Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.work_outline, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      'Current Work',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (snapshot.activeAssignments > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: ConclaveBrand.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${snapshot.activeAssignments} active',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: ConclaveBrand.accent,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (snapshot.activeAssignments == 0)
                  Text(
                    'No assignments running. This Workspace is ready to run assigned work from Conclave Cloud.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else ...[
                  Text(
                    '${snapshot.activeAssignments} active assignment${snapshot.activeAssignments == 1 ? '' : 's'} running on this machine:',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final id in snapshot.activeAssignmentIds)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.play_arrow,
                              size: 14, color: ConclaveBrand.accent),
                          const SizedBox(width: 8),
                          Text(id,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12)),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Workers Summary Card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.memory, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      'Workers',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: onAddWorker,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add Worker'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (localWorkerRegistry == null)
                  const Text(
                      'Pair this Workspace before configuring local Workers.')
                else
                  FutureBuilder<List<LocalConfiguredWorker>>(
                    key: ValueKey(workerRevision),
                    future: localWorkerRegistry!.list(),
                    builder: (context, workerSnapshot) {
                      final workers = workerSnapshot.data ?? const [];
                      if (workers.isEmpty) {
                        return Text(
                          'No local Workers configured yet. Add a Worker to enable AI execution on this machine.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        );
                      }
                      final readyCount = workers
                          .where((w) => w.status == LocalWorkerStatus.ready)
                          .length;
                      final attentionCount = workers
                          .where((w) =>
                              w.status == LocalWorkerStatus.needsAttention)
                          .length;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _StatusCountChip(
                                count: readyCount,
                                label: 'Ready',
                                color: ConclaveBrand.success,
                              ),
                              const SizedBox(width: 8),
                              if (attentionCount > 0)
                                _StatusCountChip(
                                  count: attentionCount,
                                  label: 'Needs attention',
                                  color: ConclaveBrand.warning,
                                ),
                              const Spacer(),
                              TextButton(
                                onPressed: onNavigateToWorkers,
                                child: const Text('View all →'),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Machine & Work Root section
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      'Work Root',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (snapshot.workRootPath != null)
                      TextButton.icon(
                        onPressed: () =>
                            HostLifecycleController.openPath(snapshot.workRootPath!),
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Open in Finder'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  snapshot.workRootPath ?? 'Work root directory not initialized yet.',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.system_update_alt, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'App Version: v${snapshot.appVersion} · ${snapshot.updateSummary}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusCountChip extends StatelessWidget {
  const _StatusCountChip({
    required this.count,
    required this.label,
    required this.color,
  });

  final int count;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$count $label',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
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
    super.key,
  });

  final LocalConfiguredWorkerRegistry? registry;
  final SecureCredentialStore credentialStore;
  final V7AdapterPackageStore? adapterPackageStore;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onAddWorker;

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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Configured Workers',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'Local AI models and execution adapters running on this machine.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const Spacer(),
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
                  'Pair this Workspace before configuring local Workers.'),
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
                                  color: theme.colorScheme.surfaceContainerHighest
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
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
                                        _WorkerStatusBadge(status: worker.status),
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

class _WorkerStatusBadge extends StatelessWidget {
  const _WorkerStatusBadge({required this.status});

  final LocalWorkerStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      LocalWorkerStatus.ready => ('Ready', ConclaveBrand.success),
      LocalWorkerStatus.needsAttention =>
        ('Needs attention', ConclaveBrand.warning),
      LocalWorkerStatus.disabled => ('Disabled', Colors.grey),
      LocalWorkerStatus.removed => ('Removed', ConclaveBrand.error),
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
    final friendlyType = _WorkersTabState._friendlyTypeName(worker.workerTypeId);

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
          _WorkerStatusBadge(status: worker.status),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Worker Type: $friendlyType',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              _DetailRow(
                label: 'Default Model',
                value: worker.defaultModel ?? 'Not specified',
              ),
              if (worker.allowedModels.isNotEmpty)
                _DetailRow(
                  label: 'Allowed Models',
                  value: worker.allowedModels.join(', '),
                ),
              _DetailRow(
                label: 'Authentication',
                value: switch (worker.authStrategy) {
                  'api_key' => 'Encrypted API key on this machine',
                  'browser_auth' => 'Signed in locally via browser / CLI',
                  'local_endpoint' => 'Local service endpoint',
                  _ => worker.authStrategy,
                },
              ),
              if (worker.adapterConfig['endpointUrl'] != null)
                _DetailRow(
                  label: 'Endpoint URL',
                  value: worker.adapterConfig['endpointUrl'] as String,
                ),
              const SizedBox(height: 8),
              Text(
                'Granted Local Permissions:',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              if (worker.localPermissions.isEmpty)
                Text('No permissions granted',
                    style: theme.textTheme.bodySmall)
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final perm in worker.localPermissions)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(perm, style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  'Advanced Technical Details',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                children: [
                  _DetailRow(label: 'Worker ID', value: worker.id),
                  _DetailRow(
                      label: 'Revision', value: 'r${worker.revision}'),
                  if (worker.credentialRef != null)
                    _DetailRow(
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

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({
    required this.snapshot,
    this.onPair,
    this.onQuit,
  });

  final HostUiSnapshot snapshot;
  final VoidCallback? onPair;
  final VoidCallback? onQuit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Settings',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          'Workspace machine configuration and cloud pairing.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),

        // Work Root card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.folder_open, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Work Root Directory',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                    const SizedBox(width: 8),
                    if (snapshot.workRootPath != null)
                      FilledButton.tonalIcon(
                        onPressed: () => HostLifecycleController.openPath(
                            snapshot.workRootPath!),
                        icon: const Icon(Icons.folder, size: 16),
                        label: const Text('Open Folder'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  snapshot.workRootPath ?? 'Not configured',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  'Workstream checkouts and local code isolation reside under this path. Each assignment is executed within its dedicated ID-only directory.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Application Updates card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.system_update_alt, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Application Updates',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: ConclaveBrand.success.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Up to date',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: ConclaveBrand.success,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Installed version: v${snapshot.appVersion}'),
                Text('Update channel: Stable',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Pairing details card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.cloud_sync, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Cloud Pairing',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: onPair,
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('Re-pair Workspace'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  label: 'Cloud URL',
                  value: snapshot.cloudUrl ?? 'Not configured',
                ),
                _DetailRow(
                  label: 'Workspace Name',
                  value: snapshot.workspaceName ?? 'Not configured',
                ),
                _DetailRow(
                  label: 'Workspace ID',
                  value: snapshot.workspaceId ?? snapshot.hostId ?? 'Not paired',
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: onQuit,
          icon: const Icon(Icons.power_settings_new),
          label: const Text('Quit Workspace'),
        ),
      ],
    );
  }
}

class _DiagnosticsTab extends StatelessWidget {
  const _DiagnosticsTab({
    required this.snapshot,
    this.onExportDiagnostics,
  });

  final HostUiSnapshot snapshot;
  final Future<void> Function()? onExportDiagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Diagnostics',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    'Runtime state, connection metrics, and system identity.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: onExportDiagnostics,
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Export Report'),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Connection Telemetry
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.wifi_tethering, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Cloud Gateway Connection',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      snapshot.cloudConnected ? 'Connected' : 'Disconnected',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: snapshot.cloudConnected
                            ? ConclaveBrand.success
                            : ConclaveBrand.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  label: 'Gateway URL',
                  value: snapshot.cloudUrl ?? 'Not configured',
                ),
                _DetailRow(
                  label: 'Session ID',
                  value: snapshot.sessionId ?? 'No active session',
                ),
                _DetailRow(
                  label: 'Reconnect Count',
                  value: '${snapshot.reconnectCount}',
                ),
                _DetailRow(
                  label: 'Active Work',
                  value: '${snapshot.activeAssignments} assignments',
                ),
                if (snapshot.lastInventorySyncAt != null)
                  _DetailRow(
                    label: 'Last Inventory Sync',
                    value: snapshot.lastInventorySyncAt!.toLocal().toString(),
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Identity & Machine info
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.fingerprint, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Machine & Runtime Identity',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _CopyableDetailRow(
                  label: 'Workspace ID',
                  value: snapshot.workspaceId ?? snapshot.hostId ?? 'Not paired',
                ),
                _CopyableDetailRow(
                  label: 'Runtime ID',
                  value: snapshot.hostId ?? 'Not assigned',
                ),
                _CopyableDetailRow(
                  label: 'Local Hostname',
                  value: snapshot.hostname ?? Platform.localHostname,
                ),
                _DetailRow(
                  label: 'OS Platform',
                  value: '${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Logs viewer
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.receipt_long, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Runtime Logs',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                    ),
                    const SizedBox(width: 8),
                    if (snapshot.logsPath != null)
                      TextButton.icon(
                        onPressed: () => HostLifecycleController.openPath(
                            snapshot.logsPath!),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Open Log File'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  snapshot.logsPath ?? 'Logs will appear after first launch.',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.summary,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final IconData icon;
  final String summary;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(summary),
                  if (actionLabel != null) ...[
                    const SizedBox(height: 10),
                    TextButton(onPressed: onAction, child: Text(actionLabel!)),
                  ],
                ],
              ),
            ),
          ],
        ),
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
          Text(issue ?? 'The Workspace needs attention.',
              style: TextStyle(color: colors.onErrorContainer)),
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

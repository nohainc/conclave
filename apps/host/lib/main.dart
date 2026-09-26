import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import 'brand.dart';
import 'adapter_prerequisite.dart';
import 'diagnostics.dart';
import 'host.dart';
import 'local_worker_setup.dart';
import 'secure_credentials.dart';
import 'v7_adapter_package_store.dart';
import 'v7_adapter_catalog.dart';

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
  return AdapterPrerequisiteResult(
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
  return false;
}

Future<bool> _validateLocalApiCredential(
  V7AdapterPackageStore? packageStore,
  String workerTypeId,
  String apiKey,
  String endpointUrl,
  List<String> permissions,
) async {
  if (packageStore == null) return false;
  try {
    await packageStore.validateApiCredential(
      workerTypeId: workerTypeId,
      apiKey: apiKey,
      endpointUrl: endpointUrl,
      localPermissions: permissions,
    );
    return true;
  } on Object {
    return false;
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
  throw StateError(
      'Sign-in setup is not available for this Worker Type yet.');
}

class HostLifecycleController extends ChangeNotifier {
  HostLifecycleController(this.host);

  final Host host;
  bool _hidden = false;
  bool _quitting = false;
  Object? _startupError;

  bool get hidden => _hidden;
  bool get quitting => _quitting;
  bool get running => host.isRunning;
  Object? get startupError => _startupError;

  HostUiSnapshot get uiSnapshot {
    if (quitting) {
      return const HostUiSnapshot(
        mode: HostUiMode.stopped,
        title: 'Stopping Workspace',
        detail: 'Active local work is being reconciled safely.',
      );
    }
    if (startupError != null) {
      return HostUiSnapshot(
        mode: HostUiMode.offline,
        title: 'Workspace is offline',
        detail: 'The Workspace could not connect. It will be safe to retry.',
        issue: startupError.toString(),
      );
    }
    if (host.config.hostId == null) {
      return const HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Pair this Workspace',
        detail: 'Connect this machine to Conclave to begin.',
      );
    }
    if (!running) {
      return const HostUiSnapshot(
        mode: HostUiMode.starting,
        title: 'Starting Workspace',
        detail: 'Checking this machine and reconnecting to Conclave.',
      );
    }
    final connection = host.cloudConnection;
    final activeAssignments = connection?.activeAssignmentCount ?? 0;
    return HostUiSnapshot(
      mode: activeAssignments > 0 ? HostUiMode.active : HostUiMode.ready,
      title: activeAssignments > 0 ? 'Work in progress' : 'Workspace is ready',
      detail: activeAssignments > 0
          ? 'The Workspace is running assigned work.'
          : 'This machine is paired and ready to run assigned work.',
      hostId: host.config.hostId,
      paired: true,
      cloudConnected: connection?.isConnected ?? false,
      logsPath: '${host.config.dataDirectory.path}/logs/host.log',
      activeAssignments: activeAssignments,
    );
  }

  Future<void> launch() async {
    try {
      await host.start();
    } catch (error) {
      _startupError = error;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
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
    notifyListeners();
    await host.stop();
    notifyListeners();
  }

  Future<File> exportDiagnostics() => writeHostDiagnostics(
        config: host.config,
        connection: host.cloudConnection,
        journal: host.cloudConnection?.assignmentJournal,
      );
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
    this.hostId,
    this.paired = false,
    this.cloudConnected = false,
    this.accountsNeedingAction = const [],
    this.repositorySummary = 'No repositories registered',
    this.permissionSummary = 'Permissions have not been checked',
    this.workerSummary = 'Worker diagnostics are available after pairing',
    this.logsPath,
    this.updateSummary = 'Up to date',
    this.activeAssignments = 0,
    this.issue,
  });

  final HostUiMode mode;
  final String title;
  final String detail;
  final String? hostId;
  final bool paired;
  final bool cloudConnected;
  final List<String> accountsNeedingAction;
  final String repositorySummary;
  final String permissionSummary;
  final String workerSummary;
  final String? logsPath;
  final String updateSummary;
  final int activeAssignments;
  final String? issue;

  bool get hasLocalAction =>
      accountsNeedingAction.isNotEmpty ||
      mode == HostUiMode.authNeeded ||
      mode == HostUiMode.installFailure;
}

void main() {
  final host = Host(config: HostConfig.fromArgs(const []));
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
    final shouldQuit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quit Conclave Workspace?'),
        content: const Text(
            'Active work will be reconciled safely before this machine disconnects. You can start the Workspace again later.'),
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

  Future<void> _addLocalWorker(BuildContext context) async {
    final registry = widget.lifecycle.host.localWorkerRegistry;
    if (registry == null) return;
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => AddLocalWorkerDialog(
        registry: registry,
        credentialStore: widget.lifecycle.host.credentialStore,
        // A Worker is never marked Ready until a verified adapter is
        // installed and its provider authentication can be validated.
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
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: ConclaveBrand.paper,
        colorScheme: ColorScheme.fromSeed(seedColor: ConclaveBrand.accent),
        appBarTheme: const AppBarTheme(
          backgroundColor: ConclaveBrand.paper,
          foregroundColor: ConclaveBrand.ink,
          elevation: 0,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: ConclaveBrand.accent,
                  borderRadius: BorderRadius.all(Radius.circular(9)),
                ),
                alignment: Alignment.center,
                child: const Text('C',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17)),
              ),
              const SizedBox(width: 10),
              const Text('Conclave Workspace'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: lifecycle.hidden ? 'Restore' : 'Minimize',
              onPressed:
                  lifecycle.hidden ? lifecycle.restore : lifecycle.minimize,
              icon: Icon(
                lifecycle.hidden ? Icons.open_in_full : Icons.remove,
              ),
            ),
            IconButton(
              tooltip: 'Quit Workspace',
              onPressed: _confirmQuit,
              icon: const Icon(Icons.power_settings_new),
            ),
          ],
        ),
        body: Center(
          child: lifecycle.hidden
              ? const Text('Workspace is running in the background.')
              : HostDashboard(
                  snapshot: lifecycle.uiSnapshot,
                  onPair: lifecycle.restore,
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
      ),
    );
  }
}

class HostDashboard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = snapshot.mode == HostUiMode.offline ||
        snapshot.mode == HostUiMode.installFailure;
    final statusColor = isError
        ? theme.colorScheme.error
        : snapshot.mode == HostUiMode.active
            ? theme.colorScheme.primary
            : theme.colorScheme.tertiary;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Semantics(
              header: true,
              child: Text('Machine status', style: theme.textTheme.labelLarge),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.circle, size: 14, color: statusColor),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(snapshot.title,
                              style: theme.textTheme.headlineSmall),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(snapshot.detail),
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
                    if (snapshot.mode == HostUiMode.active)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                            '${snapshot.activeAssignments} active assignment${snapshot.activeAssignments == 1 ? '' : 's'}'),
                      ),
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
            _SectionCard(
              title: 'Repositories and permissions',
              icon: Icons.folder_open,
              summary:
                  '${snapshot.repositorySummary}. ${snapshot.permissionSummary}.',
            ),
            const SizedBox(height: 12),
            _LocalWorkersCard(
              key: ValueKey(workerRevision),
              registry: localWorkerRegistry,
              credentialStore: credentialStore,
              adapterPackageStore: adapterPackageStore,
              ensureAdapter: ensureAdapter,
              onAddWorker: onAddWorker,
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Logs',
              icon: Icons.receipt_long,
              summary:
                  snapshot.logsPath ?? 'Logs will appear after first launch.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onExportDiagnostics,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Export diagnostics'),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Updates',
              icon: Icons.system_update_alt,
              summary: snapshot.updateSummary,
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              leading: const Icon(Icons.tune),
              title: const Text('Advanced details'),
              subtitle: Text(snapshot.paired
                  ? 'Workspace ID and connection details'
                  : 'Diagnostics become available after pairing'),
              children: [
                ListTile(
                  title: const Text('Workspace ID'),
                  subtitle: Text(snapshot.hostId ?? 'Not paired'),
                ),
                ListTile(
                  title: const Text('Cloud connection'),
                  subtitle: Text(
                      snapshot.cloudConnected ? 'Connected' : 'Not connected'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onQuit,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('Quit Workspace'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalWorkersCard extends StatefulWidget {
  const _LocalWorkersCard({
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
  State<_LocalWorkersCard> createState() => _LocalWorkersCardState();
}

class _LocalWorkersCardState extends State<_LocalWorkersCard> {
  Future<List<LocalConfiguredWorker>>? _workers;

  @override
  void initState() {
    super.initState();
    _loadWorkers();
  }

  @override
  void didUpdateWidget(covariant _LocalWorkersCard oldWidget) {
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

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.memory),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text('Workers',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  FilledButton.tonalIcon(
                    onPressed:
                        widget.registry == null ? null : widget.onAddWorker,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Worker'),
                  ),
                ],
              ),
              if (widget.registry == null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                      'Pair this Workspace before configuring local Workers.'),
                )
              else
                FutureBuilder<List<LocalConfiguredWorker>>(
                  future: _workers,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                            'Worker registry needs repair: ${snapshot.error}',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: LinearProgressIndicator(),
                      );
                    }
                    final workers = snapshot.data!;
                    if (workers.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                            'No local Workers yet. Add one to configure this machine.'),
                      );
                    }
                    return Column(
                      children: [
                        const SizedBox(height: 8),
                        for (final worker in workers)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              worker.status == LocalWorkerStatus.ready
                                  ? Icons.check_circle_outline
                                  : worker.status == LocalWorkerStatus.disabled
                                      ? Icons.pause_circle_outline
                                      : Icons.error_outline,
                            ),
                            title: Text(worker.name),
                            subtitle: Text(
                                '${worker.workerTypeId} · ${_statusLabel(worker.status)}'
                                '${worker.defaultModel == null ? '' : ' · ${worker.defaultModel}'}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('r${worker.revision}'),
                                PopupMenuButton<String>(
                                  tooltip: 'Worker actions',
                                  onSelected: (action) {
                                    if (action == 'edit') {
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
                                      value: 'edit',
                                      child: Text('Edit configuration'),
                                    ),
                                    if (worker.status ==
                                        LocalWorkerStatus.disabled)
                                      const PopupMenuItem(
                                        value: 'enable',
                                        child: Text('Enable scheduling'),
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
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      );

  String _statusLabel(LocalWorkerStatus status) => switch (status) {
        LocalWorkerStatus.ready => 'Ready',
        LocalWorkerStatus.needsAttention => 'Needs attention',
        LocalWorkerStatus.disabled => 'Disabled',
        LocalWorkerStatus.removed => 'Removed',
      };
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

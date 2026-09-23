import 'dart:async';
import 'package:flutter/material.dart';

import 'host.dart';

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
        title: 'Stopping Host',
        detail: 'Active local work is being reconciled safely.',
      );
    }
    if (startupError != null) {
      return HostUiSnapshot(
        mode: HostUiMode.offline,
        title: 'Host is offline',
        detail: 'The Host could not connect. It will be safe to retry.',
        issue: startupError.toString(),
      );
    }
    if (host.config.hostId == null) {
      return const HostUiSnapshot(
        mode: HostUiMode.firstLaunch,
        title: 'Pair this Host',
        detail: 'Connect this machine to Conclave to begin.',
      );
    }
    if (!running) {
      return const HostUiSnapshot(
        mode: HostUiMode.starting,
        title: 'Starting Host',
        detail: 'Checking this machine and reconnecting to Conclave.',
      );
    }
    final connection = host.cloudConnection;
    final activeAssignments = connection?.activeAssignmentCount ?? 0;
    return HostUiSnapshot(
      mode: activeAssignments > 0 ? HostUiMode.active : HostUiMode.ready,
      title: activeAssignments > 0 ? 'Work in progress' : 'Host is ready',
      detail: activeAssignments > 0
          ? 'The Host is running assigned work.'
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

  @override
  Widget build(BuildContext context) {
    final lifecycle = widget.lifecycle;
    return MaterialApp(
      title: 'Conclave Host',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Conclave Host'),
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
              tooltip: 'Quit Host',
              onPressed: lifecycle.quit,
              icon: const Icon(Icons.power_settings_new),
            ),
          ],
        ),
        body: Center(
          child: lifecycle.hidden
              ? const Text('Host is running in the background.')
              : HostDashboard(
                  snapshot: lifecycle.uiSnapshot,
                  onPair: lifecycle.restore,
                  onQuit: lifecycle.quit,
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
    super.key,
  });

  final HostUiSnapshot snapshot;
  final VoidCallback? onPair;
  final VoidCallback? onAccountAction;
  final VoidCallback? onQuit;

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
                    if (snapshot.issue != null) ...[
                      const SizedBox(height: 12),
                      Text(snapshot.issue!,
                          style: TextStyle(color: theme.colorScheme.error)),
                    ],
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
            _SectionCard(
              title: 'Worker diagnostics',
              icon: Icons.memory,
              summary: snapshot.workerSummary,
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Logs',
              icon: Icons.receipt_long,
              summary:
                  snapshot.logsPath ?? 'Logs will appear after first launch.',
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
                  ? 'Host ID and connection details'
                  : 'Diagnostics become available after pairing'),
              children: [
                ListTile(
                  title: const Text('Host ID'),
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
              label: const Text('Quit Host'),
            ),
          ],
        ),
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

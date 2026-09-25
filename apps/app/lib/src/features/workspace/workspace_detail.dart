import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';
import '../common/workspace_release.dart';

/// Contextual Workspace detail view for runtime state and configured Workers.
class WorkspaceDetailView extends StatefulWidget {
  const WorkspaceDetailView({
    super.key,
    required this.workspace,
    this.configuredWorkers = const [],
    required this.onBack,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
    required this.onConnect,
    this.onOpenDownloads,
    this.initialTab = 0,
    this.onOpenConfiguredWorker,
    this.onSetupConfiguredWorkerWorkspace,
    this.onRemoveConfiguredWorkerWorkspace,
  });

  final StudioAgent workspace;
  final List<StudioConfiguredWorker> configuredWorkers;
  final VoidCallback onBack;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;
  final Future<void> Function(StudioAgent) onConnect;
  final VoidCallback? onOpenDownloads;
  final int initialTab;
  final ValueChanged<StudioConfiguredWorker>? onOpenConfiguredWorker;
  final Future<void> Function(
          StudioConfiguredWorker worker, String workspaceId, String action)?
      onSetupConfiguredWorkerWorkspace;
  final Future<void> Function(
          StudioConfiguredWorker worker, String workspaceId)?
      onRemoveConfiguredWorkerWorkspace;

  @override
  State<WorkspaceDetailView> createState() => _WorkspaceDetailViewState();
}

class _WorkspaceDetailViewState extends State<WorkspaceDetailView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 5,
      initialIndex: widget.initialTab.clamp(0, 4),
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(WorkspaceDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.clamp(0, 4));
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        final activeIndex = _tabController.index;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back to Workspaces',
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    widget.workspace.name,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Workspace actions',
                  onSelected: (action) {
                    if (action == 'rename') widget.onRename(widget.workspace);
                    if (action == 'update') widget.onUpdate(widget.workspace);
                    if (action == 'revoke') widget.onRevoke(widget.workspace);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(
                        value: 'update', child: Text('Update Workspace')),
                    PopupMenuItem(
                        value: 'revoke', child: Text('Revoke Workspace')),
                  ],
                ),
              ],
            ),
            Text(
              '${widget.workspace.os} · ${widget.workspace.architecture} · ${_statusLabel(widget.workspace.status)}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabs: const [
                Tab(text: 'Overview'),
                Tab(text: 'Workers'),
                Tab(text: 'Project access'),
                Tab(text: 'Activity'),
                Tab(text: 'Settings'),
              ],
            ),
            const SizedBox(height: 14),
            switch (activeIndex) {
              0 => _overview(),
              1 => _workers(),
              2 => _projectAccess(),
              3 => _activity(),
              _ => _settings(),
            },
          ],
        );
      },
    );
  }

  Widget _overview() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Panel(
            title: 'Workspace overview',
            subtitle:
                'Runtime identity and current capacity for ${widget.workspace.name}.',
            child: Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                Text('Status: ${_statusLabel(widget.workspace.status)}'),
                Text(
                    'Machine: ${_machineLabel(widget.workspace.os, widget.workspace.architecture)}'),
                Text('Hostname: ${widget.workspace.hostname}'),
                Text('Conclave Workspace: ${widget.workspace.appVersion}'),
                if (widget.workspace.runtimeCapabilities.isNotEmpty)
                  Text(
                      'Runtime capabilities: ${widget.workspace.runtimeCapabilities.join(', ')}'),
                Text(
                    'Current load: ${widget.workspace.activeTaskCount} active tasks'),
                Text('Last seen: ${widget.workspace.lastSeen}'),
                Text('Runtime: ${widget.workspace.version}'),
                if (!_isInstalled) ...[
                  const Text('No machine is connected to this Workspace yet.'),
                  FilledButton.icon(
                    onPressed: () => widget.onConnect(widget.workspace),
                    icon: const Icon(Icons.link_outlined),
                    label: const Text('Connect machine'),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenDownloads,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Download Conclave Workspace'),
                  ),
                ],
              ],
            ),
          ),
          _workspaceReleasePanel(),
        ],
      );

  bool get _isInstalled =>
      widget.workspace.appVersion.trim().isNotEmpty &&
      widget.workspace.appVersion != '—';

  Widget _workspaceReleasePanel() => _Panel(
        title: 'Conclave Workspace',
        subtitle: 'Runtime installation and release status.',
        child: _isInstalled
            ? Wrap(
                spacing: 24,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Installed\n${widget.workspace.appVersion}'),
                  const Text('Latest\n$conclaveWorkspaceLatestVersion'),
                  if (workspaceUpdateAvailable(widget.workspace.appVersion))
                    FilledButton.icon(
                      onPressed: widget.onOpenDownloads,
                      icon: const Icon(Icons.system_update_outlined),
                      label: const Text('Update available'),
                    )
                  else
                    const Text('Up to date'),
                ],
              )
            : Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Not installed'),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenDownloads,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Download Conclave Workspace'),
                  ),
                ],
              ),
      );

  String _statusLabel(String status) => switch (status.toLowerCase()) {
        'enrolled' || 'not_connected' => 'Not connected',
        'pairing' => 'Pairing',
        'online' => 'Online',
        'offline' => 'Offline',
        'busy' => 'Busy',
        'draining' => 'Draining',
        'revoked' => 'Revoked',
        _ => status,
      };

  String _platformLabel(String value) => switch (value.toLowerCase()) {
        'macos' => 'macOS',
        'windows' => 'Windows',
        'linux' => 'Linux',
        _ => value,
      };

  String _architectureLabel(String value) => switch (value.toLowerCase()) {
        'arm64' => 'Apple Silicon',
        'x64' => 'x64',
        _ => value,
      };

  String _machineLabel(String os, String arch) {
    final p = _platformLabel(os);
    final a = _architectureLabel(arch);
    if ((p == '—' || p.isEmpty) && (a == '—' || a.isEmpty)) return '—';
    if (p == '—' || p.isEmpty) return a;
    if (a == '—' || a.isEmpty) return p;
    return '$p · $a';
  }

  Widget _workers() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Panel(
            title: 'Workers on ${widget.workspace.name}',
            subtitle: 'Configured AI/tool identities that can run here.',
            child: _configuredWorkersOnWorkspace(),
          ),
        ],
      );

  Widget _configuredWorkersOnWorkspace() {
    final workers = widget.configuredWorkers
        .where((worker) => worker.bindings
            .any((binding) => binding.workspaceId == widget.workspace.id))
        .toList();
    if (workers.isEmpty) {
      return const Text(
          'No configured Workers are connected to this Workspace.');
    }
    return Column(
      children: workers.map((worker) {
        final binding = worker.bindings
            .firstWhere((item) => item.workspaceId == widget.workspace.id);
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            binding.ready
                ? Icons.check_circle_outline
                : Icons.warning_amber_outlined,
            color: binding.ready
                ? const Color(0xff3ca879)
                : const Color(0xffc1842d),
          ),
          title: Text(worker.name),
          subtitle: Text(
              '${worker.workerTypeName} · ${binding.ready ? 'Ready to run' : 'Needs attention'}'),
          trailing: Wrap(
            spacing: 2,
            children: [
              if (binding.credentialStatus != 'ready')
                TextButton(
                  onPressed: widget.onSetupConfiguredWorkerWorkspace == null
                      ? null
                      : () => widget.onSetupConfiguredWorkerWorkspace!(
                          worker, widget.workspace.id, 'reauthenticate'),
                  child: const Text('Authenticate'),
                ),
              IconButton(
                tooltip: 'Open Worker',
                onPressed: widget.onOpenConfiguredWorker == null
                    ? null
                    : () => widget.onOpenConfiguredWorker!(worker),
                icon: const Icon(Icons.open_in_new, size: 18),
              ),
              IconButton(
                tooltip: 'Remove binding',
                onPressed: widget.onRemoveConfiguredWorkerWorkspace == null
                    ? null
                    : () => widget.onRemoveConfiguredWorkerWorkspace!(
                        worker, widget.workspace.id),
                icon: const Icon(Icons.link_off_outlined, size: 18),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _projectAccess() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Panel(
            title: 'Project access for ${widget.workspace.name}',
            subtitle:
                'Explicit Project Grants determine which Projects may use this Workspace.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.workspace.workspaceBindings.length} active Project Grant${widget.workspace.workspaceBindings.length == 1 ? '' : 's'}',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => widget.onGrant(widget.workspace),
                  icon: const Icon(Icons.add_link),
                  label: const Text('Grant to Project'),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _activity() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Panel(
            title: 'Activity on ${widget.workspace.name}',
            subtitle: 'Recent runtime state for this Workspace.',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timeline_outlined),
              title: Text('Last seen ${widget.workspace.lastSeen}'),
              subtitle:
                  Text('${widget.workspace.activeTaskCount} active tasks'),
            ),
          ),
        ],
      );

  Widget _settings() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Panel(
            title: 'Runtime settings for ${widget.workspace.name}',
            subtitle: 'Manage the runtime environment and its lifecycle.',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => widget.onRename(widget.workspace),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Rename'),
                ),
                OutlinedButton.icon(
                  onPressed: () => widget.onUpdate(widget.workspace),
                  icon: const Icon(Icons.system_update_outlined),
                  label: const Text('Update'),
                ),
                TextButton.icon(
                  onPressed: () => widget.onRevoke(widget.workspace),
                  icon: const Icon(Icons.link_off_outlined),
                  label: const Text('Revoke'),
                ),
              ],
            ),
          ),
        ],
      );
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      );
}

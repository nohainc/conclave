import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

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
              '${widget.workspace.os} · ${widget.workspace.architecture} · ${widget.workspace.status}',
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
                Text('Status: ${widget.workspace.status}'),
                Text(
                    'Current load: ${widget.workspace.activeTaskCount} active tasks'),
                Text('Last seen: ${widget.workspace.lastSeen}'),
                Text('Runtime: ${widget.workspace.version}')
              ],
            ),
          ),
          _Panel(
            title: 'Update state',
            subtitle: 'Signed Workspace runtime release information.',
            child: Text(
              'Channel: ${widget.workspace.updateChannel}\nApplication version: ${widget.workspace.appVersion}',
            ),
          ),
        ],
      );

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

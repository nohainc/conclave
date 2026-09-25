import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Contextual Workspace detail view with Overview, Workers, AI Accounts,
/// Project access, Repositories, Activity, and Settings tabs.
class WorkspaceDetailView extends StatefulWidget {
  const WorkspaceDetailView({
    super.key,
    required this.workspace,
    required this.accounts,
    required this.onBack,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
    this.initialTab = 0,
  });

  final StudioAgent workspace;
  final List<StudioCredentialProfile> accounts;
  final VoidCallback onBack;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;
  final int initialTab;

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
      length: 6,
      initialIndex: widget.initialTab.clamp(0, 5),
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(WorkspaceDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.clamp(0, 5));
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localAccounts = widget.accounts
        .where((account) =>
            account.host == widget.workspace.id ||
            account.host == widget.workspace.name)
        .toList();

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
                Tab(text: 'AI Accounts'),
                Tab(text: 'Project access'),
                Tab(text: 'Activity'),
                Tab(text: 'Settings'),
              ],
            ),
            const SizedBox(height: 14),
            switch (activeIndex) {
              0 => _overview(),
              1 => _workers(),
              2 => _accountsTab(localAccounts),
              3 => _projectAccess(),
              4 => _activity(),
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
                Text('Current load: ${widget.workspace.activeTaskCount} active tasks'),
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
            subtitle: 'Manage what this Workspace has installed.',
            child: widget.workspace.installedWorkers.isEmpty
                ? const Text('No Workers installed.')
                : Column(
                    children: widget.workspace.installedWorkers
                        .map(
                          (worker) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.extension_outlined),
                            title: Text(worker.workerId),
                            subtitle:
                                Text('${worker.version} · ${worker.status}'),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      );

  Widget _accountsTab(List<StudioCredentialProfile> localAccounts) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Panel(
            title: 'AI Accounts on ${widget.workspace.name}',
            subtitle:
                'Secrets remain local to this Workspace and are never transmitted to Cloud.',
            child: localAccounts.isEmpty
                ? const Text('No local AI Accounts.')
                : Column(
                    children: localAccounts
                        .map(
                          (account) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.account_circle_outlined),
                            title: Text(account.displayName),
                            subtitle: Text(
                                '${account.status} · ${account.sharing}'),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      );

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
              subtitle: Text('${widget.workspace.activeTaskCount} active tasks'),
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

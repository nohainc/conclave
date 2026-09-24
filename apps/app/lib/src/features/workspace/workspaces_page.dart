import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Execution configuration center consolidating Workspaces, Workers, and AI Accounts.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    super.key,
    required this.workspaces,
    required this.workers,
    required this.accounts,
    this.plugins = const [],
    this.initialTab = 0,
    required this.onAdd,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
    this.onSetWorkerAvailability,
    this.onShowWorkerDetails,
    this.onCreateAccount,
    this.onRequestAccountSetup,
    this.onRevokeAccount,
    this.onNavigateToAccounts,
    this.workerActionMessage,
    this.onDismissWorkerActionMessage,
  });

  final List<StudioAgent> workspaces;
  final List<StudioWorker> workers;
  final List<StudioCredentialProfile> accounts;
  final List<StudioPlugin> plugins;
  final int initialTab;
  final VoidCallback onAdd;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;
  final void Function(StudioPlugin plugin, StudioAgent host, bool desired)?
      onSetWorkerAvailability;
  final ValueChanged<StudioPlugin>? onShowWorkerDetails;
  final VoidCallback? onCreateAccount;
  final ValueChanged<StudioCredentialProfile>? onRequestAccountSetup;
  final ValueChanged<StudioCredentialProfile>? onRevokeAccount;
  final VoidCallback? onNavigateToAccounts;
  final String? workerActionMessage;
  final VoidCallback? onDismissWorkerActionMessage;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  StudioAgent? selected;

  @override
  Widget build(BuildContext context) {
    final active = selected == null
        ? null
        : widget.workspaces
            .where((item) => item.id == selected!.id)
            .firstOrNull;
    return active == null ? _executionCenter(context) : _detail(context, active);
  }

  Widget _executionCenter(BuildContext context) {
    return DefaultTabController(
      key: ValueKey('execution_tabs_${widget.initialTab}'),
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(
            context,
            'Workspaces',
            'Execution environments, Workers, and AI Accounts.',
            widget.onAdd,
          ),
          const SizedBox(height: 16),
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Workspaces'),
              Tab(text: 'Workers'),
              Tab(text: 'AI Accounts'),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: TabBarView(
              children: [
                _workspacesTab(context),
                _workersTab(context),
                _accountsTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _workspacesTab(BuildContext context) => ListView(
        children: [
          if (widget.workspaces.isEmpty)
            _Panel(
              title: 'No Workspaces yet',
              subtitle:
                  'Add a Workspace to provide execution capacity to Projects.',
              child: FilledButton.icon(
                onPressed: widget.onAdd,
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('Add Workspace'),
              ),
            )
          else
            ...widget.workspaces
                .map((workspace) => _workspaceCard(context, workspace)),
        ],
      );

  Widget _workspaceCard(BuildContext context, StudioAgent workspace) {
    final online = workspace.status.toLowerCase() == 'online';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => setState(() => selected = workspace),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(workspace.name,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  _status(online ? 'Online' : workspace.status),
                  Text('${workspace.os} · ${workspace.architecture}'),
                ]),
            const SizedBox(height: 12),
            Wrap(spacing: 20, runSpacing: 8, children: [
              Text('${workspace.workerCount} Workers'),
              Text('${workspace.activeTaskCount} active tasks'),
              Text('${workspace.workspaceBindings.length} Project Grants'),
              Text('Last seen: ${workspace.lastSeen}'),
              Text('Update: ${workspace.updateChannel}'),
            ]),
            const SizedBox(height: 12),
            Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => selected = workspace),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('View Workspace'),
                )),
          ]),
        ),
      ),
    );
  }

  // --- Workers Tab ---

  bool _workerDesiredOn(StudioPlugin plugin, StudioAgent host) =>
      host.desiredWorkers.any((worker) => worker.workerId == plugin.id);

  bool _workerInstalledOn(StudioPlugin plugin, StudioAgent host) =>
      host.installedWorkers.any((worker) =>
          worker.workerId == plugin.id &&
          worker.status.toLowerCase() != 'failed');

  Widget _workerHostRow(StudioPlugin plugin, StudioAgent host) {
    final desired = _workerDesiredOn(plugin, host);
    final installed = _workerInstalledOn(plugin, host);
    final state = !desired
        ? 'Not installed'
        : installed
            ? 'Installed'
            : 'Installing';
    final stateColor = !desired
        ? const Color(0xff777683)
        : installed
            ? const Color(0xff3ca879)
            : const Color(0xffc1842d);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check_circle_outline : Icons.circle_outlined,
            size: 18,
            color: stateColor,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(host.name)),
          Text(state, style: TextStyle(color: stateColor)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: widget.onSetWorkerAvailability != null
                ? () => widget.onSetWorkerAvailability!(plugin, host, !desired)
                : null,
            child: Text(desired ? 'Remove from Workspace' : 'Make available'),
          ),
          if (desired)
            IconButton(
              tooltip: 'Update Worker',
              onPressed: widget.onSetWorkerAvailability != null
                  ? () => widget.onSetWorkerAvailability!(plugin, host, true)
                  : null,
              icon: const Icon(Icons.system_update_outlined, size: 19),
            ),
        ],
      ),
    );
  }

  Widget _workersTab(BuildContext context) => ListView(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Workers',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Manage Worker availability across your Workspaces.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          if (widget.plugins.isEmpty)
            const _Panel(
              title: 'No Workers available',
              subtitle:
                  'Workers appear when the catalog has a compatible release.',
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Text('Nothing to configure yet.',
                    style: TextStyle(color: Color(0xff777683))),
              ),
            )
          else
            ...widget.plugins.map((plugin) {
              final readyHosts = widget.workspaces
                  .where((host) => _workerInstalledOn(plugin, host))
                  .length;
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const CircleAvatar(
                            backgroundColor: Color(0xffeeecff),
                            child: Icon(Icons.extension_outlined,
                                color: Color(0xff6254d9)),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 220,
                            child: Text(plugin.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16)),
                          ),
                          Text('Ready on $readyHosts Workspaces',
                              style: const TextStyle(color: Color(0xff777683))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                          '${plugin.version} · ${plugin.publisher.isEmpty ? 'Unknown publisher' : plugin.publisher} · ${plugin.capabilities.join(' · ')}'),
                      const SizedBox(height: 6),
                      Text(plugin.permissions.isEmpty
                          ? 'No special permissions'
                          : 'Requirements: ${plugin.permissions.join(', ')}'),
                      if (widget.workspaces.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ...widget.workspaces
                            .map((host) => _workerHostRow(plugin, host)),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton.icon(
                            onPressed: widget.onShowWorkerDetails != null
                                ? () => widget.onShowWorkerDetails!(plugin)
                                : null,
                            icon: const Icon(Icons.info_outline, size: 18),
                            label: const Text('View capabilities'),
                          ),
                          OutlinedButton.icon(
                            onPressed: widget.onShowWorkerDetails != null
                                ? () => widget.onShowWorkerDetails!(plugin)
                                : null,
                            icon: const Icon(Icons.rule_outlined, size: 18),
                            label: const Text('View requirements'),
                          ),
                          OutlinedButton.icon(
                            onPressed: widget.onNavigateToAccounts,
                            icon: const Icon(Icons.account_circle_outlined,
                                size: 18),
                            label: const Text('Connect Account'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      );

  // --- AI Accounts Tab ---

  Widget _accountsTab(BuildContext context) => ListView(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'AI Accounts',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Accounts used by Workers on your Workspaces.',
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: widget.onCreateAccount,
                  icon: const Icon(Icons.add),
                  label: const Text('Add AI Account'),
                ),
              ],
            ),
          ),
          if (widget.workerActionMessage != null) ...[
            MaterialBanner(
              content: Text(widget.workerActionMessage!),
              leading: const Icon(Icons.info_outline),
              actions: [
                TextButton(
                  onPressed: widget.onDismissWorkerActionMessage,
                  child: const Text('Dismiss'),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (widget.accounts.isEmpty)
            const _Panel(
              title: 'No Accounts connected',
              subtitle:
                  'Connect an Account to make a Worker ready for execution.',
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Text('Nothing to configure yet.',
                    style: TextStyle(color: Color(0xff777683))),
              ),
            )
          else ...[
            const Text('Accounts',
                style: TextStyle(color: Color(0xff777683), fontSize: 13)),
            const SizedBox(height: 12),
            ...widget.accounts.map(
              (account) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xffeeecff),
                    child: Icon(Icons.account_circle_outlined,
                        color: Color(0xff6254d9), size: 20),
                  ),
                  title: Text(account.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      'Owner: ${account.owner}\nWorker: ${account.worker} · Workspace: ${account.host}\nStorage: ${account.storageLocation} · Sharing: ${account.sharing}\nLast used: ${account.lastUsed} · Usage: ${account.usage}'),
                  isThreeLine: true,
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Account actions',
                    onSelected: (action) {
                      if (action == 'setup') {
                        widget.onRequestAccountSetup?.call(account);
                      } else if (action == 'revoke') {
                        widget.onRevokeAccount?.call(account);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'setup',
                        child: Text(account.status.toLowerCase() == 'ready'
                            ? 'Reconnect / re-authenticate'
                            : 'Connect Account'),
                      ),
                      const PopupMenuItem(
                        value: 'revoke',
                        child: Text('Revoke Account'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      );

  Widget _detail(BuildContext context, StudioAgent workspace) {
    final localAccounts = widget.accounts
        .where((account) =>
            account.host == workspace.id || account.host == workspace.name)
        .toList();
    return DefaultTabController(
      length: 7,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(
              tooltip: 'Back to Workspaces',
              onPressed: () => setState(() => selected = null),
              icon: const Icon(Icons.arrow_back)),
          Expanded(
              child: Text(workspace.name,
                  style: const TextStyle(
                      fontSize: 25, fontWeight: FontWeight.w700))),
          PopupMenuButton<String>(
            tooltip: 'Workspace actions',
            onSelected: (action) {
              if (action == 'rename') widget.onRename(workspace);
              if (action == 'update') widget.onUpdate(workspace);
              if (action == 'revoke') widget.onRevoke(workspace);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'update', child: Text('Update Workspace')),
              PopupMenuItem(value: 'revoke', child: Text('Revoke Workspace')),
            ],
          ),
        ]),
        Text(
            '${workspace.os} · ${workspace.architecture} · ${workspace.status}',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        const TabBar(isScrollable: true, tabs: [
          Tab(text: 'Overview'),
          Tab(text: 'Workers'),
          Tab(text: 'AI Accounts'),
          Tab(text: 'Project access'),
          Tab(text: 'Repositories & permissions'),
          Tab(text: 'Activity'),
          Tab(text: 'Settings'),
        ]),
        const SizedBox(height: 14),
        Expanded(
            child: TabBarView(children: [
          _overview(workspace),
          _workers(workspace),
          _accounts(workspace, localAccounts),
          _projectAccess(workspace),
          _repositories(workspace),
          _activity(workspace),
          _settings(workspace),
        ])),
      ]),
    );
  }

  Widget _overview(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Workspace overview',
            subtitle:
                'Runtime identity and current capacity for ${workspace.name}.',
            child: Wrap(spacing: 24, runSpacing: 12, children: [
              Text('Status: ${workspace.status}'),
              Text('Current load: ${workspace.activeTaskCount} active tasks'),
              Text('Last seen: ${workspace.lastSeen}'),
              Text('Runtime: ${workspace.version}')
            ])),
        _Panel(
            title: 'Update state',
            subtitle: 'Signed Workspace runtime release information.',
            child: Text(
                'Channel: ${workspace.updateChannel}\nApplication version: ${workspace.appVersion}')),
      ]);

  Widget _workers(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Workers on ${workspace.name}',
            subtitle:
                'Manage what this Workspace has installed.',
            child: workspace.installedWorkers.isEmpty
                ? const Text('No Workers installed.')
                : Column(
                    children: workspace.installedWorkers
                        .map((worker) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.extension_outlined),
                            title: Text(worker.workerId),
                            subtitle:
                                Text('${worker.version} · ${worker.status}')))
                        .toList())),
      ]);

  Widget _accounts(StudioAgent workspace, List<StudioCredentialProfile> accounts) =>
      ListView(children: [
        _Panel(
            title: 'AI Accounts on ${workspace.name}',
            subtitle:
                'Secrets remain local to this Workspace and are never transmitted to Cloud.',
            child: accounts.isEmpty
                ? const Text('No local AI Accounts.')
                : Column(
                    children: accounts
                        .map((account) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.account_circle_outlined),
                            title: Text(account.displayName),
                            subtitle:
                                Text('${account.status} · ${account.sharing}')))
                        .toList())),
      ]);

  Widget _projectAccess(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Project access for ${workspace.name}',
            subtitle:
                'Explicit Project Grants determine which Projects may use this Workspace.',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  '${workspace.workspaceBindings.length} active Project Grant${workspace.workspaceBindings.length == 1 ? '' : 's'}'),
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: () => widget.onGrant(workspace),
                  icon: const Icon(Icons.add_link),
                  label: const Text('Grant to Project'))
            ])),
      ]);

  Widget _repositories(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Repositories and permissions for ${workspace.name}',
            subtitle:
                'Repository mappings and effective filesystem permissions on this Workspace.',
            child: Text(workspace.workspaceBindings.isEmpty
                ? 'No Project Grant mappings yet.'
                : 'Review repository paths and permissions from the connected Project Grants.')),
      ]);

  Widget _activity(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Activity on ${workspace.name}',
            subtitle: 'Recent runtime state for this Workspace.',
            child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timeline_outlined),
                title: Text('Last seen ${workspace.lastSeen}'),
                subtitle: Text('${workspace.activeTaskCount} active tasks'))),
      ]);

  Widget _settings(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Runtime settings for ${workspace.name}',
            subtitle: 'Manage the runtime environment and its lifecycle.',
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: () => widget.onRename(workspace),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Rename')),
              OutlinedButton.icon(
                  onPressed: () => widget.onUpdate(workspace),
                  icon: const Icon(Icons.system_update_outlined),
                  label: const Text('Update')),
              TextButton.icon(
                  onPressed: () => widget.onRevoke(workspace),
                  icon: const Icon(Icons.link_off_outlined),
                  label: const Text('Revoke'))
            ])),
      ]);

  Widget _header(BuildContext context, String title, String subtitle,
          VoidCallback action) =>
      Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 10,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 25, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(subtitle,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13))
            ]),
            FilledButton.icon(
                onPressed: action,
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('Add Workspace'))
          ]);

  Widget _status(String value) => Chip(
      avatar: Icon(Icons.circle,
          size: 9, color: value == 'Online' ? Colors.green : Colors.grey),
      label: Text(value));
}

class _Panel extends StatelessWidget {
  const _Panel(
      {required this.title, required this.subtitle, required this.child});
  final String title;
  final String subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(subtitle,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            child
          ])));
}

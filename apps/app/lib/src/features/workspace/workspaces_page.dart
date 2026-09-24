import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    super.key,
    required this.workspaces,
    required this.workers,
    required this.accounts,
    required this.onAdd,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
  });

  final List<StudioAgent> workspaces;
  final List<StudioWorker> workers;
  final List<StudioCredentialProfile> accounts;
  final VoidCallback onAdd;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;

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
    return active == null ? _list(context) : _detail(context, active);
  }

  Widget _list(BuildContext context) => ListView(
        children: [
          _header(context, 'Workspaces',
              'Execution environments where your Workers run.', widget.onAdd),
          const SizedBox(height: 20),
          if (widget.workspaces.isEmpty)
            _Panel(
              title: 'No Workspaces yet',
              subtitle:
                  'Add a Workspace to provide execution capacity to Projects.',
              child: FilledButton.icon(
                  onPressed: widget.onAdd,
                  icon: const Icon(Icons.add_business_outlined),
                  label: const Text('Add Workspace')),
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
          _accounts(localAccounts),
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
            subtitle: 'Runtime identity and current capacity.',
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
            title: 'Workers',
            subtitle:
                'Installed and desired Worker state is managed by the Workspace owner.',
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

  Widget _accounts(List<StudioCredentialProfile> accounts) =>
      ListView(children: [
        _Panel(
            title: 'AI Accounts and local actions',
            subtitle:
                'Secrets remain local to this Workspace and are never shown here.',
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
            title: 'Project access',
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
            title: 'Repositories and permissions',
            subtitle:
                'Repository mappings and effective permissions are defined by Project Grants.',
            child: Text(workspace.workspaceBindings.isEmpty
                ? 'No Project Grant mappings yet.'
                : 'Review repository paths and permissions from the connected Project Grants.')),
      ]);

  Widget _activity(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Activity',
            subtitle: 'Recent runtime state for this Workspace.',
            child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timeline_outlined),
                title: Text('Last seen ${workspace.lastSeen}'),
                subtitle: Text('${workspace.activeTaskCount} active tasks'))),
      ]);

  Widget _settings(StudioAgent workspace) => ListView(children: [
        _Panel(
            title: 'Workspace settings',
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

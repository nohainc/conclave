import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Contextual Workspace detail view with Overview, Workers, AI Accounts,
/// Project access, Repositories, Activity, and Settings tabs.
class WorkspaceDetailView extends StatelessWidget {
  const WorkspaceDetailView({
    super.key,
    required this.workspace,
    required this.accounts,
    required this.onBack,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
  });

  final StudioAgent workspace;
  final List<StudioCredentialProfile> accounts;
  final VoidCallback onBack;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;

  @override
  Widget build(BuildContext context) {
    final localAccounts = accounts
        .where((account) =>
            account.host == workspace.id || account.host == workspace.name)
        .toList();

    return DefaultTabController(
      length: 7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Back to Workspaces',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  workspace.name,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Workspace actions',
                onSelected: (action) {
                  if (action == 'rename') onRename(workspace);
                  if (action == 'update') onUpdate(workspace);
                  if (action == 'revoke') onRevoke(workspace);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'update', child: Text('Update Workspace')),
                  PopupMenuItem(value: 'revoke', child: Text('Revoke Workspace')),
                ],
              ),
            ],
          ),
          Text(
            '${workspace.os} · ${workspace.architecture} · ${workspace.status}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Workers'),
              Tab(text: 'AI Accounts'),
              Tab(text: 'Project access'),
              Tab(text: 'Repositories & permissions'),
              Tab(text: 'Activity'),
              Tab(text: 'Settings'),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: TabBarView(
              children: [
                _overview(),
                _workers(),
                _accountsTab(localAccounts),
                _projectAccess(),
                _repositories(),
                _activity(),
                _settings(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _overview() => ListView(
        children: [
          _Panel(
            title: 'Workspace overview',
            subtitle:
                'Runtime identity and current capacity for ${workspace.name}.',
            child: Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                Text('Status: ${workspace.status}'),
                Text('Current load: ${workspace.activeTaskCount} active tasks'),
                Text('Last seen: ${workspace.lastSeen}'),
                Text('Runtime: ${workspace.version}')
              ],
            ),
          ),
          _Panel(
            title: 'Update state',
            subtitle: 'Signed Workspace runtime release information.',
            child: Text(
              'Channel: ${workspace.updateChannel}\nApplication version: ${workspace.appVersion}',
            ),
          ),
        ],
      );

  Widget _workers() => ListView(
        children: [
          _Panel(
            title: 'Workers on ${workspace.name}',
            subtitle: 'Manage what this Workspace has installed.',
            child: workspace.installedWorkers.isEmpty
                ? const Text('No Workers installed.')
                : Column(
                    children: workspace.installedWorkers
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

  Widget _accountsTab(List<StudioCredentialProfile> localAccounts) => ListView(
        children: [
          _Panel(
            title: 'AI Accounts on ${workspace.name}',
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

  Widget _projectAccess() => ListView(
        children: [
          _Panel(
            title: 'Project access for ${workspace.name}',
            subtitle:
                'Explicit Project Grants determine which Projects may use this Workspace.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${workspace.workspaceBindings.length} active Project Grant${workspace.workspaceBindings.length == 1 ? '' : 's'}',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => onGrant(workspace),
                  icon: const Icon(Icons.add_link),
                  label: const Text('Grant to Project'),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _repositories() => ListView(
        children: [
          _Panel(
            title: 'Repositories and permissions for ${workspace.name}',
            subtitle:
                'Repository mappings and effective filesystem permissions on this Workspace.',
            child: Text(
              workspace.workspaceBindings.isEmpty
                  ? 'No Project Grant mappings yet.'
                  : 'Review repository paths and permissions from the connected Project Grants.',
            ),
          ),
        ],
      );

  Widget _activity() => ListView(
        children: [
          _Panel(
            title: 'Activity on ${workspace.name}',
            subtitle: 'Recent runtime state for this Workspace.',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.timeline_outlined),
              title: Text('Last seen ${workspace.lastSeen}'),
              subtitle: Text('${workspace.activeTaskCount} active tasks'),
            ),
          ),
        ],
      );

  Widget _settings() => ListView(
        children: [
          _Panel(
            title: 'Runtime settings for ${workspace.name}',
            subtitle: 'Manage the runtime environment and its lifecycle.',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => onRename(workspace),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Rename'),
                ),
                OutlinedButton.icon(
                  onPressed: () => onUpdate(workspace),
                  icon: const Icon(Icons.system_update_outlined),
                  label: const Text('Update'),
                ),
                TextButton.icon(
                  onPressed: () => onRevoke(workspace),
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

import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Overview tab displaying the list of enrolled Workspaces.
class WorkspacesOverview extends StatelessWidget {
  const WorkspacesOverview({
    super.key,
    required this.workspaces,
    required this.onAdd,
    required this.onSelectWorkspace,
  });

  final List<StudioAgent> workspaces;
  final VoidCallback onAdd;
  final ValueChanged<StudioAgent> onSelectWorkspace;

  @override
  Widget build(BuildContext context) {
    if (workspaces.isEmpty) {
      return ListView(
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No Workspaces yet',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Add a Workspace to provide execution capacity to Projects.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add_business_outlined),
                    label: const Text('Add Workspace'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      children: workspaces
          .map((ws) => _WorkspaceCard(
                workspace: ws,
                onSelect: () => onSelectWorkspace(ws),
              ))
          .toList(),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.workspace,
    required this.onSelect,
  });

  final StudioAgent workspace;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final online = workspace.status.toLowerCase() == 'online';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    workspace.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Chip(
                    avatar: Icon(
                      Icons.circle,
                      size: 9,
                      color: online ? Colors.green : Colors.grey,
                    ),
                    label: Text(online ? 'Online' : workspace.status),
                  ),
                  Text('${workspace.os} · ${workspace.architecture}'),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 20,
                runSpacing: 8,
                children: [
                  Text('${workspace.workerCount} Workers'),
                  Text('${workspace.activeTaskCount} active tasks'),
                  Text('${workspace.workspaceBindings.length} Project Grants'),
                  Text('Last seen: ${workspace.lastSeen}'),
                  Text('Update: ${workspace.updateChannel}'),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: onSelect,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('View Workspace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

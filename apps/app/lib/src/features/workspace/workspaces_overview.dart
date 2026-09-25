import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Overview tab displaying the list of enrolled Workspaces.
class WorkspacesOverview extends StatelessWidget {
  const WorkspacesOverview({
    super.key,
    required this.workspaces,
    required this.onAdd,
    required this.onSelectWorkspace,
    this.onOpenDownloads,
  });

  final List<StudioAgent> workspaces;
  final VoidCallback onAdd;
  final ValueChanged<StudioAgent> onSelectWorkspace;
  final VoidCallback? onOpenDownloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  'Workspaces provide execution capacity for AI workloads and Workers.',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Add Workspace',
                splashRadius: 20,
                onPressed: onAdd,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (workspaces.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('No workspaces yet.'),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onOpenDownloads,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Download Conclave Workspace'),
                  ),
                ],
              ),
            )
          else ...[
            Padding(
              padding:
                  const EdgeInsets.only(top: 6, bottom: 4, left: 4, right: 4),
              child: Row(
                children: [
                  const Expanded(
                    flex: 5,
                    child: SizedBox.shrink(),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text('Workers',
                        textAlign: TextAlign.center, style: mutedStyle),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text('Projects',
                        textAlign: TextAlign.center, style: mutedStyle),
                  ),
                  Expanded(
                    flex: 2,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Icon(
                          Icons.sensors_rounded,
                          size: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text('Connected', style: mutedStyle),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Column(
              children: workspaces.map((workspace) {
                final online = workspace.status.toLowerCase() == 'online';
                return InkWell(
                  onTap: () => onSelectWorkspace(workspace),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                workspace.name,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (workspace.os != '—' ||
                                  workspace.architecture != '—')
                                Text(
                                  '${workspace.os} · ${workspace.architecture}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '${workspace.workerCount}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '${workspace.workspaceBindings.length}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.circle,
                                  size: 7,
                                  color: online
                                      ? const Color(0xff3ca879)
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    online
                                        ? 'Online'
                                        : _statusLabel(workspace.status),
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: online
                                          ? const Color(0xff3ca879)
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

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
}

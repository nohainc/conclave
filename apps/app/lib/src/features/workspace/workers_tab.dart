import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Workers tab displaying worker plugins, capabilities, and availability per Workspace.
class WorkersTab extends StatelessWidget {
  const WorkersTab({
    super.key,
    required this.workspaces,
    required this.plugins,
    this.onSetWorkerAvailability,
    this.onShowWorkerDetails,
    this.onNavigateToAccounts,
  });

  final List<StudioAgent> workspaces;
  final List<StudioPlugin> plugins;
  final void Function(StudioPlugin plugin, StudioAgent host, bool desired)?
      onSetWorkerAvailability;
  final ValueChanged<StudioPlugin>? onShowWorkerDetails;
  final VoidCallback? onNavigateToAccounts;

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
            onPressed: onSetWorkerAvailability != null
                ? () => onSetWorkerAvailability!(plugin, host, !desired)
                : null,
            child: Text(desired ? 'Remove from Workspace' : 'Make available'),
          ),
          if (desired)
            IconButton(
              tooltip: 'Update Worker',
              onPressed: onSetWorkerAvailability != null
                  ? () => onSetWorkerAvailability!(plugin, host, true)
                  : null,
              icon: const Icon(Icons.system_update_outlined, size: 19),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        if (plugins.isEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No Workers available',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Workers appear when the catalog has a compatible release.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Nothing to configure yet.',
                      style: TextStyle(color: Color(0xff777683)),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...plugins.map((plugin) {
            final readyHosts = workspaces
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
                    if (workspaces.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ...workspaces.map((host) => _workerHostRow(plugin, host)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          onPressed: onShowWorkerDetails != null
                              ? () => onShowWorkerDetails!(plugin)
                              : null,
                          icon: const Icon(Icons.info_outline, size: 18),
                          label: const Text('View capabilities'),
                        ),
                        OutlinedButton.icon(
                          onPressed: onShowWorkerDetails != null
                              ? () => onShowWorkerDetails!(plugin)
                              : null,
                          icon: const Icon(Icons.rule_outlined, size: 18),
                          label: const Text('View requirements'),
                        ),
                        OutlinedButton.icon(
                          onPressed: onNavigateToAccounts,
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
  }
}

import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// Normal product surface for user-configured Workers.
///
/// Worker Type catalog data is intentionally not rendered here. It is used by
/// the Add Worker flow; package lifecycle belongs to infrastructure.
class WorkersTab extends StatelessWidget {
  const WorkersTab({
    super.key,
    required this.workspaces,
    required this.plugins,
    this.configuredWorkers = const [],
    this.onAddConfiguredWorker,
    this.onOpenConfiguredWorker,
  });

  // Kept in the widget contract for the migration period. Catalog and
  // Workspace runtime data are consumed by the Add Worker flow and backend.
  final List<StudioAgent> workspaces;
  final List<StudioPlugin> plugins;
  final List<StudioConfiguredWorker> configuredWorkers;
  final VoidCallback? onAddConfiguredWorker;
  final ValueChanged<StudioConfiguredWorker>? onOpenConfiguredWorker;

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
              const Text('Workers',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'A Worker is a configured AI/tool identity. Connect it to the Workspaces where it can run.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: onAddConfiguredWorker,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Worker'),
          ),
        ),
        const SizedBox(height: 12),
        if (configuredWorkers.isEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('No configured Workers yet',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    'Add a Worker, connect it to a Workspace, and authenticate when prompted.',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          )
        else
          ...configuredWorkers
              .map((worker) => _configuredWorkerCard(context, worker)),
      ],
    );
  }

  Widget _configuredWorkerCard(
      BuildContext context, StudioConfiguredWorker worker) {
    final ready = worker.readyWorkspaceCount;
    final statusColor = worker.status == 'active'
        ? const Color(0xff3ca879)
        : const Color(0xffc1842d);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onOpenConfiguredWorker == null
            ? null
            : () => onOpenConfiguredWorker!(worker),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: Color(0xffeeecff),
                    child: Icon(Icons.smart_toy_outlined,
                        color: Color(0xff6254d9)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(worker.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                  Chip(
                    label: Text(worker.status),
                    labelStyle: TextStyle(color: statusColor, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                  '${worker.workerTypeName} · ${worker.defaultModel ?? 'Default model'}'),
              const SizedBox(height: 6),
              Text(
                '$ready/${worker.bindings.length} Workspaces ready · concurrency ${worker.concurrencyLimit}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              if (worker.bindings.isNotEmpty) ...[
                const SizedBox(height: 10),
                ...worker.bindings.take(3).map((binding) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Icon(
                            binding.ready
                                ? Icons.check_circle_outline
                                : Icons.warning_amber_outlined,
                            size: 16,
                            color: binding.ready
                                ? const Color(0xff3ca879)
                                : const Color(0xffc1842d),
                          ),
                          const SizedBox(width: 6),
                          Expanded(child: Text(binding.workspaceName)),
                          Text(binding.ready ? 'Ready' : 'Action required',
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    )),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onOpenConfiguredWorker == null
                      ? null
                      : () => onOpenConfiguredWorker!(worker),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open Worker'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

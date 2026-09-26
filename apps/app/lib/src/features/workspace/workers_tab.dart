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
    this.workspaceWorkers = const [],
    this.onAddConfiguredWorker,
    this.onOpenConfiguredWorker,
  });

  // Kept in the widget contract for the migration period. Catalog and
  // Workspace runtime data are consumed by the Add Worker flow and backend.
  final List<StudioAgent> workspaces;
  final List<StudioPlugin> plugins;
  final List<StudioConfiguredWorker> configuredWorkers;
  final List<StudioWorkspaceWorker> workspaceWorkers;
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
                'Workers are created and authenticated on their Workspace computer. This inventory shows safe status and capability details.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        if (workspaceWorkers.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _showLocalSetupGuidance(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add a Worker in Conclave Workspace'),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onAddConfiguredWorker,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add legacy Cloud Worker'),
          ),
        ),
        const SizedBox(height: 12),
        if (workspaceWorkers.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Workers from your Workspaces',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          ...workspaceWorkers
              .map((worker) => _workspaceWorkerCard(context, worker)),
          const SizedBox(height: 10),
        ],
        if (configuredWorkers.isEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('No legacy Cloud-configured Workers',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    'To create a Worker, open Conclave Workspace on the computer where it should run.',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          )
        else if (configuredWorkers.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Legacy Cloud-configured Workers',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          ...configuredWorkers
              .map((worker) => _configuredWorkerCard(context, worker)),
        ],
      ],
    );
  }

  void _showLocalSetupGuidance(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a Worker on its Workspace'),
        content: const Text(
          'Open Conclave Workspace on the computer where this Worker should run. Add and authenticate the Worker there; it will appear in this inventory after the Workspace syncs.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _workspaceWorkerCard(
      BuildContext context, StudioWorkspaceWorker worker) {
    final ready = worker.status == 'ready' &&
        const {'ready', 'not_required'}.contains(worker.credentialStatus);
    final status = worker.status == 'removed'
        ? 'Removed'
        : worker.status == 'disabled'
            ? 'Disabled'
            : ready
                ? 'Ready'
                : 'Needs attention';
    final color = ready ? const Color(0xff3ca879) : const Color(0xffc1842d);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _showWorkspaceWorkerDetails(context, worker, status),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const CircleAvatar(
                  backgroundColor: Color(0xffeeecff),
                  child:
                      Icon(Icons.smart_toy_outlined, color: Color(0xff6254d9))),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(worker.name,
                      style: const TextStyle(fontWeight: FontWeight.w700))),
              Chip(
                  label: Text(status),
                  labelStyle: TextStyle(color: color, fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            Text('${worker.workerTypeId} · ${worker.workspaceName}'),
            if (worker.defaultModel != null)
              Text('Default model · ${worker.defaultModel}'),
            if (worker.capabilities.isNotEmpty)
              Text('Capabilities · ${worker.capabilities.join(', ')}'),
            Text('Local concurrency · ${worker.localConcurrencyLimit}'),
          ]),
        ),
      ),
    );
  }

  void _showWorkspaceWorkerDetails(
    BuildContext context,
    StudioWorkspaceWorker worker,
    String status,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(worker.name),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _detailSection('Overview', [
                  'Worker Type · ${worker.workerTypeId}',
                  'Status · $status',
                  'Authentication · ${worker.authStrategy}',
                  'Credential · ${worker.credentialStatus}',
                  'Adapter · ${worker.adapterVersion ?? 'Unknown'}',
                  'Default model · ${worker.defaultModel ?? 'Not set'}',
                  'Allowed models · ${worker.allowedModels.isEmpty ? 'Any supported model' : worker.allowedModels.join(', ')}',
                  'Capabilities · ${worker.capabilities.isEmpty ? 'None reported' : worker.capabilities.join(', ')}',
                  'Local concurrency · ${worker.localConcurrencyLimit}',
                ]),
                _detailSection('Workspace', [worker.workspaceName]),
                if (status == 'Needs attention')
                  _detailSection('Local attention', [
                    'Complete authentication or prerequisite setup in Conclave Workspace on ${worker.workspaceName}.',
                  ]),
                _detailSection('Scheduling', [
                  'Remote scheduling state is not included in the current Worker inventory.',
                ]),
                _detailSection('Activity and audit', [
                  'Recent Worker activity is not included in the current Worker inventory.',
                  'Inventory revision · ${worker.revision}',
                ]),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _detailSection(String title, List<String> values) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            ...values.map((value) => Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(value),
                )),
          ],
        ),
      );

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

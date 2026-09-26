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
    this.workspaceWorkers = const [],
    this.onScheduling,
  });

  // Kept in the widget contract for the migration period. Catalog and
  // Workspace runtime data are consumed by the Add Worker flow and backend.
  final List<StudioAgent> workspaces;
  final List<StudioPlugin> plugins;
  final List<StudioWorkspaceWorker> workspaceWorkers;
  final Future<void> Function(StudioWorkspaceWorker worker, String action)?
      onScheduling;

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
        if (workspaceWorkers.isEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                'No Workers have synced yet. Open Conclave Workspace on the target computer, add and authenticate a Worker there, and it will appear here automatically.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
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
                  'Cloud scheduling · ${worker.schedulingState}',
                  if (worker.cloudConcurrencyLimit != null)
                    'Cloud concurrency · ${worker.cloudConcurrencyLimit}',
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
          if (onScheduling != null && status != 'Removed') ...[
            if (worker.schedulingState == 'enabled')
              TextButton(
                  onPressed: () => _runScheduling(context, worker, 'drain'),
                  child: const Text('Drain')),
            if (worker.schedulingState != 'disabled')
              TextButton(
                  onPressed: () => _runScheduling(context, worker, 'disable'),
                  child: const Text('Disable scheduling')),
            if (worker.schedulingState == 'disabled' && status == 'Ready')
              TextButton(
                  onPressed: () => _runScheduling(context, worker, 'enable'),
                  child: const Text('Enable scheduling')),
          ],
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _runScheduling(
      BuildContext context, StudioWorkspaceWorker worker, String action) async {
    Navigator.of(context).pop();
    await onScheduling?.call(worker, action);
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
}

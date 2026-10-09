import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';

export 'workspaces_overview.dart';

/// Workspace-owned execution capacity and the Workers configured on it.
///
/// Workspace collection page. Workspace routes always render this view.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    super.key,
    required this.workspaces,
    this.workspaceWorkers = const [],
    this.initialWorkspaceId,
    // Retained as optional compatibility inputs while callers are audited.
    VoidCallback? onAdd,
    ValueChanged<AxWorkspace>? onRename,
    ValueChanged<AxWorkspace>? onUpdate,
    ValueChanged<AxWorkspace>? onRevoke,
    Future<void> Function(AxWorkspace)? onConnect,
  });

  final List<AxWorkspace> workspaces;
  final List<AxWorker> workspaceWorkers;
  final String? initialWorkspaceId;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  final Map<String, GlobalKey> _workspaceCardKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    if (widget.initialWorkspaceId != null) {
      _focusWorkspaceCard(widget.initialWorkspaceId!);
    }
  }

  @override
  void didUpdateWidget(WorkspacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialWorkspaceId != widget.initialWorkspaceId &&
        widget.initialWorkspaceId != null) {
      _focusWorkspaceCard(widget.initialWorkspaceId!);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final wideLayout = MediaQuery.sizeOf(context).width >= 760;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Workspaces',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3)),
              const SizedBox(height: 6),
              Text(
                'Workspaces are connected execution environments. Workers are the AI integrations configured on each Workspace.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (widget.workspaces.isEmpty)
                const _EmptyWorkspaces()
              else
                LayoutBuilder(
                    builder: (context, cardConstraints) => Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: widget.workspaces
                              .map((workspace) {
                                final localWorkers = widget.workspaceWorkers
                                    .where((worker) =>
                                        worker.workspaceId == workspace.id &&
                                        worker.status != 'removed')
                                    .toList(growable: false);
                                final isTarget =
                                    widget.initialWorkspaceId == workspace.id;
                                return Card(
                                  key: _workspaceCardKeys.putIfAbsent(
                                      workspace.id, GlobalKey.new),
                                  margin: EdgeInsets.zero,
                                  clipBehavior: Clip.antiAlias,
                                  shape: RoundedRectangleBorder(
                                    side: BorderSide(
                                      color: isTarget
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : Colors.transparent,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Column(
                                    children: [
                                      ListTile(
                                        title: Row(
                                          children: [
                                            Expanded(
                                              child: Text(workspace.name,
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700)),
                                            ),
                                            _StatusPill(
                                                status:
                                                    _statusLabel(workspace)),
                                          ],
                                        ),
                                        subtitle: Text(
                                          _workspaceSubtitle(workspace),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            16, 0, 16, 16),
                                        child: _WorkspaceCardBody(
                                          workers: localWorkers,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              })
                              .map((card) => SizedBox(
                                    width: wideLayout &&
                                            widget.workspaces.length > 1
                                        ? (cardConstraints.maxWidth - 12) / 2
                                        : cardConstraints.maxWidth,
                                    child: card,
                                  ))
                              .toList(),
                        )),
            ],
          );
        },
      );

  void _focusWorkspaceCard(String workspaceId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cardContext = _workspaceCardKeys[workspaceId]?.currentContext;
      if (cardContext == null) return;
      Scrollable.ensureVisible(
        cardContext,
        alignment: 0.08,
        duration: const Duration(milliseconds: 220),
      );
    });
  }
}

class _WorkspaceCardBody extends StatelessWidget {
  const _WorkspaceCardBody({
    required this.workers,
  });

  final List<AxWorker> workers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 14),
        Text('Workers',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (workers.isEmpty)
          Text(
              'No Workers are available for this Workspace yet. Configure Workers in Conclave Workspace on this computer.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant))
        else
          ...workers.map((worker) => _WorkerRow(worker: worker)),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _WorkerRow extends StatefulWidget {
  const _WorkerRow({required this.worker});
  final AxWorker worker;

  @override
  State<_WorkerRow> createState() => _WorkerRowState();
}

class _WorkerRowState extends State<_WorkerRow> {
  bool _showDiagnostics = false;

  @override
  Widget build(BuildContext context) {
    final worker = widget.worker;
    return Column(
      children: [
        ListTile(
          key: Key('workspace-worker-row-${worker.id}'),
          contentPadding: EdgeInsets.zero,
          onTap: () => setState(() => _showDiagnostics = !_showDiagnostics),
          leading: Icon(worker.isReady
              ? Icons.check_circle_outline
              : Icons.warning_amber),
          title: Text(worker.displayName),
          trailing:
              Icon(_showDiagnostics ? Icons.expand_less : Icons.expand_more),
        ),
        if (_showDiagnostics)
          Padding(
            padding: const EdgeInsets.fromLTRB(48, 0, 8, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 18,
                runSpacing: 8,
                children: [
                  _Diagnostic(label: 'Worker Type', value: worker.displayName),
                  _Diagnostic(
                      label: 'Engine', value: worker.engineVersion ?? '—'),
                  if (worker.profileDefinitionId != null)
                    _Diagnostic(
                      label: 'Integration',
                      value:
                          '${worker.profileDefinitionId}@${worker.profileReleaseVersion ?? '—'}',
                    ),
                  _Diagnostic(
                    label: 'Provider CLI',
                    value: worker.providerToolName ?? '—',
                  ),
                  _Diagnostic(
                    label: 'Provider CLI version',
                    value: worker.providerToolVersion ?? '—',
                  ),
                  _Diagnostic(
                      label: 'Capabilities',
                      value: worker.capabilities.isEmpty
                          ? '—'
                          : worker.capabilities.join(', ')),
                  _Diagnostic(
                      label: 'Local concurrency',
                      value: '${worker.localConcurrencyLimit}'),
                  if (worker.attentionReasonCode != null)
                    _Diagnostic(
                        label: 'Local attention',
                        value:
                            'Resolve ${worker.attentionReasonCode} in Conclave Workspace.'),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Diagnostic extends StatelessWidget {
  const _Diagnostic({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text('$label · $value');
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final online = status.toLowerCase() == 'online';
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.circle,
          size: 9, color: online ? const Color(0xff3ca879) : Colors.grey),
      label: Text(_display(status)),
    );
  }
}

class _EmptyWorkspaces extends StatelessWidget {
  const _EmptyWorkspaces();

  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('No Workspaces connected',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              SizedBox(height: 8),
              Text(
                  'Download and register Conclave Workspace to make a Workspace and its Workers available here.'),
            ],
          ),
        ),
      );
}

String _workspaceSubtitle(AxWorkspace workspace) {
  final machine = _machine(workspace);
  final hostname = _display(workspace.hostname);
  final details = [
    if (machine != '—') machine,
    if (hostname != '—') hostname,
  ];
  return details.isEmpty ? '—' : details.join(' · ');
}

String _machine(AxWorkspace workspace) {
  final os = switch (workspace.platform.toLowerCase()) {
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    _ => workspace.platform,
  };
  final architecture = switch (workspace.architecture.toLowerCase()) {
    'arm64' => 'Apple Silicon',
    'x64' => 'x64',
    _ => workspace.architecture,
  };
  final parts = [os, architecture]
      .where((value) => value.isNotEmpty && value != '—')
      .toList();
  return parts.isEmpty ? '—' : parts.join(' · ');
}

String _display(String value) => value.isEmpty ? '—' : value;

String _statusLabel(AxWorkspace workspace) =>
    workspace.status.toLowerCase() == 'offline' && !workspace.hasRuntimeIdentity
        ? 'Not connected'
        : switch (workspace.status.toLowerCase()) {
            'online' => 'Online',
            'offline' => 'Offline',
            'busy' => 'Busy',
            'draining' => 'Draining',
            'revoked' => 'Revoked',
            _ => workspace.status,
          };

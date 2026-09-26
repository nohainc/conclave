import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

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
    this.onSelectWorkspace,
    required this.onAdd,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
    this.onOpenDownloads,
    this.onConnect,
    this.onWorkspaceWorkerScheduling,
  });

  final List<StudioWorkspace> workspaces;
  final List<StudioWorker> workspaceWorkers;
  final String? initialWorkspaceId;
  final ValueChanged<String?>? onSelectWorkspace;
  final VoidCallback onAdd;
  final ValueChanged<StudioWorkspace> onRename;
  final ValueChanged<StudioWorkspace> onUpdate;
  final ValueChanged<StudioWorkspace> onRevoke;
  final ValueChanged<StudioWorkspace> onGrant;
  final VoidCallback? onOpenDownloads;
  final Future<void> Function(StudioWorkspace)? onConnect;
  final Future<void> Function(StudioWorker worker, String action)?
      onWorkspaceWorkerScheduling;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  final Set<String> _expanded = <String>{};
  final Map<String, GlobalKey> _workspaceCardKeys = <String, GlobalKey>{};
  bool _initializedExpansion = false;
  bool? _wideLayout;

  @override
  void didUpdateWidget(WorkspacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaces.length != widget.workspaces.length) {
      _expanded.clear();
      _initializedExpansion = false;
    }
    if (oldWidget.initialWorkspaceId != widget.initialWorkspaceId &&
        widget.initialWorkspaceId != null) {
      _expanded.add(widget.initialWorkspaceId!);
      _focusWorkspaceCard(widget.initialWorkspaceId!);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final wideLayout = constraints.maxWidth >= 760;
          if (widget.workspaces.length == 2 &&
              _wideLayout != null &&
              _wideLayout != wideLayout) {
            if (wideLayout) {
              _expanded.addAll(widget.workspaces.map((item) => item.id));
            } else {
              _expanded
                ..clear()
                ..add(widget.initialWorkspaceId ?? widget.workspaces.first.id);
            }
          }
          _wideLayout = wideLayout;
          if (!_initializedExpansion) {
            _initializedExpansion = true;
            final selected = widget.initialWorkspaceId;
            if (widget.workspaces.length == 1 ||
                (widget.workspaces.length == 2 && wideLayout)) {
              _expanded.addAll(widget.workspaces.map((item) => item.id));
            } else if (selected != null &&
                widget.workspaces.any((item) => item.id == selected)) {
              _expanded.add(selected);
            } else if (widget.workspaces.isNotEmpty) {
              _expanded.add(widget.workspaces.first.id);
            }
            if (selected != null &&
                widget.workspaces.any((item) => item.id == selected)) {
              _focusWorkspaceCard(selected);
            }
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Workspaces',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3)),
                  ),
                  if (widget.workspaces.isNotEmpty)
                    Tooltip(
                      message: 'Connect Workspace',
                      child: FilledButton.icon(
                        onPressed: widget.onAdd,
                        icon: const Icon(Icons.add),
                        label: const Text('Connect Workspace'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Execution capacity, Workers, project access, and recent activity.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (widget.workspaces.isEmpty)
                _EmptyWorkspaces(
                    onAdd: widget.onAdd,
                    onOpenDownloads: widget.onOpenDownloads)
              else
                ...widget.workspaces.map((workspace) {
                  final expanded = _expanded.contains(workspace.id);
                  final localWorkers = widget.workspaceWorkers
                      .where((worker) =>
                          worker.workspaceId == workspace.id &&
                          worker.status != 'removed')
                      .toList(growable: false);
                  final isTarget = widget.initialWorkspaceId == workspace.id;
                  return Card(
                    key: _workspaceCardKeys.putIfAbsent(
                        workspace.id, GlobalKey.new),
                    margin: const EdgeInsets.only(bottom: 10),
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      side: BorderSide(
                        color: isTarget
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          onTap: () => _toggle(workspace),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(workspace.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                              ),
                              _StatusPill(
                                  status: _statusLabel(workspace.status)),
                              PopupMenuButton<String>(
                                tooltip: 'Workspace actions',
                                onSelected: (action) => switch (action) {
                                  'rename' => widget.onRename(workspace),
                                  'update' => widget.onUpdate(workspace),
                                  'grant' => widget.onGrant(workspace),
                                  'revoke' => widget.onRevoke(workspace),
                                  _ => null,
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'rename', child: Text('Rename')),
                                  PopupMenuItem(
                                      value: 'update',
                                      child: Text('Update Workspace')),
                                  PopupMenuItem(
                                      value: 'grant',
                                      child: Text('Grant to Project')),
                                  PopupMenuItem(
                                      value: 'revoke',
                                      child: Text('Unpair Workspace')),
                                ],
                              ),
                              Icon(expanded
                                  ? Icons.expand_less
                                  : Icons.expand_more),
                            ],
                          ),
                          subtitle: Text(
                            '${_machine(workspace)}  ·  ${localWorkers.length} Workers  ·  ${_grantCount(workspace)} Project grants  ·  ${workspace.activeTaskCount} active work',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (expanded)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: _WorkspaceCardBody(
                              workspace: workspace,
                              workers: localWorkers,
                              onGrant: () => widget.onGrant(workspace),
                              onUpdate: () => widget.onUpdate(workspace),
                              onConnect: widget.onConnect == null
                                  ? null
                                  : () => widget.onConnect!(workspace),
                              onOpenDownloads: widget.onOpenDownloads,
                              onScheduling: widget.onWorkspaceWorkerScheduling,
                            ),
                          ),
                      ],
                    ),
                  );
                }),
            ],
          );
        },
      );

  void _toggle(StudioWorkspace workspace) {
    final isExpanded = _expanded.contains(workspace.id);
    setState(() {
      if (isExpanded) {
        _expanded.remove(workspace.id);
      } else {
        // Three or more Workspaces behave as an accordion. With one or two,
        // users can keep both cards open on wide layouts.
        if (widget.workspaces.length >= 3) _expanded.clear();
        _expanded.add(workspace.id);
      }
    });
    widget.onSelectWorkspace?.call(isExpanded ? null : workspace.id);
  }

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
    required this.workspace,
    required this.workers,
    required this.onGrant,
    required this.onUpdate,
    required this.onConnect,
    required this.onOpenDownloads,
    required this.onScheduling,
  });

  final StudioWorkspace workspace;
  final List<StudioWorker> workers;
  final VoidCallback onGrant;
  final VoidCallback onUpdate;
  final Future<void> Function()? onConnect;
  final VoidCallback? onOpenDownloads;
  final Future<void> Function(StudioWorker, String)? onScheduling;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed =
        workspace.appVersion.isNotEmpty && workspace.appVersion != '—';
    final connected = switch (workspace.status.toLowerCase()) {
      'online' || 'busy' || 'draining' => true,
      _ => false,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 14),
        Wrap(
          spacing: 24,
          runSpacing: 14,
          children: [
            _Fact(
                label: 'Connection status',
                value: _statusLabel(workspace.status)),
            _Fact(label: 'Machine', value: _machine(workspace)),
            _Fact(label: 'Hostname', value: _display(workspace.hostname)),
            _Fact(label: 'App version', value: _display(workspace.appVersion)),
            _Fact(label: 'Last seen', value: _display(workspace.lastSeen)),
            _Fact(label: 'Workers', value: '${workers.length}'),
            _Fact(label: 'Project grants', value: '${_grantCount(workspace)}'),
            _Fact(label: 'Active work', value: '${workspace.activeTaskCount}'),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text('Workers',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: onGrant,
              icon: const Icon(Icons.add_link),
              label: const Text('Project access'),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Configure and authenticate Workers in Conclave Workspace on this computer. Synced Workers appear here for Cloud scheduling.',
          ),
        ),
        if (workers.isEmpty)
          Text(
              'No Workers have synced yet. Configure your first Worker in Conclave Workspace on this computer.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant))
        else
          ...workers.map((worker) => _WorkerRow(
                worker: worker,
                onScheduling: onScheduling,
              )),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if ((!installed || !connected) && onConnect != null)
              OutlinedButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.link_outlined),
                label: const Text('Connect Machine'),
              ),
            if (onOpenDownloads != null)
              OutlinedButton.icon(
                onPressed: onOpenDownloads,
                icon: const Icon(Icons.download_outlined),
                label: Text(installed
                    ? 'Workspace downloads'
                    : 'Download Conclave Workspace'),
              ),
            TextButton.icon(
              onPressed: onUpdate,
              icon: const Icon(Icons.system_update_outlined),
              label: const Text('Update'),
            ),
          ],
        ),
      ],
    );
  }
}

class _WorkerRow extends StatefulWidget {
  const _WorkerRow({required this.worker, required this.onScheduling});
  final StudioWorker worker;
  final Future<void> Function(StudioWorker, String)? onScheduling;

  @override
  State<_WorkerRow> createState() => _WorkerRowState();
}

class _WorkerRowState extends State<_WorkerRow> {
  bool _showDiagnostics = false;

  @override
  Widget build(BuildContext context) {
    final worker = widget.worker;
    final action = switch (worker.schedulingState) {
      'enabled' || 'draining' => 'disable',
      _ => 'enable',
    };
    final readiness = _readinessLabel(worker.status);
    final credential = _credentialLabel(worker.credentialStatus);
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          onTap: () => setState(() => _showDiagnostics = !_showDiagnostics),
          leading: Icon(worker.status == 'ready'
              ? Icons.check_circle_outline
              : Icons.warning_amber),
          title: Text(worker.name),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _WorkerStatus(text: _workerTypeLabel(worker.workerTypeId)),
                _WorkerStatus(text: 'Model · ${worker.defaultModel ?? 'Auto'}'),
                _WorkerStatus(text: readiness),
                _WorkerStatus(text: credential),
                _WorkerStatus(
                    text:
                        'Cloud scheduling · ${_schedulingLabel(worker.schedulingState)}'),
              ],
            ),
          ),
          trailing: widget.onScheduling == null
              ? Icon(_showDiagnostics ? Icons.expand_less : Icons.expand_more)
              : Wrap(
                  spacing: 2,
                  children: [
                    TextButton(
                      onPressed: () => widget.onScheduling!(worker, action),
                      child: Text(action == 'enable' ? 'Enable' : 'Disable'),
                    ),
                    if (worker.schedulingState == 'enabled')
                      TextButton(
                        onPressed: () => widget.onScheduling!(worker, 'drain'),
                        child: const Text('Drain'),
                      ),
                  ],
                ),
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
                  _Diagnostic(label: 'Worker Type', value: worker.workerTypeId),
                  _Diagnostic(
                      label: 'Adapter', value: worker.adapterVersion ?? '—'),
                  _Diagnostic(
                      label: 'Capabilities',
                      value: worker.capabilities.isEmpty
                          ? '—'
                          : worker.capabilities.join(', ')),
                  _Diagnostic(
                      label: 'Local concurrency',
                      value: '${worker.localConcurrencyLimit}'),
                  if (worker.cloudConcurrencyLimit != null)
                    _Diagnostic(
                        label: 'Cloud concurrency',
                        value: '${worker.cloudConcurrencyLimit}'),
                  if (credential != 'Authentication ready' &&
                      credential != 'Authentication not required')
                    _Diagnostic(
                        label: 'Local attention',
                        value:
                            'Complete sign-in or setup in Conclave Workspace on ${worker.workspaceName}.'),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkerStatus extends StatelessWidget {
  const _WorkerStatus({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Chip(
        visualDensity: VisualDensity.compact,
        label: Text(text),
      );
}

class _Diagnostic extends StatelessWidget {
  const _Diagnostic({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text('$label · $value');
}

String _workerTypeLabel(String value) => switch (value.toLowerCase()) {
      'claude-code' => 'Claude Code',
      'anthropic-api' => 'Anthropic API',
      'openai-api' => 'OpenAI API',
      'gemini-api' => 'Gemini API',
      'antigravity' => 'Antigravity',
      'ollama' => 'Ollama',
      'codex' => 'Codex',
      _ => value
          .split(RegExp(r'[-_]'))
          .where((part) => part.isNotEmpty)
          .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
          .join(' '),
    };

String _readinessLabel(String value) => switch (value.toLowerCase()) {
      'ready' => 'Ready locally',
      'disabled' => 'Disabled locally',
      'removed' => 'Removed locally',
      'needs_attention' => 'Needs local attention',
      _ => 'Readiness · $value',
    };

String _credentialLabel(String value) => switch (value.toLowerCase()) {
      'ready' => 'Authentication ready',
      'not_required' => 'Authentication not required',
      'needs_authentication' || 'missing' => 'Sign-in required',
      'expired' => 'Sign-in expired',
      'error' => 'Authentication needs attention',
      _ => 'Authentication · $value',
    };

String _schedulingLabel(String value) => switch (value.toLowerCase()) {
      'enabled' => 'Enabled',
      'disabled' => 'Disabled',
      'draining' => 'Draining',
      _ => value,
    };

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 170,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );
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
  const _EmptyWorkspaces({required this.onAdd, required this.onOpenDownloads});
  final VoidCallback onAdd;
  final VoidCallback? onOpenDownloads;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('No Workspaces connected',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
                'Connect a computer running Conclave Workspace to make local Workers available to your Projects.'),
            const SizedBox(height: 14),
            Wrap(spacing: 8, children: [
              FilledButton(
                  onPressed: onAdd, child: const Text('Connect Workspace')),
              if (onOpenDownloads != null)
                OutlinedButton(
                    onPressed: onOpenDownloads,
                    child: const Text('Download Conclave Workspace')),
            ]),
          ]),
        ),
      );
}

String _machine(StudioWorkspace workspace) {
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

String _statusLabel(String status) => switch (status.toLowerCase()) {
      'enrolled' || 'not_connected' => 'Not connected',
      'online' => 'Online',
      'pairing' => 'Pairing',
      'offline' => 'Offline',
      'busy' => 'Busy',
      'draining' => 'Draining',
      'revoked' => 'Revoked',
      _ => status,
    };

int _grantCount(StudioWorkspace workspace) => workspace.projectGrantCount;

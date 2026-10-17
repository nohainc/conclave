import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';
import '../../ax/ax_workspace_member_access.dart';
import '../workflows/workflows_page.dart';
import 'workspace_member_access_section.dart';
import 'workspace_sharing_section.dart';

export 'workspaces_overview.dart';

/// Workspace-owned execution capacity, its Workers, and its Workflows.
///
/// Each registered Workspace is a tab; Workflows are configured inside the tab
/// of the Workspace they run on. Workspace routes always render this view.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    super.key,
    required this.workspaces,
    this.workspaceWorkers = const [],
    this.initialWorkspaceId,
    this.workflowCatalogs,
    this.workflowConfigurations,
    this.viewerEmail,
    this.memberAccessSource,
    this.sharingSource,
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

  /// Workflow inputs. When either is null the Workflows section is hidden.
  final AxSessionCatalogs? workflowCatalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? viewerEmail;

  /// Enables the owner's "Member access" section of each Workspace tab.
  final AxWorkspaceMemberAccessDataSource? memberAccessSource;

  /// Enables lending: the owner's sharing section and the invited person's banner.
  final AxWorkspaceSharingDataSource? sharingSource;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage>
    with TickerProviderStateMixin {
  TabController? _tabs;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialWorkspaceId;
    _syncTabs();
  }

  @override
  void didUpdateWidget(WorkspacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialWorkspaceId != widget.initialWorkspaceId &&
        widget.initialWorkspaceId != null) {
      _selectedId = widget.initialWorkspaceId;
    }
    _syncTabs();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  void _syncTabs() {
    final count = widget.workspaces.length;
    if (count == 0) {
      _tabs?.dispose();
      _tabs = null;
      return;
    }
    var index = widget.workspaces.indexWhere((w) => w.id == _selectedId);
    if (index < 0) index = 0;
    if (_tabs?.length != count) {
      _tabs?.dispose();
      _tabs = TabController(length: count, vsync: this, initialIndex: index)
        ..addListener(_onTabChanged);
    } else if (_tabs!.index != index) {
      _tabs!.index = index;
    }
    _selectedId = widget.workspaces[index].id;
  }

  void _onTabChanged() {
    final tabs = _tabs;
    if (tabs == null || tabs.indexIsChanging) return;
    final id = widget.workspaces[tabs.index].id;
    if (id != _selectedId) setState(() => _selectedId = id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabs = _tabs;
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
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (widget.sharingSource != null)
          WorkspaceInvitationsBanner(
              key: const ValueKey('workspace-invitations-banner'),
              source: widget.sharingSource!),
        if (tabs == null)
          const _EmptyWorkspaces()
        else ...[
          TabBar(
            key: const Key('workspace-tabs'),
            controller: tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: theme.colorScheme.onSurface,
            unselectedLabelColor: theme.brightness == Brightness.dark
                ? Colors.white38
                : Colors.black45,
            indicatorColor: theme.colorScheme.onSurface,
            dividerHeight: 0,
            tabs: [
              for (final workspace in widget.workspaces)
                Tab(
                    key: Key('workspace-tab-${workspace.id}'),
                    text: workspace.name),
            ],
          ),
          const Divider(height: 1, thickness: 1),
          const SizedBox(height: 16),
          _workspaceDetail(context, widget.workspaces[tabs.index]),
        ],
      ],
    );
  }

  Widget _workspaceDetail(BuildContext context, AxWorkspace workspace) {
    final workers = widget.workspaceWorkers
        .where((worker) =>
            worker.workspaceId == workspace.id && worker.status != 'removed')
        .toList(growable: false);
    final catalogs = widget.workflowCatalogs;
    final configurations = widget.workflowConfigurations;
    return Column(
      key: Key('workspace-detail-${workspace.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                title: Text(_workspaceSubtitle(workspace),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: SizedBox(
                  width: 96,
                  child: Center(
                      child: _StatusPill(status: _statusLabel(workspace))),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: _WorkspaceCardBody(workers: workers),
              ),
            ],
          ),
        ),
        if (catalogs != null && configurations != null) ...[
          const SizedBox(height: 24),
          WorkflowsPage(
            key: ValueKey('workspace-workflows-${workspace.id}'),
            catalogs: catalogs,
            configurations: configurations.forWorkspace(workspace.id),
            viewerEmail: widget.viewerEmail,
            workspaceId: workspace.id,
          ),
        ],
        if (widget.sharingSource != null) ...[
          const SizedBox(height: 24),
          WorkspaceSharingSection(
            key: ValueKey('workspace-sharing-${workspace.id}'),
            workspaceId: workspace.id,
            source: widget.sharingSource!,
          ),
        ],
        if (widget.memberAccessSource != null) ...[
          const SizedBox(height: 24),
          WorkspaceMemberAccessSection(
            key: ValueKey('workspace-member-access-${workspace.id}'),
            workspaceId: workspace.id,
            workers: widget.workspaceWorkers,
            source: widget.memberAccessSource!,
          ),
        ],
      ],
    );
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

class _WorkerRow extends StatelessWidget {
  const _WorkerRow({required this.worker});
  final AxWorker worker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = worker.executionOptions?.models
            .where((model) => model.status != 'unavailable')
            .map((model) => model.name)
            .toList() ??
        const <String>[];
    final providerTool = [
      worker.providerToolName ?? 'Provider CLI',
      worker.providerToolVersion ?? 'Not detected',
    ].join(' ');
    return Column(
      children: [
        ListTile(
          key: Key('workspace-worker-row-${worker.id}'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(worker.isReady
              ? Icons.check_circle_outline
              : Icons.warning_amber),
          title: Text(worker.displayName),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(providerTool, style: theme.textTheme.bodySmall),
                if (worker.profileReleaseVersion != null)
                  Text('Profile v${worker.profileReleaseVersion}',
                      style: theme.textTheme.bodySmall),
                Text(
                  'Models: ${models.isEmpty ? 'Unavailable' : models.join(', ')}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
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

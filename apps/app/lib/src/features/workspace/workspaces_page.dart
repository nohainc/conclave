import 'package:syntila_design/syntila_design.dart';
import '../../ax/ax_people.dart';
import '../../ax/ax_data.dart'
    show AxWorkflowWorkspaceDataSource, AxWorkflowWorkspaceSettings;
import '../../ax/sync/ax_query_builder.dart';
import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/worker_presentation.dart';
import '../../ax/worker_usage.dart';
import 'worker_usage_dialog.dart';
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
    this.workerUsageSource,
    this.initialWorkspaceId,
    this.workflowCatalogs,
    this.workflowConfigurations,
    this.viewerEmail,
    this.memberAccessSource,
    this.sharingSource,
    this.people = const [],
    this.personAccessSource,
    this.onRevoke,
    // Retained as optional compatibility inputs while callers are audited.
    VoidCallback? onAdd,
    ValueChanged<AxWorkspace>? onRename,
    ValueChanged<AxWorkspace>? onUpdate,
    Future<void> Function(AxWorkspace)? onConnect,
  });

  final ValueChanged<AxWorkspace>? onRevoke;

  /// Owner-only, Profile-defined usage commands; reports remain local view state.
  final AxWorkerUsageDataSource? workerUsageSource;
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

  /// People the owner can share a Workspace with.
  final List<AxPerson> people;

  /// Enables editing one person's Workers, models and mode.
  final AxWorkspacePersonAccessDataSource? personAccessSource;

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
    final isDark = theme.brightness == Brightness.dark;
    final tabs = _tabs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.sharingSource != null)
          WorkspaceInvitationsBanner(
              key: const ValueKey('workspace-invitations-banner'),
              source: widget.sharingSource!),
        if (tabs == null)
          const _EmptyWorkspaces()
        else ...[
          SizedBox(
            width: double.infinity,
            child: TabBar(
              key: const Key('workspace-tabs'),
              controller: tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              labelColor: SyntilaColors.primaryForeground(isDark),
              unselectedLabelColor: SyntilaColors.textSecondary(isDark),
              indicatorColor: SyntilaColors.primaryForeground(isDark),
              dividerHeight: 0,
              tabs: [
                for (final workspace in widget.workspaces)
                  Tab(
                      key: Key('workspace-tab-${workspace.id}'),
                      text: workspace.name),
              ],
            ),
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
    final machineName =
        workspace.hostname.isNotEmpty && workspace.hostname != '—'
            ? workspace.hostname
            : workspace.name;
    final machineOs = _machine(workspace);

    return Column(
      key: Key('workspace-detail-${workspace.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (machineName.isNotEmpty && machineName != '—') ...[
              Text(
                machineName,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 8),
            ],
            if (machineOs != '—') ...[
              Text(
                machineOs,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(width: 8),
            ],
            if (workspace.shared) ...[
              const Chip(
                  key: ValueKey('workspace-shared-badge'),
                  avatar: Icon(Icons.people_outline, size: 16),
                  label: Text('Shared with you')),
              const SizedBox(width: 8),
            ],
            const Spacer(),
            _StatusPill(status: _statusLabel(workspace)),
          ],
        ),
        if (configurations != null &&
            configurations.source is AxWorkflowWorkspaceDataSource)
          _DefaultWorkspaceControl(
            key: ValueKey('default-workspace-${workspace.id}'),
            configurations: configurations,
            workspace: workspace,
          ),
        const SizedBox(height: 16),
        _WorkspaceCardBody(
          workers: workers,
          usageSource:
              workspace.role == 'owner' ? widget.workerUsageSource : null,
          online: workspace.status.toLowerCase() == 'online',
        ),
        if (catalogs != null && configurations != null) ...[
          const SizedBox(height: 24),
          WorkflowsPage(
            key: ValueKey('workspace-workflows-${workspace.id}'),
            catalogs: catalogs,
            configurations: configurations.forWorkspace(workspace.id),
            viewerEmail: widget.viewerEmail,
            workspaceId: workspace.id,
            showWorkspaceAction: false,
          ),
        ],
        // A lent Workspace is used, not managed: its owner controls access.
        if (widget.sharingSource != null && !workspace.shared) ...[
          const SizedBox(height: 24),
          WorkspaceSharingSection(
            key: ValueKey('workspace-sharing-${workspace.id}'),
            workspaceId: workspace.id,
            source: widget.sharingSource!,
            people: widget.people,
            memberAccessSource: widget.memberAccessSource,
            personAccessSource: widget.personAccessSource,
            workers: widget.workspaceWorkers,
            expandable: true,
          ),
        ],
        if (widget.memberAccessSource != null && !workspace.shared) ...[
          const SizedBox(height: 24),
          WorkspaceMemberAccessSection(
            key: ValueKey('workspace-member-access-${workspace.id}'),
            workspaceId: workspace.id,
            workers: widget.workspaceWorkers,
            source: widget.memberAccessSource!,
            expandable: true,
          ),
        ],
        if (!workspace.shared && widget.onRevoke != null) ...[
          const SizedBox(height: 32),
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: ValueKey('revoke-workspace-${workspace.id}'),
              icon:
                  const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              label: const Text(
                'Unregister Workspace',
                style: TextStyle(color: Colors.red),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
              ),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    constraints: SyntilaDialogStyle.small,
                    title: Text('Unregister ${workspace.name}?'),
                    content: const Text(
                      'This will disconnect and revoke the Workspace registration in Cloud. You can register it again at any time with syntila-workspace login.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        key: const ValueKey('confirm-revoke-workspace'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Unregister'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  widget.onRevoke!(workspace);
                }
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _WorkspaceCardBody extends StatelessWidget {
  const _WorkspaceCardBody({
    required this.workers,
    required this.usageSource,
    required this.online,
  });

  final List<AxWorker> workers;
  final AxWorkerUsageDataSource? usageSource;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (workers.isEmpty) {
      return Text(
        'No Workers are available for this Workspace yet. Configure Workers in Syntila Workspace on this computer.',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Compute columns based on compact card minimum width of ~240px
        const double gap = 12;
        final double availableWidth = constraints.maxWidth;
        final int columns = (availableWidth / 240).floor().clamp(1, 4);

        if (columns == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < workers.length; i++) ...[
                if (i > 0) const SizedBox(height: gap),
                _WorkerCard(
                    worker: workers[i],
                    usageSource: usageSource,
                    online: online),
              ],
            ],
          );
        }

        // When multiple columns, group into rows and wrap in IntrinsicHeight
        // so all worker widgets in the row share the same height.
        final List<List<AxWorker>> rows = [];
        for (int i = 0; i < workers.length; i += columns) {
          rows.add(workers.sublist(i,
              (i + columns < workers.length) ? i + columns : workers.length));
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int c = 0; c < columns; c++) ...[
                      if (c > 0) const SizedBox(width: gap),
                      Expanded(
                        child: c < rows[r].length
                            ? _WorkerCard(
                                worker: rows[r][c],
                                usageSource: usageSource,
                                online: online)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard(
      {required this.worker, required this.usageSource, required this.online});
  final AxWorkerUsageDataSource? usageSource;
  final bool online;
  final AxWorker worker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = worker.executionOptions?.models
            .where((model) => model.status != 'unavailable')
            .map((model) => model.name)
            .toList() ??
        const <String>[];
    final toolName = worker.providerToolName ?? 'Provider CLI';
    final toolVersion = worker.providerToolVersion ?? 'Not detected';
    final toolInfo = '$toolName $toolVersion';

    final presentation = WorkerPresentation.resolve(
      worker.workerTypeId,
      worker.displayName,
      profileDefinitionId: worker.profileDefinitionId,
      providerToolName: worker.providerToolName,
    );
    final workerIcon =
        presentation.iconAssetForBrightness(Theme.of(context).brightness);
    final isDark = theme.brightness == Brightness.dark;

    final Widget iconWidget = workerIcon != null
        ? Image.asset(
            workerIcon,
            width: 32,
            height: 32,
            fit: BoxFit.contain,
            semanticLabel: '${worker.displayName} icon',
          )
        : Icon(
            worker.isReady ? Icons.smart_toy_outlined : Icons.warning_amber,
            size: 32,
            color: worker.isReady ? null : Colors.amber,
          );

    final modelsText = models.isEmpty ? 'Unavailable' : models.join(' · ');

    return Card(
      key: Key('workspace-worker-row-${worker.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: iconWidget,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              worker.displayName,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (!worker.isReady)
                            const Icon(
                              Icons.warning_amber,
                              size: 16,
                              color: Colors.amber,
                            )
                          else
                            Icon(
                              Icons.check_circle_outline,
                              size: 16,
                              color: SyntilaColors.successText(isDark),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              toolInfo,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (usageSource != null) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              key: ValueKey(
                                  'workspace-worker-usage-${worker.id}'),
                              icon: const Icon(Icons.speed, size: 16),
                              iconSize: 16,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                  width: 20, height: 20),
                              style: const ButtonStyle(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: online && worker.isReady
                                  ? () => showDialog<void>(
                                        context: context,
                                        builder: (_) => WorkerUsageDialog(
                                            source: usageSource!,
                                            worker: worker),
                                      )
                                  : null,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              modelsText,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
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
          size: 9,
          color: online
              ? SyntilaColors.successText(
                  Theme.of(context).brightness == Brightness.dark)
              : SyntilaColors.neutral),
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
                  'Download and register Syntila Workspace to make a Workspace and its Workers available here.'),
            ],
          ),
        ),
      );
}

String _machine(AxWorkspace workspace) {
  final os = switch (workspace.platform.toLowerCase()) {
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    _ => workspace.platform,
  };
  return os.isEmpty ? '—' : os;
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

/// The same user selection inherited by Spaces and their Threads.
class _DefaultWorkspaceControl extends StatefulWidget {
  const _DefaultWorkspaceControl(
      {super.key, required this.configurations, required this.workspace});
  final AxWorkflowConfigurations configurations;
  final AxWorkspace workspace;
  @override
  State<_DefaultWorkspaceControl> createState() =>
      _DefaultWorkspaceControlState();
}

class _DefaultWorkspaceControlState extends State<_DefaultWorkspaceControl> {
  bool _busy = false;
  String? _error;

  Future<void> _makeDefault() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              constraints: SyntilaDialogStyle.small,
              title: const Text('Change default Workspace?'),
              content: Text(
                  'Spaces using the default Workspace, including new Spaces, will use ${widget.workspace.name}. Workflow overrides in inheriting Spaces are reset. Saved per-Workspace workflows and existing runs keep their settings.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    key: const ValueKey('confirm-default-workspace'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Make default')),
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.configurations.selectWorkspace(widget.workspace.id);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      AxQueryBuilder<AxWorkflowWorkspaceSettings>(
        engine: widget.configurations.engine,
        query: widget.configurations.workspaceQuery,
        builder: (context, state) {
          final settings = state.data;
          final selected = settings?.workspaceId == widget.workspace.id;
          final eligible =
              settings?.workspaces.any((w) => w.id == widget.workspace.id) ??
                  false;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (selected)
                  const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Chip(
                          key: ValueKey('default-workspace-badge'),
                          avatar: Icon(Icons.check, size: 16),
                          label: Text('Default Workspace')))
                else if (eligible)
                  TextButton(
                      key: const ValueKey('make-default-workspace'),
                      onPressed: _busy ? null : _makeDefault,
                      child: const Text('Make default')),
                if (state.error != null)
                  TextButton(
                      onPressed: () => widget.configurations.engine
                          .refresh(widget.configurations.workspaceQuery),
                      child: const Text('Retry default Workspace')),
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
              ]);
        },
      );
}

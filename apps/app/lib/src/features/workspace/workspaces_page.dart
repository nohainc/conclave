import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';
import 'workers_tab.dart';
import 'workspace_detail.dart';
import 'workspaces_overview.dart';

export 'workers_tab.dart';
export 'workspace_detail.dart';
export 'workspaces_overview.dart';

/// Execution area for Workspaces and configured Workers.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    super.key,
    required this.workspaces,
    required this.workers,
    this.configuredWorkers = const [],
    this.plugins = const [],
    this.initialTab = 0,
    required this.onAdd,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
    this.workerActionMessage,
    this.onDismissWorkerActionMessage,
    this.onAddConfiguredWorker,
    this.onOpenConfiguredWorker,
    this.onSetupConfiguredWorkerWorkspace,
    this.onRemoveConfiguredWorkerWorkspace,
  });

  final List<StudioAgent> workspaces;
  final List<StudioWorker> workers;
  final List<StudioConfiguredWorker> configuredWorkers;
  final List<StudioPlugin> plugins;
  final int initialTab;
  final VoidCallback onAdd;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;
  final String? workerActionMessage;
  final VoidCallback? onDismissWorkerActionMessage;
  final VoidCallback? onAddConfiguredWorker;
  final ValueChanged<StudioConfiguredWorker>? onOpenConfiguredWorker;
  final Future<void> Function(
          StudioConfiguredWorker worker, String workspaceId, String action)?
      onSetupConfiguredWorkerWorkspace;
  final Future<void> Function(
          StudioConfiguredWorker worker, String workspaceId)?
      onRemoveConfiguredWorkerWorkspace;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage>
    with SingleTickerProviderStateMixin {
  StudioAgent? selected;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      initialIndex: widget.initialTab.clamp(0, 1),
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(WorkspacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.clamp(0, 1));
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = selected == null
        ? null
        : widget.workspaces
            .where((item) => item.id == selected!.id)
            .firstOrNull;

    if (active != null) {
      return WorkspaceDetailView(
        workspace: active,
        onBack: () => setState(() => selected = null),
        onRename: widget.onRename,
        onUpdate: widget.onUpdate,
        onRevoke: widget.onRevoke,
        onGrant: widget.onGrant,
        configuredWorkers: widget.configuredWorkers,
        onOpenConfiguredWorker: widget.onOpenConfiguredWorker,
        onSetupConfiguredWorkerWorkspace:
            widget.onSetupConfiguredWorkerWorkspace,
        onRemoveConfiguredWorkerWorkspace:
            widget.onRemoveConfiguredWorkerWorkspace,
      );
    }

    return _buildExecutionCenter(context);
  }

  Widget _buildExecutionCenter(BuildContext context) {
    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        final activeIndex = _tabController.index;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(
              context,
              'Execution',
              'Workspaces are where AI runs. Workers are configured AI/tool identities. Projects and Workstreams are what they work on.',
            ),
            const SizedBox(height: 16),
            Center(
              child: TabBar(
                controller: _tabController,
                tabAlignment: TabAlignment.center,
                isScrollable: true,
                tabs: const [
                  Tab(text: 'Workspaces'),
                  Tab(text: 'Workers'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (activeIndex == 0)
              WorkspacesOverview(
                workspaces: widget.workspaces,
                onAdd: widget.onAdd,
                onSelectWorkspace: (ws) => setState(() => selected = ws),
              )
            else if (activeIndex == 1)
              WorkersTab(
                workspaces: widget.workspaces,
                plugins: widget.plugins,
                configuredWorkers: widget.configuredWorkers,
                onAddConfiguredWorker: widget.onAddConfiguredWorker,
                onOpenConfiguredWorker: widget.onOpenConfiguredWorker,
              )
          ],
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    String title,
    String subtitle,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ],
      );
}

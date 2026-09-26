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
    this.workspaceWorkers = const [],
    this.plugins = const [],
    this.initialTab = 0,
    this.initialWorkspaceId,
    this.onSelectWorkspace,
    required this.onAdd,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
    this.onOpenDownloads,
    this.onConnect,
    this.workerActionMessage,
    this.onDismissWorkerActionMessage,
    this.onWorkspaceWorkerScheduling,
  });

  final List<StudioAgent> workspaces;
  final List<StudioWorker> workers;
  final List<StudioWorkspaceWorker> workspaceWorkers;
  final List<StudioPlugin> plugins;
  final int initialTab;
  final String? initialWorkspaceId;
  final ValueChanged<String?>? onSelectWorkspace;
  final VoidCallback onAdd;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;
  final VoidCallback? onOpenDownloads;
  final Future<void> Function(StudioAgent)? onConnect;
  final String? workerActionMessage;
  final VoidCallback? onDismissWorkerActionMessage;
  final Future<void> Function(StudioWorkspaceWorker worker, String action)?
      onWorkspaceWorkerScheduling;

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
    if (widget.initialWorkspaceId != null) {
      selected = widget.workspaces
          .where((item) => item.id == widget.initialWorkspaceId)
          .firstOrNull;
    }
  }

  @override
  void didUpdateWidget(WorkspacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.clamp(0, 1));
    }
    if (oldWidget.initialWorkspaceId != widget.initialWorkspaceId) {
      setState(() {
        if (widget.initialWorkspaceId != null) {
          selected = widget.workspaces
              .where((item) => item.id == widget.initialWorkspaceId)
              .firstOrNull;
        } else {
          selected = null;
        }
      });
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
        onBack: () {
          setState(() => selected = null);
          widget.onSelectWorkspace?.call(null);
        },
        onRename: widget.onRename,
        onUpdate: widget.onUpdate,
        onRevoke: widget.onRevoke,
        onGrant: widget.onGrant,
        onConnect: widget.onConnect ?? (_) async {},
        onOpenDownloads: widget.onOpenDownloads,
        workspaceWorkers: widget.workspaceWorkers,
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
                onSelectWorkspace: (ws) {
                  setState(() => selected = ws);
                  widget.onSelectWorkspace?.call(ws.id);
                },
                onOpenDownloads: widget.onOpenDownloads,
              )
            else if (activeIndex == 1)
              WorkersTab(
                workspaces: widget.workspaces,
                plugins: widget.plugins,
                workspaceWorkers: widget.workspaceWorkers,
                onScheduling: widget.onWorkspaceWorkerScheduling,
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
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
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

import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';
import 'accounts_tab.dart';
import 'workers_tab.dart';
import 'workspace_detail.dart';
import 'workspaces_overview.dart';

export 'accounts_tab.dart';
export 'workers_tab.dart';
export 'workspace_detail.dart';
export 'workspaces_overview.dart';

/// Execution configuration center consolidating Workspaces, Workers, and AI Accounts.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    super.key,
    required this.workspaces,
    required this.workers,
    required this.accounts,
    this.plugins = const [],
    this.initialTab = 0,
    required this.onAdd,
    required this.onRename,
    required this.onUpdate,
    required this.onRevoke,
    required this.onGrant,
    this.onSetWorkerAvailability,
    this.onShowWorkerDetails,
    this.onCreateAccount,
    this.onRequestAccountSetup,
    this.onRevokeAccount,
    this.onNavigateToAccounts,
    this.workerActionMessage,
    this.onDismissWorkerActionMessage,
  });

  final List<StudioAgent> workspaces;
  final List<StudioWorker> workers;
  final List<StudioCredentialProfile> accounts;
  final List<StudioPlugin> plugins;
  final int initialTab;
  final VoidCallback onAdd;
  final ValueChanged<StudioAgent> onRename;
  final ValueChanged<StudioAgent> onUpdate;
  final ValueChanged<StudioAgent> onRevoke;
  final ValueChanged<StudioAgent> onGrant;
  final void Function(StudioPlugin plugin, StudioAgent host, bool desired)?
      onSetWorkerAvailability;
  final ValueChanged<StudioPlugin>? onShowWorkerDetails;
  final VoidCallback? onCreateAccount;
  final ValueChanged<StudioCredentialProfile>? onRequestAccountSetup;
  final ValueChanged<StudioCredentialProfile>? onRevokeAccount;
  final VoidCallback? onNavigateToAccounts;
  final String? workerActionMessage;
  final VoidCallback? onDismissWorkerActionMessage;

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
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(WorkspacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.clamp(0, 2));
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
        accounts: widget.accounts,
        onBack: () => setState(() => selected = null),
        onRename: widget.onRename,
        onUpdate: widget.onUpdate,
        onRevoke: widget.onRevoke,
        onGrant: widget.onGrant,
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
              'Workspaces',
              'Execution environments, Workers, and AI Accounts.',
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
                  Tab(text: 'AI Accounts'),
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
                onSetWorkerAvailability: widget.onSetWorkerAvailability,
                onShowWorkerDetails: widget.onShowWorkerDetails,
                onNavigateToAccounts: widget.onNavigateToAccounts,
              )
            else
              AccountsTab(
                accounts: widget.accounts,
                onCreateAccount: widget.onCreateAccount,
                onRequestAccountSetup: widget.onRequestAccountSetup,
                onRevokeAccount: widget.onRevokeAccount,
                workerActionMessage: widget.workerActionMessage,
                onDismissWorkerActionMessage:
                    widget.onDismissWorkerActionMessage,
              ),
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

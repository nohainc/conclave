part of '../spaces_pages.dart';

class SpacePage extends StatelessWidget {
  const SpacePage({
    super.key,
    required this.space,
    required this.dataSource,
    required this.onOpenThread,
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onSpaceUpdated,
    this.spaceThreads,
    this.workspaceGrants,
    this.tabQueries,
    this.mutations,
  });

  final AxSpace space;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenThread;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxSpace>? onSpaceUpdated;
  final AxSpaceThreads? spaceThreads;
  final AxSpaceWorkspaceGrants? workspaceGrants;
  final AxSpaceTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;

  // Compatibility getters/factory

  @override
  Widget build(BuildContext context) => _SpaceWorkspace(
        key: ValueKey(space.id),
        space: space,
        dataSource: dataSource,
        onOpenThread: onOpenThread,
        onOpenWorkspace: onOpenWorkspace,
        onEdit: onEdit,
        onArchive: onArchive,
        onDelete: onDelete,
        onSpaceUpdated: onSpaceUpdated,
        spaceThreads: spaceThreads,
        workspaceGrants: workspaceGrants,
        tabQueries: tabQueries,
        mutations: mutations,
      );
}

class _SpaceWorkspace extends StatefulWidget {
  const _SpaceWorkspace({
    super.key,
    required this.space,
    required this.dataSource,
    required this.onOpenThread,
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onSpaceUpdated,
    this.spaceThreads,
    this.workspaceGrants,
    this.tabQueries,
    this.mutations,
  });

  final AxSpace space;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenThread;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxSpace>? onSpaceUpdated;
  final AxSpaceThreads? spaceThreads;
  final AxSpaceWorkspaceGrants? workspaceGrants;
  final AxSpaceTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;

  @override
  State<_SpaceWorkspace> createState() => _SpaceWorkspaceState();
}

class _SpaceWorkspaceState extends State<_SpaceWorkspace>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<AxThread> threads;
  List<AxSpaceMember> members = const [];
  List<AxSpaceInvitation> invitations = const [];
  List<AxWorkspace> ownedWorkspaces = const [];
  List<Map<String, dynamic>> spaceWorkspaces = const [];
  bool threadsLoading = true;
  bool membersLoading = true;
  Object? threadsError;
  Object? membersError;
  late AxSpaceTabQueries _queries;
  late AxWorkflowConfigurations _workflowConfigurations;
  late AxSpaceThreads _streams;
  late AxCollaborationMutations _collaboration;
  final _tabCancels = <void Function()>[];
  int _activeTab = -1;
  bool executionLoading = true;
  Object? executionError;
  late AxSpaceWorkspaceGrants _grants;
  bool get canManage => widget.space.effectivePermissions.manageOwnThreads;
  bool get canAttachWorkspace =>
      widget.space.effectivePermissions.attachWorkspace;
  bool get canInvite => widget.space.effectivePermissions.inviteMembers;
  bool? _allowWorkOverride;
  bool _savingWorkSetting = false;
  final _savingMembers = <String>{};
  bool get allowWork => _allowWorkOverride ?? widget.space.allowWork;
  bool get isOwner => widget.space.role == 'owner';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _configureQueries();
    _tabController.addListener(_onTabChanged);
    _onTabChanged();
  }

  void _configureQueries() {
    _queries =
        widget.tabQueries ?? AxSpaceTabQueries.forSource(widget.dataSource);
    _streams = widget.spaceThreads ?? _queries.threads;
    _collaboration = widget.mutations ??
        AxCollaborationMutations(widget.dataSource, engine: _streams.engine);
    _grants = widget.workspaceGrants ??
        AxSpaceWorkspaceGrants.forSource(widget.dataSource);
    _workflowConfigurations = AxWorkflowConfigurations(widget.dataSource,
        engine: _streams.engine, spaceId: widget.space.id);
    threads = _streams.peek(widget.space.id);
  }

  void _onTabChanged() {
    if (_activeTab == _tabController.index) return;
    _activeTab = _tabController.index;
    _bindActiveTab();
  }

  void _cancelTab() {
    for (final cancel in _tabCancels) {
      cancel();
    }
    _tabCancels.clear();
  }

  void _ensure<T>(AxSyncEngine engine, AxQuery<T> query) {
    unawaited(engine
        .ensure(query)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  void _bindActiveTab() {
    _cancelTab();
    final id = widget.space.id;
    if (_activeTab == 0) {
      final query = _streams.query(id);
      void apply(AxQueryState<List<AxThread>> state) {
        threads = state.data ?? const [];
        threadsLoading = !state.hasData && state.isFetching;
        threadsError = state.error;
      }

      apply(_streams.engine.peek(query));
      _tabCancels.add(_streams.engine.watch(query, (state) {
        if (mounted) _updateState(() => apply(state));
      }, fireImmediately: false));
      _ensure(_streams.engine, query);
    } else if (_activeTab == 1) {
      void apply(AxQueryState<AxWorkspaceGrants> state) {
        spaceWorkspaces = state.data ?? const [];
        executionError = state.error;
        executionLoading = !state.hasData && state.isFetching;
      }

      apply(_grants.peek(id));
      _tabCancels.add(_grants.watch(id, (state) {
        if (mounted) _updateState(() => apply(state));
      }));
      unawaited(_grants
          .ensure(id)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    } else if (_activeTab == 2) {
      final membersQuery = _queries.members(id);
      final invitationsQuery = _queries.invitations(id);
      void apply() {
        final memberState = _queries.engine.peek(membersQuery);
        final invitationState = _queries.engine.peek(invitationsQuery);
        members = memberState.data ?? const [];
        invitations = invitationState.data ?? const [];
        membersLoading = !memberState.hasData && memberState.isFetching;
        membersError = memberState.error ?? invitationState.error;
      }

      apply();
      _tabCancels.add(_queries.engine.watch(membersQuery, (_) {
        if (mounted) _updateState(apply);
      }, fireImmediately: false));
      _tabCancels.add(_queries.engine.watch(invitationsQuery, (_) {
        if (mounted) _updateState(apply);
      }, fireImmediately: false));
      _ensure(_queries.engine, membersQuery);
      _ensure(_queries.engine, invitationsQuery);
    }
  }

  void _recordThreads() {
    _streams.engine.update(
        _streams.query(widget.space.id), (_) => List.unmodifiable(threads));
    _queries.engine.invalidate(_queries.audit(widget.space.id).key);
  }

  @override
  void didUpdateWidget(_SpaceWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space != widget.space) _allowWorkOverride = null;
    if (oldWidget.space.id != widget.space.id ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.spaceThreads != widget.spaceThreads ||
        oldWidget.workspaceGrants != widget.workspaceGrants ||
        oldWidget.tabQueries != widget.tabQueries ||
        oldWidget.mutations != widget.mutations) {
      _cancelTab();
      _configureQueries();
      _bindActiveTab();
    }
  }

  @override
  void dispose() {
    _cancelTab();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _updateState(VoidCallback callback) => setState(callback);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Stack(
                      alignment: Alignment.topCenter,
                      children: [
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.space.name.isNotEmpty
                                    ? widget.space.name
                                    : 'Untitled Space',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              if (widget.space.description
                                  .trim()
                                  .isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  widget.space.description.trim(),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Align(
                          alignment: Alignment.topRight,
                          child: isOwner
                              ? PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert),
                                  tooltip: 'Space actions',
                                  splashRadius: 18,
                                  onSelected: (action) {
                                    if (action == 'edit') {
                                      if (widget.onEdit != null) {
                                        widget.onEdit!();
                                      } else {
                                        _editSpaceDialog();
                                      }
                                    } else if (action == 'archive') {
                                      widget.onArchive();
                                    } else if (action == 'delete') {
                                      widget.onDelete();
                                    }
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Row(
                                        children: [
                                          Icon(Icons.edit_outlined, size: 18),
                                          SizedBox(width: 8),
                                          Text('Edit'),
                                        ],
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'archive',
                                      child: Row(
                                        children: [
                                          Icon(Icons.archive_outlined,
                                              size: 18),
                                          SizedBox(width: 8),
                                          Text('Archive'),
                                        ],
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Row(
                                        children: [
                                          Icon(Icons.delete_outline,
                                              size: 18,
                                              color: ConclaveColors.error),
                                          SizedBox(width: 8),
                                          Text('Delete',
                                              style: TextStyle(
                                                  color: ConclaveColors.error)),
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                        if (widget.space.instructions.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 62),
                            child: Column(
                              children: [
                                Text(
                                  'Space Instructions',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(widget.space.instructions.trim(),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Space resource tabs share session caches.
                  AnimatedBuilder(
                    animation: _tabController,
                    builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: TabBar(
                            controller: _tabController,
                            isScrollable: true,
                            tabAlignment: TabAlignment.center,
                            tabs: const [
                              Tab(text: 'Threads'),
                              Tab(text: 'Workspaces'),
                              Tab(text: 'Members'),
                              Tab(text: 'Workflows'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_tabController.index == 0)
                          _threadsTab()
                        else if (_tabController.index == 1)
                          _workspacesTab()
                        else if (_tabController.index == 2)
                          _membersTab()
                        else
                          WorkflowsPage(
                              catalogs: AxSessionCatalogs.forSource(
                                  widget.dataSource),
                              configurations: _workflowConfigurations,
                              canEdit: widget.space.role == 'owner'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

part of '../projects_pages.dart';

class ProjectPage extends StatelessWidget {
  const ProjectPage({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onOpenWorkstream,
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
    this.projectWorkstreams,
    this.workspaceGrants,
    this.tabQueries,
    this.mutations,
  });

  final AxProject project;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxProject>? onProjectUpdated;
  final AxProjectWorkstreams? projectWorkstreams;
  final AxProjectWorkspaceGrants? workspaceGrants;
  final AxProjectTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;

  @override
  Widget build(BuildContext context) => _ProjectWorkspace(
        key: ValueKey(project.id),
        project: project,
        dataSource: dataSource,
        onOpenWorkstream: onOpenWorkstream,
        onOpenWorkspace: onOpenWorkspace,
        onEdit: onEdit,
        onArchive: onArchive,
        onDelete: onDelete,
        onProjectUpdated: onProjectUpdated,
        projectWorkstreams: projectWorkstreams,
        workspaceGrants: workspaceGrants,
        tabQueries: tabQueries,
        mutations: mutations,
      );
}

class _ProjectWorkspace extends StatefulWidget {
  const _ProjectWorkspace({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onOpenWorkstream,
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
    this.projectWorkstreams,
    this.workspaceGrants,
    this.tabQueries,
    this.mutations,
  });

  final AxProject project;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxProject>? onProjectUpdated;
  final AxProjectWorkstreams? projectWorkstreams;
  final AxProjectWorkspaceGrants? workspaceGrants;
  final AxProjectTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;

  @override
  State<_ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<_ProjectWorkspace>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<AxWorkstream> workstreams;
  List<AxProjectMember> members = const [];
  List<AxProjectInvitation> invitations = const [];
  List<AxWorkspace> ownedWorkspaces = const [];
  List<Map<String, dynamic>> projectWorkspaces = const [];
  bool workstreamsLoading = true;
  bool membersLoading = true;
  Object? workstreamsError;
  Object? membersError;
  late AxProjectTabQueries _queries;
  late AxProjectWorkstreams _streams;
  late AxCollaborationMutations _collaboration;
  final _tabCancels = <void Function()>[];
  int _activeTab = -1;
  bool executionLoading = true;
  Object? executionError;
  late AxProjectWorkspaceGrants _grants;
  bool _savingField = false;
  String? _editingField;

  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _instructionsController;

  bool get canManage =>
      widget.project.role == 'owner' || widget.project.role == 'collaborator';
  bool get isOwner => widget.project.role == 'owner';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _nameController = TextEditingController(text: widget.project.name);
    _descriptionController =
        TextEditingController(text: widget.project.description);
    _instructionsController =
        TextEditingController(text: widget.project.instructions);
    _configureQueries();
    _tabController.addListener(_onTabChanged);
    _onTabChanged();
  }

  void _configureQueries() {
    _queries =
        widget.tabQueries ?? AxProjectTabQueries.forSource(widget.dataSource);
    _streams = widget.projectWorkstreams ?? _queries.workstreams;
    _collaboration = widget.mutations ??
        AxCollaborationMutations(widget.dataSource, engine: _streams.engine);
    _grants = widget.workspaceGrants ??
        AxProjectWorkspaceGrants.forSource(widget.dataSource);
    workstreams = _streams.peek(widget.project.id);
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
    final id = widget.project.id;
    if (_activeTab == 0) {
      final query = _streams.query(id);
      void apply(AxQueryState<List<AxWorkstream>> state) {
        workstreams = state.data ?? const [];
        workstreamsLoading = !state.hasData && state.isFetching;
        workstreamsError = state.error;
      }

      apply(_streams.engine.peek(query));
      _tabCancels.add(_streams.engine.watch(query, (state) {
        if (mounted) _updateState(() => apply(state));
      }, fireImmediately: false));
      _ensure(_streams.engine, query);
    } else if (_activeTab == 1) {
      void apply(AxQueryState<AxWorkspaceGrants> state) {
        projectWorkspaces = state.data ?? const [];
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
    } else {
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

  void _recordWorkstreams() {
    _streams.engine.update(_streams.query(widget.project.id),
        (_) => List.unmodifiable(workstreams));
    _queries.engine.invalidate(_queries.audit(widget.project.id).key);
  }

  @override
  void didUpdateWidget(_ProjectWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id ||
        oldWidget.project.name != widget.project.name ||
        oldWidget.project.description != widget.project.description ||
        oldWidget.project.instructions != widget.project.instructions) {
      if (_editingField == null) {
        _nameController.text = widget.project.name;
        _descriptionController.text = widget.project.description;
        _instructionsController.text = widget.project.instructions;
      }
    }
    if (oldWidget.project.id != widget.project.id ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.projectWorkstreams != widget.projectWorkstreams ||
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
    _nameController.dispose();
    _descriptionController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  void _updateState(VoidCallback callback) => setState(callback);

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Project Data directly without group control card or horizontal lines
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Line 1: Project Name
                _buildEditableField(
                  label: 'Project Name',
                  fieldKey: 'name',
                  value: widget.project.name,
                  placeholder: 'Untitled Project',
                  controller: _nameController,
                  textStyle: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                // Line 2: Description
                _buildEditableField(
                  label: 'Description',
                  fieldKey: 'description',
                  value: widget.project.description,
                  placeholder: 'No project description provided.',
                  controller: _descriptionController,
                  maxLines: 2,
                ),
                if (isOwner ||
                    widget.project.instructions.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  // Project instructions
                  _buildEditableField(
                    label: 'Project Instructions',
                    fieldKey: 'instructions',
                    value: widget.project.instructions,
                    placeholder: 'No instructions configured.',
                    controller: _instructionsController,
                    maxLines: 3,
                  ),
                ],
                if (isOwner) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: widget.onArchive,
                        icon: const Icon(Icons.archive_outlined),
                        label: const Text('Archive'),
                      ),
                      TextButton.icon(
                        onPressed: widget.onDelete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                        style: TextButton.styleFrom(
                            foregroundColor: ConclaveColors.error),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // 3 Tabs: Workstreams, Workspaces, Members aligned by center
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
                      Tab(text: 'Workstreams'),
                      Tab(text: 'Workspaces'),
                      Tab(text: 'Members'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_tabController.index == 0)
                  _workstreamsTab()
                else if (_tabController.index == 1)
                  _workspacesTab()
                else
                  _membersTab(),
              ],
            ),
          ),
        ],
      );
}

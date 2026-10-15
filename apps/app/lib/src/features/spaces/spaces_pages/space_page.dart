part of '../spaces_pages.dart';

enum SpacePageSection { threads, members }

class SpacePage extends StatelessWidget {
  const SpacePage({
    super.key,
    required this.space,
    required this.dataSource,
    required this.onOpenThread,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onSpaceUpdated,
    this.section = SpacePageSection.threads,
    this.spaceThreads,
    this.tabQueries,
    this.mutations,
    this.viewerEmail,
  });

  final AxSpace space;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenThread;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxSpace>? onSpaceUpdated;
  final SpacePageSection section;
  final AxSpaceThreads? spaceThreads;
  final AxSpaceTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;
  final String? viewerEmail;

  @override
  Widget build(BuildContext context) => _SpaceWorkspace(
        key: ValueKey(space.id),
        space: space,
        dataSource: dataSource,
        onOpenThread: onOpenThread,
        onEdit: onEdit,
        onArchive: onArchive,
        onDelete: onDelete,
        onSpaceUpdated: onSpaceUpdated,
        section: section,
        spaceThreads: spaceThreads,
        tabQueries: tabQueries,
        mutations: mutations,
        viewerEmail: viewerEmail,
      );
}

class _SpaceWorkspace extends StatefulWidget {
  const _SpaceWorkspace({
    super.key,
    required this.space,
    required this.dataSource,
    required this.onOpenThread,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onSpaceUpdated,
    this.section = SpacePageSection.threads,
    this.spaceThreads,
    this.tabQueries,
    this.mutations,
    this.viewerEmail,
  });

  final AxSpace space;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenThread;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxSpace>? onSpaceUpdated;
  final SpacePageSection section;
  final AxSpaceThreads? spaceThreads;
  final AxSpaceTabQueries? tabQueries;
  final AxCollaborationMutations? mutations;
  final String? viewerEmail;

  @override
  State<_SpaceWorkspace> createState() => _SpaceWorkspaceState();
}

class _SpaceWorkspaceState extends State<_SpaceWorkspace> {
  late List<AxThread> threads;
  List<AxSpaceMember> members = const [];
  List<AxSpaceInvitation> invitations = const [];
  bool threadsLoading = true;
  bool membersLoading = true;
  Object? threadsError;
  Object? membersError;
  late AxSpaceTabQueries _queries;
  late AxPeople _people;
  late AxSpaceThreads _streams;
  late AxCollaborationMutations _collaboration;
  final _tabCancels = <void Function()>[];
  bool get canManage => widget.space.effectivePermissions.manageOwnThreads;
  bool get canInvite => widget.space.role == 'owner';
  final _savingMembers = <String>{};
  bool get isOwner => widget.space.role == 'owner';

  @override
  void initState() {
    super.initState();
    _configureQueries();
    _bindActiveSection();
  }

  void _configureQueries() {
    _queries =
        widget.tabQueries ?? AxSpaceTabQueries.forSource(widget.dataSource);
    _streams = widget.spaceThreads ?? _queries.threads;
    _collaboration = widget.mutations ??
        AxCollaborationMutations(widget.dataSource, engine: _streams.engine);
    _people = AxPeople(widget.dataSource, engine: _streams.engine);
    if (widget.dataSource is AxPeopleDataSource) {
      unawaited(_people
          .ensure()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }
    threads = _streams.peek(widget.space.id);
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

  void _bindActiveSection() {
    _cancelTab();
    final id = widget.space.id;
    if (widget.section == SpacePageSection.threads) {
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
    } else if (widget.section == SpacePageSection.members) {
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

  @override
  void didUpdateWidget(_SpaceWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space.id != widget.space.id ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.spaceThreads != widget.spaceThreads ||
        oldWidget.tabQueries != widget.tabQueries ||
        oldWidget.mutations != widget.mutations ||
        oldWidget.section != widget.section) {
      _cancelTab();
      _configureQueries();
      _bindActiveSection();
    }
  }

  @override
  void dispose() {
    _cancelTab();
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Stack(
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
                                    const SizedBox(height: 12),
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
                                              Icon(Icons.edit_outlined,
                                                  size: 18),
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
                                                      color: ConclaveColors
                                                          .error)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (widget.section == SpacePageSection.members)
                    _membersTab()
                  else
                    _threadsTab(),
                ],
              ),
            ),
          ),
        ),
      );
}

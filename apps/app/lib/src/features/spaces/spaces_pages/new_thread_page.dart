part of '../spaces_pages.dart';

/// Space landing surface with explicit, Space-unique Thread creation.
class NewThreadPage extends StatefulWidget {
  const NewThreadPage({
    super.key,
    required this.space,
    required this.dataSource,
    required this.createThread,
    required this.onOpenThread,
    required this.discussionCache,
    required this.workHistoryCache,
    required this.threadViewStateStore,
    this.catalogs,
    this.workflowConfigurations,
    this.currentUserId,
    this.currentUserName,
    this.viewerEmail,
  });

  final AxSpace space;
  final AxDataSource dataSource;
  final Future<AxThread> Function(String name) createThread;
  final ValueChanged<AxThread> onOpenThread;
  final AxDiscussionCache discussionCache;
  final AxWorkHistoryCache workHistoryCache;
  final AxThreadViewStateStore threadViewStateStore;
  final AxSessionCatalogs? catalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? currentUserId;
  final String? currentUserName;
  final String? viewerEmail;

  @override
  State<NewThreadPage> createState() => _NewThreadPageState();
}

class _NewThreadPageState extends State<NewThreadPage> {
  final _nameController = TextEditingController();
  late final _threads =
      AxSpaceThreads(widget.dataSource, engine: widget.workHistoryCache.engine);
  late final AxWorkflowConfigurations? _workflows =
      widget.workflowConfigurations ??
          (widget.dataSource is AxWorkflowWorkspaceDataSource
              ? AxWorkflowConfigurations(widget.dataSource,
                  engine: widget.workHistoryCache.engine,
                  spaceId: widget.space.id)
              : null);
  bool _busy = false;
  bool _membersExpanded = false;
  String? _creationError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool _duplicate(List<AxThread> threads) {
    final name = _nameController.text.trim().toLowerCase();
    return name.isNotEmpty &&
        threads.any((thread) => thread.name.trim().toLowerCase() == name);
  }

  Future<void> _createNamedThread() async {
    if (_busy ||
        _nameController.text.trim().isEmpty ||
        !widget.space.effectivePermissions.manageOwnThreads) {
      return;
    }
    setState(() {
      _busy = true;
      _creationError = null;
    });
    try {
      final threads = await _threads.ensure(widget.space.id);
      if (!mounted) return;
      if (_duplicate(threads)) {
        setState(() => _creationError =
            'A Thread with this name already exists in this Space.');
        return;
      }
      final thread = await widget.createThread(_nameController.text.trim());
      if (thread.id.isEmpty ||
          thread.id.startsWith('local-') ||
          thread.spaceId != widget.space.id) {
        throw StateError('Thread creation returned an invalid identity.');
      }
      if (mounted) widget.onOpenThread(thread);
    } catch (error) {
      if (mounted) setState(() => _creationError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 20, 0, 12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.space.name.trim().isNotEmpty) ...[
                          Text(widget.space.name.trim(),
                              key: const ValueKey('space-landing-name'),
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 12),
                        ],
                        if (widget.space.description.trim().isNotEmpty) ...[
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 140),
                            child: SingleChildScrollView(
                                child: Text(widget.space.description)),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_workflows != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _SpaceWorkspaceSelector(
                                configurations: _workflows!,
                                isOwner: widget.space.role == 'owner'),
                          ),
                        const SizedBox(height: 20),
                        Align(
                          alignment: Alignment.centerLeft,
                          child:
                              SizedBox(width: 360, child: _threadNameField()),
                        ),
                      ]),
                ),
              ))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                shape: const Border(),
                collapsedShape: const Border(),
                showTrailingIcon: false,
                onExpansionChanged: (expanded) =>
                    setState(() => _membersExpanded = expanded),
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Members',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _membersExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more,
                          key: ValueKey('space-members-arrow'), size: 20),
                    ),
                  ],
                ),
                children: [
                  SpacePage(
                    embedded: true,
                    workflowConfigurations: widget.workflowConfigurations,
                    section: SpacePageSection.members,
                    space: widget.space,
                    dataSource: widget.dataSource,
                    viewerEmail: widget.viewerEmail,
                    onOpenThread: (_) {},
                    onArchive: () {},
                    onDelete: () {},
                  )
                ],
              ),
            )),
          ),
        ],
      ));

  Widget _threadNameField() => AxQueryBuilder<List<AxThread>>(
        engine: _threads.engine,
        query: _threads.query(widget.space.id),
        builder: (context, state) {
          final duplicate = _duplicate(state.data ?? const []);
          return TextField(
            key: const ValueKey('new-thread-name'),
            controller: _nameController,
            enabled:
                !_busy && widget.space.effectivePermissions.manageOwnThreads,
            maxLength: 22,
            onChanged: (_) => setState(() => _creationError = null),
            decoration: InputDecoration(
              labelText: 'Create a new thread',
              hintText: 'Enter a unique name',
              counterText: '',
              errorText: duplicate
                  ? 'A Thread with this name already exists in this Space.'
                  : _creationError,
              suffixIcon: TextButton(
                style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.onSurface),
                onPressed: !_busy &&
                        !duplicate &&
                        _nameController.text.trim().isNotEmpty &&
                        widget.space.effectivePermissions.manageOwnThreads
                    ? _createNamedThread
                    : null,
                child: const Text('Create Thread'),
              ),
            ),
            onSubmitted: (_) => _createNamedThread(),
          );
        },
      );
}

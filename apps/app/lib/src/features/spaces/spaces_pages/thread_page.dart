part of '../spaces_pages.dart';

class ThreadPage extends StatefulWidget {
  const ThreadPage({
    super.key,
    required this.space,
    required this.thread,
    this.dataSource,
    this.discussionCache,
    this.workHistoryCache,
    this.catalogs,
    this.workflowConfigurations,
    this.currentUserId,
    this.currentUserName,
    required this.onBackToSpace,
    required this.onArchive,
    this.onRename,
    this.onRunWork,
    this.realtimeEvents,
    this.initialTab = 0,
  });

  final AxSpace space;
  final AxThread thread;
  final AxDataSource? dataSource;
  final AxDiscussionCache? discussionCache;
  final AxWorkHistoryCache? workHistoryCache;
  final AxSessionCatalogs? catalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? currentUserId;
  final String? currentUserName;
  final VoidCallback onBackToSpace;
  final VoidCallback onArchive;
  final Future<void> Function(String name)? onRename;
  final Future<String> Function(String prompt, String workflowId,
      List<Map<String, dynamic>> attachments, String idempotencyKey)? onRunWork;
  final Stream<Map<String, dynamic>>? realtimeEvents;
  final int initialTab;

  // Compatibility getters

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _requestController = TextEditingController();
  final _workHistoryController = ScrollController();
  final _chatHistoryController = ScrollController();
  bool _followWork = true;
  bool _followChat = true;
  bool _loadingOlderChat = false;
  final _chatComposerKey = GlobalKey();
  final _workComposerKey = GlobalKey();
  final _chatComposerSpaceChanges = ValueNotifier<double>(48);
  double get _chatComposerSpace => _chatComposerSpaceChanges.value;

  void _alignComposers() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final chat =
          _chatComposerKey.currentContext?.findRenderObject() as RenderBox?;
      final work =
          _workComposerKey.currentContext?.findRenderObject() as RenderBox?;
      if (chat == null || work == null || !chat.hasSize || !work.hasSize) {
        return;
      }
      final space = (_chatComposerSpace + work.size.height - chat.size.height)
          .clamp(0.0, 500.0);
      if ((space - _chatComposerSpace).abs() > 0.5) {
        _chatComposerSpaceChanges.value = space;
      }
    });
  }

  bool get _awaitingWorkResponse =>
      _submittingWork ||
      _workTimeline.any((request) =>
          !const {'completed', 'failed', 'cancelled'}.contains(request.status));

  void _followLatest(ScrollController controller, bool follow) {
    if (!follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final stillFollowing =
          controller == _workHistoryController ? _followWork : _followChat;
      if (stillFollowing) {
        controller.jumpTo(controller.position.maxScrollExtent);
      }
    });
  }

  final _discussionController = TextEditingController();
  late AxSessionCatalogs _catalogs;
  void Function()? _cancelWorkflowWorkspace;
  void Function()? _cancelWorkflows;
  void Function()? _cancelWorkers;
  String? _selectedWorkflowWorkspaceId;
  int _choicesGeneration = 0;
  String _workflow = '';
  List<AxBuiltinWorkflow> _workflowCatalog = const [];
  List<AxBuiltinWorkflow> get _currentWorkflows =>
      _currentWorkflowVersions(_availableWorkflows);
  List<AxBuiltinWorkflow> get _availableWorkflows => _workflowCatalog
      .where((workflow) => workflow.id == 'chat'
          ? widget.space.effectivePermissions.chat
          : widget.space.effectivePermissions.work)
      .toList();
  String get _effectiveWorkflow =>
      _availableWorkflows.any((item) => item.reference == _workflow)
          ? _workflow
          : _availableWorkflows.firstOrNull?.reference ?? '';
  bool _loadingWorkflows = true;
  String? _workflowCatalogError;
  late AxDiscussionCache _fallbackDiscussionCache;
  AxDiscussionCache get _discussionCache =>
      widget.discussionCache ?? _fallbackDiscussionCache;
  late AxWorkHistoryCache _fallbackWorkHistoryCache;
  AxWorkHistoryCache get _workHistoryCache =>
      widget.workHistoryCache ?? _fallbackWorkHistoryCache;
  void Function()? _cancelWorkHistory;
  bool _loadingOlderWork = false;
  List<AxWorkRequest> get _workTimeline =>
      _workHistoryCache.peek(widget.thread.id).requests;
  void _subscribeWorkHistory() {
    _cancelWorkHistory?.call();
    _cancelWorkHistory = _workHistoryCache.watch(widget.thread.id, () {
      if (!mounted) return;
      _updateWorkHistory(() {});
      _workComposerChanges.value++;
    });
  }

  Map<String, String> get _localWorkProgress =>
      _workHistoryCache.localProgress(widget.thread.id);
  bool get _loadingWorkTimeline =>
      !_workHistoryCache.peek(widget.thread.id).initialLoaded &&
      _workHistoryCache.loading(widget.thread.id);
  String? get _workTimelineError =>
      _workHistoryCache.error(widget.thread.id)?.toString();
  String? _workSubmitError;
  StreamSubscription<Map<String, dynamic>>? _workEventSubscription;
  void Function()? _cancelWorkRealtime;
  bool get _submittingWork => _workHistoryCache.submitting(widget.thread.id);
  List<Map<String, dynamic>> _workAttachments = [];
  List<AxWorker> _spaceWorkers = const [];
  List<AxWorker> _eligibleWorkers = const [];
  AxWorkflowConfigurations? _workflowConfigurations;
  void Function()? _cancelWorkflowConfigurations;
  List<AxUserWorkflowConfiguration> _userWorkflowConfigurations = const [];
  Map<String, dynamic> get _composerWorkConfig {
    final id = _effectiveWorkflow.split(':').first;
    final definition = _availableWorkflows
        .where((workflow) => workflow.reference == _effectiveWorkflow)
        .firstOrNull;
    final configuration = _userWorkflowConfigurations
        .where((value) => value.workflowId == id)
        .firstOrNull;
    return {
      'bindings': {
        for (final step in definition?.steps ?? const <AxBuiltinWorkflowStep>[])
          (id == 'direct' ? 'direct' : step.kind): {
            if (configuration?.selectionFor(step.kind).worker != null)
              'workerId': configuration!.selectionFor(step.kind).worker,
            if (configuration?.selectionFor(step.kind).model != null)
              'model': configuration!.selectionFor(step.kind).model,
            if (configuration?.selectionFor(step.kind).effort != null)
              'reasoningEffort': configuration!.selectionFor(step.kind).effort,
          }
      }
    };
  }

  void _subscribeWorkflowConfigurations() {
    final ds = widget.dataSource;
    _workflowConfigurations =
        widget.workflowConfigurations?.spaceId == widget.space.id
            ? widget.workflowConfigurations
            : ds is AxSpaceWorkflowConfigurationDataSource
                ? AxWorkflowConfigurations(ds!,
                    engine: _workHistoryCache.engine, spaceId: widget.space.id)
                : null;
    final cache = _workflowConfigurations;
    if (cache == null) return;
    _cancelWorkflowConfigurations = cache.engine.watch(cache.query, (state) {
      if (!mounted) return;
      _updateComposerState(
          () => _userWorkflowConfigurations = state.data ?? const []);
    });
    unawaited(cache
        .ensure()
        .catchError((Object error) => <AxUserWorkflowConfiguration>[]));
  }

  final _workComposerChanges = ValueNotifier<int>(0);
  final _workHistoryChanges = ValueNotifier<int>(0);
  void _updateWorkHistory(VoidCallback callback) {
    callback();
    _workHistoryChanges.value++;
  }

  @override
  void initState() {
    super.initState();
    _fallbackDiscussionCache = widget.discussionCache ??
        AxDiscussionCache.forSource(widget.dataSource);
    _fallbackWorkHistoryCache = widget.workHistoryCache ??
        AxWorkHistoryCache.forSource(widget.dataSource);
    _subscribeWorkHistory();
    _workHistoryController.addListener(() {
      if (_workHistoryController.position.userScrollDirection !=
          ScrollDirection.idle) {
        _followWork = _workHistoryController.position.extentAfter <= 24;
        if (_workHistoryController.position.userScrollDirection ==
                ScrollDirection.forward &&
            _workHistoryController.position.extentBefore <= 24 &&
            _workHistoryCache.peek(widget.thread.id).olderCursor != null &&
            !_workHistoryCache.loadingOlder(widget.thread.id) &&
            _workHistoryCache.error(widget.thread.id) == null) {
          unawaited(_loadOlderWorkHistory());
        }
      }
    });
    _chatHistoryController.addListener(() {
      if (_chatHistoryController.position.userScrollDirection !=
          ScrollDirection.idle) {
        _followChat = _chatHistoryController.position.extentAfter <= 24;
        if (_chatHistoryController.position.userScrollDirection ==
                ScrollDirection.forward &&
            _chatHistoryController.position.extentBefore <= 24) {
          final state = _discussionCache.peek(widget.thread.id);
          if (state.olderCursor != null &&
              !state.loadingOlder &&
              state.error == null) {
            unawaited(_loadOlderDiscussion());
          }
        }
      }
    });
    _tabController = TabController(
      length: 2,
      initialIndex: widget.initialTab == 2 ? 1 : widget.initialTab.clamp(0, 1),
      vsync: this,
    );
    _refreshWorkTimeline();
    _requestController.addListener(_alignComposers);
    _discussionController.addListener(_alignComposers);
    _subscribeToWorkEvents();
    _subscribeWorkflowConfigurations();
    _subscribeCatalogs();
    _subscribeWorkflowWorkspace();
    _loadWorkChoices();
    _loadWorkflowCatalog();
  }

  void _applyWorkers(List<AxWorker> workers) {
    _spaceWorkers = workers
        .where((worker) => worker.workspaceId == _selectedWorkflowWorkspaceId)
        .toList();
    _eligibleWorkers = _spaceWorkers
        .where((worker) =>
            worker.activationState == 'enabled' &&
            worker.readinessState == 'ready' &&
            worker.catalogLifecycleState == 'active' &&
            worker.catalogVisibilityState == 'visible')
        .toList();
  }

  void _subscribeCatalogs() {
    _cancelWorkflows?.call();
    _cancelWorkers?.call();
    _catalogs =
        widget.catalogs ?? AxSessionCatalogs.forSource(widget.dataSource);
    final workflows = _catalogs.engine.peek(_catalogs.workflows);
    _workflowCatalog = workflows.data ?? const [];
    _loadingWorkflows = !workflows.hasData;
    if (_workflowCatalog.isNotEmpty) {
      _workflow = _threadDefaultReference(_workflowCatalog);
    }
    _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
    _cancelWorkflows = _catalogs.engine.watch(_catalogs.workflows, (state) {
      if (!mounted) return;
      _updateComposerState(() {
        if (state.hasData) {
          _workflowCatalog = state.data!;
          if (!_workflowCatalog.any((item) => item.reference == _workflow)) {
            _workflow = _threadDefaultReference(_workflowCatalog);
          }
        }
        _loadingWorkflows = !state.hasData && state.isFetching;
        _workflowCatalogError = state.error != null
            ? 'Could not load the Workflow catalog.'
            : state.hasData && state.data!.isEmpty
                ? 'No built-in Workflows are available.'
                : null;
      });
    }, fireImmediately: false);
    _cancelWorkers = _catalogs.engine.watch(_catalogs.workers, (state) {
      if (!mounted) return;
      if (state.hasData) {
        _updateComposerState(() => _applyWorkers(state.data!));
      }
    }, fireImmediately: false);
  }

  Future<void> _loadWorkflowCatalog() async {
    final ds = widget.dataSource;
    final catalogs = _catalogs;
    if (ds == null) {
      _updateState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Workflow catalog is unavailable.';
      });
      return;
    }
    try {
      await catalogs.ensureWorkflows();
      if (!mounted || catalogs != _catalogs) return;
      final workflows = catalogs.engine.peek(catalogs.workflows).data ??
          const <AxBuiltinWorkflow>[];
      _updateState(() {
        _workflowCatalog = workflows;
        _loadingWorkflows = false;
        _workflowCatalogError =
            workflows.isEmpty ? 'No built-in Workflows are available.' : null;
        _workflow = workflows.isEmpty ? '' : _threadDefaultReference(workflows);
      });
    } catch (_) {
      if (!mounted || catalogs != _catalogs) return;
      _updateState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Could not load the Workflow catalog.';
      });
    }
  }

  String _threadDefaultReference(List<AxBuiltinWorkflow> workflows) {
    if (workflows.isEmpty) return '';
    final current = _currentWorkflowVersions(workflows);
    // The Work composer needs a stable default after thread-level execution
    // settings are removed. Prefer the general-purpose work workflow when the
    // catalog exposes it, then fall back to the catalog's first current entry.
    for (final preferred in ['direct', 'work']) {
      final match = current.where((item) => item.id == preferred).firstOrNull;
      if (match != null) return match.reference;
    }
    return current.firstOrNull?.reference ?? '';
  }

  void _subscribeWorkflowWorkspace() {
    _cancelWorkflowWorkspace?.call();
    final cache = _workflowConfigurations;
    if (cache == null) {
      _selectedWorkflowWorkspaceId = null;
      _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
      return;
    }
    final state = cache.engine.peek(cache.workspaceQuery);
    _selectedWorkflowWorkspaceId = state.data?.workspaceId;
    _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
    _cancelWorkflowWorkspace =
        cache.engine.watch(cache.workspaceQuery, (state) {
      if (!mounted) return;
      _updateState(() {
        _selectedWorkflowWorkspaceId = state.data?.workspaceId;
        _applyWorkers(
            _catalogs.engine.peek(_catalogs.workers).data ?? const []);
      });
    });
  }

  Future<void> _loadWorkChoices() async {
    final ds = widget.dataSource;
    final generation = ++_choicesGeneration;
    final catalogs = _catalogs;
    final spaceId = widget.space.id;
    if (ds == null) {
      return;
    }
    try {
      await Future.wait([
        catalogs.ensureWorkers(),
        _workflowConfigurations?.ensureWorkspace() ?? Future.value(null),
      ]);
      if (!mounted) return;
      if (generation != _choicesGeneration || catalogs != _catalogs) return;
      if (spaceId != widget.space.id) return;
      _updateState(() {
        _selectedWorkflowWorkspaceId = _workflowConfigurations?.engine
            .peek(_workflowConfigurations!.workspaceQuery)
            .data
            ?.workspaceId;
        _applyWorkers(catalogs.engine.peek(catalogs.workers).data ?? const []);
      });
    } catch (_) {
      // The shared queries retain their last valid data on refresh failure.
    }
  }

  @override
  void didUpdateWidget(ThreadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workflowConfigurations != widget.workflowConfigurations ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.space.id != widget.space.id) {
      _cancelWorkflowConfigurations?.call();
      _subscribeWorkflowConfigurations();
    }
    if (oldWidget.catalogs != widget.catalogs ||
        oldWidget.dataSource != widget.dataSource) {
      _subscribeCatalogs();
      unawaited(_loadWorkflowCatalog());
    }
    if (oldWidget.catalogs != widget.catalogs ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.space.id != widget.space.id) {
      _subscribeWorkflowWorkspace();
      unawaited(_loadWorkChoices());
    }
    if (oldWidget.dataSource != widget.dataSource ||
        oldWidget.discussionCache != widget.discussionCache) {
      _fallbackDiscussionCache = widget.discussionCache ??
          AxDiscussionCache.forSource(widget.dataSource);
    }
    if (oldWidget.workHistoryCache != widget.workHistoryCache ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.thread.id != widget.thread.id) {
      _cancelWorkRealtime?.call();
      _fallbackWorkHistoryCache = widget.workHistoryCache ??
          AxWorkHistoryCache.forSource(widget.dataSource);
      _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
          .listen(widget.realtimeEvents, threadId: widget.thread.id);
      _subscribeWorkHistory();
      unawaited(_refreshWorkTimeline());
    }
    if (oldWidget.thread.id != widget.thread.id) {
      _discussionController.clear();
      _followWork = _followChat = true;
    }
    if (oldWidget.initialTab != widget.initialTab) {
      final targetIndex =
          widget.initialTab == 2 ? 1 : widget.initialTab.clamp(0, 1);
      _tabController.animateTo(targetIndex);
    }
    if (oldWidget.realtimeEvents != widget.realtimeEvents) {
      _workEventSubscription?.cancel();
      _subscribeToWorkEvents();
    }
  }

  void _subscribeToWorkEvents() {
    _cancelWorkRealtime?.call();
    _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
        .listen(widget.realtimeEvents, threadId: widget.thread.id);
    _workEventSubscription = widget.realtimeEvents?.listen((event) {
      final type = event['type'];
      final payload = event['payload'];
      if ((type is String &&
          (type.startsWith('thread.discussion.') ||
              type.startsWith('thread.discussion.')) &&
          ((payload is Map &&
                  (payload['threadId'] == widget.thread.id ||
                      payload['threadId'] == widget.thread.id)) ||
              event['threadId'] == widget.thread.id ||
              event['threadId'] == widget.thread.id))) {
        unawaited(_discussionCache
            .synchronize(widget.thread.id, reconcileNewest: true)
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      }
    });
  }

  bool get _canExecute =>
      (widget.space.role == 'owner' || widget.thread.canExecuteWork) &&
      _effectiveWorkflow.isNotEmpty;
  @override
  void dispose() {
    _cancelWorkflowConfigurations?.call();
    _cancelWorkflows?.call();
    _cancelWorkers?.call();
    _cancelWorkflowWorkspace?.call();
    _cancelWorkHistory?.call();
    _cancelWorkRealtime?.call();
    _workEventSubscription?.cancel();
    _tabController.dispose();
    _requestController.removeListener(_alignComposers);
    _discussionController.removeListener(_alignComposers);
    _requestController.dispose();
    _workHistoryController.dispose();
    _chatHistoryController.dispose();
    _discussionController.dispose();
    _workComposerChanges.dispose();
    _workHistoryChanges.dispose();
    _chatComposerSpaceChanges.dispose();
    super.dispose();
  }

  void _updateComposerState(VoidCallback callback) {
    callback();
    _workComposerChanges.value++;
  }

  void _updateState(VoidCallback callback) {
    callback();
    _workHistoryChanges.value++;
    _workComposerChanges.value++;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _tabController,
        builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
          Widget tabHeader(List<String> names, {TabController? controller}) =>
              DefaultTabController(
                length: names.length,
                child: Column(children: [
                  Center(
                      child: TabBar(
                    controller: controller,
                    isScrollable: true,
                    tabAlignment: TabAlignment.center,
                    dividerHeight: 0,
                    tabs: names.map((name) => Tab(text: name)).toList(),
                  )),
                  const Divider(height: 1, thickness: 1),
                  const SizedBox(height: 16),
                ]),
              );
          Widget pane(String name, Widget content) => Padding(
              key: ValueKey('thread-$name-padding'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                key: ValueKey('thread-$name-pane'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  tabHeader([name]),
                  Expanded(child: content),
                ],
              ));
          if (constraints.maxWidth >= 1000) {
            _alignComposers();
            return Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1681),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                        child: pane(
                            'Chat', _discuss(context, alignWithWork: true))),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      indent: 20,
                      endIndent: 20,
                      color: Theme.of(context).dividerColor,
                    ),
                    Expanded(child: pane('Work', _work(context))),
                  ]),
            ));
          }
          return Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
                key: const ValueKey('thread-tab-padding'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    tabHeader(['Chat', 'Work'], controller: _tabController),
                    Expanded(
                        child: _tabController.index == 0
                            ? _discuss(context)
                            : _work(context)),
                  ],
                )),
          ));
        }),
      );

  Widget _discuss(BuildContext context, {bool alignWithWork = false}) =>
      AxDiscussionBuilder(
          cache: _discussionCache,
          threadId: widget.thread.id,
          builder: (context, state) =>
              _discussionBody(context, state, alignWithWork: alignWithWork));

  Widget _discussionBody(BuildContext context, AxDiscussionState state,
      {bool alignWithWork = false}) {
    final messages = state.messages.map((message) {
      final isMe =
          widget.currentUserId != null && widget.currentUserId!.isNotEmpty
              ? message.authorUserId == widget.currentUserId
              : message.isMe;
      final date = DateTime.tryParse(message.createdAt)?.toLocal();
      final rawAuthor = isMe ? 'You' : (message.authorName?.trim() ?? '');
      final displayAuthor = (rawAuthor.isEmpty ||
              rawAuthor == message.authorUserId ||
              rawAuthor.startsWith('usr_'))
          ? (isMe ? 'You' : 'Member')
          : rawAuthor;
      return _DiscussionItem(
          id: message.id,
          author: displayAuthor,
          text: message.body,
          sentAt: date == null ? null : _chatTimestamp(date),
          isMe: isMe);
    }).toList();
    _followLatest(_chatHistoryController, _followChat);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
            child: SingleChildScrollView(
                key: const ValueKey('chat-history-scroll'),
                controller: _chatHistoryController,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (state.olderCursor != null)
                        TextButton(
                            onPressed: state.loadingOlder
                                ? null
                                : _loadOlderDiscussion,
                            child: Text(state.loadingOlder
                                ? 'Loading older messages…'
                                : 'Load older messages')),
                      if (state.error != null)
                        Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            child: Text.rich(TextSpan(
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: 13),
                                children: [
                                  TextSpan(
                                      text:
                                          'Chat could not synchronize: ${state.error}  '),
                                  WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Semantics(
                                          link: true,
                                          child: InkWell(
                                              onTap: () => _discussionCache
                                                  .synchronize(widget.thread.id)
                                                  .then<void>((_) {},
                                                      onError: (Object _,
                                                          StackTrace __) {}),
                                              child: Text('Retry Chat sync',
                                                  style: TextStyle(
                                                      fontSize: 13,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .error,
                                                      decoration: TextDecoration
                                                          .underline,
                                                      decorationColor:
                                                          Theme.of(context)
                                                              .colorScheme
                                                              .error))))),
                                  const TextSpan(text: ' '),
                                  WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: IconButton(
                                          tooltip: 'Copy Chat error',
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                              minWidth: 24, minHeight: 24),
                                          visualDensity: VisualDensity.compact,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                          icon: const Icon(Icons.copy_rounded,
                                              size: 14),
                                          onPressed: () => Clipboard.setData(
                                              ClipboardData(
                                                  text:
                                                      'Chat could not synchronize: ${state.error}')))),
                                ]))),
                      if (!state.hasData && state.isFetching)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Loading Chat…')),
                      if (messages.isEmpty &&
                          state.error == null &&
                          (!state.isFetching || state.hasData))
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              vertical: 40, horizontal: 16),
                          alignment: Alignment.center,
                          child: Column(
                            children: [
                              Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 42,
                                color: isDark ? Colors.white24 : Colors.black26,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No chat messages yet',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color:
                                      isDark ? Colors.white60 : Colors.black54,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Share context, decisions, or questions with your team below.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      isDark ? Colors.white38 : Colors.black38,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        ListView.separated(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: messages.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final message = messages[index];
                            return _DiscussionMessageBubble(
                              key: ValueKey(message.id),
                              item: message,
                              onCopy: () {
                                Clipboard.setData(
                                    ClipboardData(text: message.text));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content:
                                        Text('Message copied to clipboard'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                              onEdit: (newText) =>
                                  _editDiscussion(message.id, newText),
                              onDelete: () => _deleteDiscussion(message.id),
                            );
                          },
                        ),
                    ]))),
        const SizedBox(height: 16),
        MarkdownComposer(
          key: alignWithWork ? _chatComposerKey : null,
          controller: _discussionController,
          chatStyle: true,
          enabled: widget.space.effectivePermissions.chat,
          onSend: _sendDiscussion,
          additionalControlsBuilder: alignWithWork
              ? (_) => ValueListenableBuilder<double>(
                  valueListenable: _chatComposerSpaceChanges,
                  builder: (context, space, _) => SizedBox(height: space))
              : null,
        ),
      ],
    );
  }

  Widget _work(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
              child: ListenableBuilder(
                  listenable: _workHistoryChanges,
                  builder: (context, _) {
                    _followLatest(_workHistoryController, _followWork);
                    return _workComposer().history(context);
                  })),
          const SizedBox(height: 16),
          ListenableBuilder(
              listenable: _workComposerChanges,
              builder: (context, _) {
                _alignComposers();
                return _workComposer().controls(context);
              }),
        ],
      );

  _WorkComposer _workComposer() => _WorkComposer(
        composerKey: _workComposerKey,
        requestController: _requestController,
        historyController: _workHistoryController,
        currentUserId: widget.currentUserId,
        currentUserName: widget.currentUserName,
        workflow: _effectiveWorkflow,
        workflowCatalog: _availableWorkflows,
        workConfig: _composerWorkConfig,
        spaceWorkers: _spaceWorkers,
        eligibleWorkers: _eligibleWorkers,
        loadingWorkflows: _loadingWorkflows,
        workflowCatalogError: _workflowCatalogError,
        canExecute: _canExecute,
        workTimeline: _workTimeline,
        localWorkProgress: _localWorkProgress,
        loadingTimeline: _loadingWorkTimeline,
        timelineError: _workTimelineError,
        submitError: _workSubmitError,
        submitting: _submittingWork,
        awaitingResponse: _awaitingWorkResponse,
        attachments: _workAttachments,
        onAddFiles: _addWorkFiles,
        onAddReference: _addWorkReference,
        onRemoveAttachment: (index) => _updateState(() {
          _workAttachments.removeAt(index);
        }),
        onRefresh: _retryWorkSync,
        hasOlder: _workHistoryCache.peek(widget.thread.id).olderCursor != null,
        loadingOlder: _workHistoryCache.loadingOlder(widget.thread.id),
        onLoadOlder: _loadOlderWorkHistory,
        onShowRunDetails: widget.dataSource == null ? null : _showRunDetails,
        onRetryStep: widget.dataSource == null ? null : _retryWorkRequestStep,
        onCancelRun: widget.dataSource == null ? null : _cancelWorkRequest,
        onWorkflowChanged: (value) => _updateState(() => _workflow = value),
        onRun: _runWork,
      );
}

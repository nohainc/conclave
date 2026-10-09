part of '../spaces_pages.dart';

class ThreadPage extends StatefulWidget {
  const ThreadPage({
    super.key,
    required this.space,
    required this.thread,
    this.dataSource,
    this.discussionCache,
    this.workHistoryCache,
    this.threadViewStateStore,
    this.catalogs,
    this.workflowConfigurations,
    this.currentUserId,
    this.currentUserName,
    required this.onBackToSpace,
    required this.onArchive,
    this.onRename,
    this.onRunWork,
    this.onRunWorkWithSelection,
    this.realtimeEvents,
    this.initialTab = 0,
  });

  final AxSpace space;
  final AxThread thread;
  final AxDataSource? dataSource;
  final AxDiscussionCache? discussionCache;
  final AxWorkHistoryCache? workHistoryCache;
  final AxThreadViewStateStore? threadViewStateStore;
  final AxSessionCatalogs? catalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? currentUserId;
  final String? currentUserName;
  final VoidCallback onBackToSpace;
  final VoidCallback onArchive;
  final Future<void> Function(String name)? onRename;
  final Future<String> Function(String prompt, String workflowId,
      List<Map<String, dynamic>> attachments, String idempotencyKey)? onRunWork;
  final Future<String> Function(
      String prompt,
      String workflowId,
      List<Map<String, dynamic>> attachments,
      String idempotencyKey,
      Map<String, dynamic> executionSelection)? onRunWorkWithSelection;
  final Stream<Map<String, dynamic>>? realtimeEvents;
  final int initialTab;

  // Compatibility getters

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late final AxThreadViewStateStore _threadViewStateStore =
      widget.threadViewStateStore ?? MemoryAxThreadViewStateStore();
  Timer? _threadViewStateSaveTimer;
  int _threadViewStateGeneration = 0;
  bool _threadViewStateRestored = false;
  AxThreadViewState? _pendingThreadViewState;
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
  Map<String, dynamic> _workExecutionSelection = {};
  List<AxWorker> _spaceWorkers = const [];
  List<AxWorker> _eligibleWorkers = const [];
  AxWorkflowConfigurations? _workflowConfigurations;
  void Function()? _cancelWorkflowConfigurations;
  void Function()? _cancelWorkflowDefault;
  String? _workflowDefaultId;
  List<AxUserWorkflowConfiguration> _userWorkflowConfigurations = const [];

  void _scheduleThreadViewStateSave() {
    if (!_threadViewStateRestored || widget.currentUserId == null) return;
    _threadViewStateSaveTimer?.cancel();
    _threadViewStateSaveTimer = Timer(const Duration(milliseconds: 180), () {
      _threadViewStateSaveTimer = null;
      unawaited(_saveThreadViewState());
    });
  }

  String? _selectionValue(String key) {
    if (_workExecutionSelection.containsKey(key)) {
      final value = _workExecutionSelection[key];
      return value is String && value.isNotEmpty ? value : null;
    }
    final bindings = _composerWorkConfig['bindings'];
    if (bindings is! Map) return null;
    final definition = _availableWorkflows
        .where((item) => item.reference == _effectiveWorkflow)
        .firstOrNull;
    final stepKind = definition?.composerBindingId;
    final binding = stepKind == null ? null : bindings[stepKind];
    if (binding is! Map) return null;
    final value = binding[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  AxThreadViewState _currentThreadViewState() => AxThreadViewState(
        tabIndex: _tabController.index,
        workflowReference:
            _effectiveWorkflow.isEmpty ? null : _effectiveWorkflow,
        workerId: _selectionValue('workerId'),
        model: _selectionValue('model'),
        reasoningEffort: _selectionValue('reasoningEffort'),
        chatDraft: _discussionController.text,
        workDraft: _requestController.text,
      );

  Future<void> _saveThreadViewState() async {
    final userId = widget.currentUserId;
    if (!_threadViewStateRestored || userId == null || userId.isEmpty) return;
    await _threadViewStateStore.save(
      userId: userId,
      threadId: widget.thread.id,
      state: _currentThreadViewState(),
    );
  }

  void _reconcilePendingThreadViewState() {
    final saved = _pendingThreadViewState;
    if (saved == null || _availableWorkflows.isEmpty) return;
    if (saved.workerId != null &&
        !_catalogs.engine.peek(_catalogs.workers).hasData) {
      return;
    }
    final workflow = _availableWorkflows
        .where((item) => item.reference == saved.workflowReference)
        .firstOrNull;
    if (workflow == null) {
      if (!_loadingWorkflows) _pendingThreadViewState = null;
      return;
    }
    _workflow = workflow.reference;
    final worker = _eligibleWorkers
        .where((candidate) => candidate.id == saved.workerId)
        .firstOrNull;
    final selection = <String, dynamic>{
      if (worker != null) 'workerId': worker.id,
    };
    if (worker?.executionOptions != null) {
      final values = worker!.executionOptions!.reconcileSelection(
        model: saved.model,
        effort: saved.reasoningEffort,
      );
      if (values.model != null) selection['model'] = values.model;
      if (values.effort != null) {
        selection['reasoningEffort'] = values.effort;
      }
    }
    _workExecutionSelection = selection;
    _pendingThreadViewState = null;
    _updateComposerState(() {});
  }

  Future<void> _restoreThreadViewState() async {
    final userId = widget.currentUserId;
    final threadId = widget.thread.id;
    final generation = ++_threadViewStateGeneration;
    _threadViewStateRestored = false;
    _pendingThreadViewState = null;
    if (userId == null || userId.isEmpty) {
      _threadViewStateRestored = true;
      return;
    }
    final saved = await _threadViewStateStore.load(
      userId: userId,
      threadId: threadId,
    );
    if (!mounted ||
        generation != _threadViewStateGeneration ||
        widget.thread.id != threadId ||
        widget.currentUserId != userId) {
      return;
    }
    _threadViewStateRestored = true;
    if (saved != null) {
      _discussionController.text = saved.chatDraft;
      _requestController.text = saved.workDraft;
      _pendingThreadViewState = saved;
      _tabController.animateTo(saved.tabIndex);
      _reconcilePendingThreadViewState();
    }
    _scheduleThreadViewStateSave();
  }

  void _onThreadTabChanged() {
    if (!_tabController.indexIsChanging) _scheduleThreadViewStateSave();
  }

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
    _cancelWorkflowDefault?.call();
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
      _updateComposerState(() {
        _userWorkflowConfigurations = state.data ?? const [];
        if (!_threadViewStateRestored || widget.currentUserId == null) {
          _workExecutionSelection = {};
        }
      });
    });
    _workflowDefaultId = cache.engine.peek(cache.defaultQuery).data;
    _cancelWorkflowDefault = cache.engine.watch(cache.defaultQuery, (state) {
      if (!mounted) return;
      if (state.hasData) {
        _updateComposerState(() {
          _workflowDefaultId = state.data;
          if (!_threadViewStateRestored || widget.currentUserId == null) {
            _workExecutionSelection = {};
          }
          if ((!_threadViewStateRestored || widget.currentUserId == null) &&
              _workflowCatalog.isNotEmpty) {
            _workflow = _threadDefaultReference(_workflowCatalog,
                preferredId: _workflowDefaultId);
          }
        });
      }
    }, fireImmediately: false);
    unawaited(cache
        .ensure()
        .catchError((Object error) => <AxUserWorkflowConfiguration>[]));
    unawaited(cache.ensureDefault().catchError((Object error) => 'chat'));
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
    _tabController.addListener(_onThreadTabChanged);
    _refreshWorkTimeline();
    _requestController.addListener(_alignComposers);
    _requestController.addListener(_scheduleThreadViewStateSave);
    _discussionController.addListener(_alignComposers);
    _discussionController.addListener(_scheduleThreadViewStateSave);
    _subscribeToWorkEvents();
    _subscribeWorkflowConfigurations();
    _subscribeCatalogs();
    _subscribeWorkflowWorkspace();
    _loadWorkChoices();
    _loadWorkflowCatalog();
    unawaited(_restoreThreadViewState());
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
      _workflow = _threadDefaultReference(_workflowCatalog,
          preferredId: _workflowDefaultId);
    }
    _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
    _cancelWorkflows = _catalogs.engine.watch(_catalogs.workflows, (state) {
      if (!mounted) return;
      _updateComposerState(() {
        if (state.hasData) {
          _workflowCatalog = state.data!;
          if (!_workflowCatalog.any((item) => item.reference == _workflow)) {
            _workflow = _threadDefaultReference(_workflowCatalog,
                preferredId: _workflowDefaultId);
          }
          _reconcilePendingThreadViewState();
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
        _workflow = workflows.isEmpty
            ? ''
            : _threadDefaultReference(workflows,
                preferredId: _workflowDefaultId);
        _reconcilePendingThreadViewState();
      });
    } catch (_) {
      if (!mounted || catalogs != _catalogs) return;
      _updateState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Could not load the Workflow catalog.';
      });
    }
  }

  String _threadDefaultReference(List<AxBuiltinWorkflow> workflows,
      {String? preferredId}) {
    if (workflows.isEmpty) return '';
    final current = _currentWorkflowVersions(workflows);
    if (preferredId != null) {
      final preferred =
          current.where((item) => item.id == preferredId).firstOrNull;
      if (preferred != null) return preferred.reference;
    }
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
        _reconcilePendingThreadViewState();
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
        _reconcilePendingThreadViewState();
      });
    } catch (_) {
      // The shared queries retain their last valid data on refresh failure.
    }
  }

  @override
  void didUpdateWidget(ThreadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.thread.id != widget.thread.id &&
        _threadViewStateRestored &&
        oldWidget.currentUserId != null &&
        oldWidget.currentUserId == widget.currentUserId) {
      _threadViewStateSaveTimer?.cancel();
      unawaited(_threadViewStateStore.save(
        userId: oldWidget.currentUserId!,
        threadId: oldWidget.thread.id,
        state: _currentThreadViewState(),
      ));
    }
    if (oldWidget.thread.id != widget.thread.id ||
        oldWidget.space.id != widget.space.id ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.currentUserId != widget.currentUserId) {
      _workExecutionSelection = {};
    }
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
      _threadViewStateGeneration++;
      _threadViewStateRestored = false;
      _pendingThreadViewState = null;
      _discussionController.clear();
      _requestController.clear();
      _workExecutionSelection = {};
      _workflow = '';
      _followWork = _followChat = true;
      unawaited(_restoreThreadViewState());
    } else if (oldWidget.currentUserId != widget.currentUserId) {
      unawaited(_restoreThreadViewState());
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
    _cancelWorkflowDefault?.call();
    _cancelWorkflows?.call();
    _cancelWorkers?.call();
    _cancelWorkflowWorkspace?.call();
    _cancelWorkHistory?.call();
    _cancelWorkRealtime?.call();
    _workEventSubscription?.cancel();
    _threadViewStateSaveTimer?.cancel();
    unawaited(_saveThreadViewState());
    _tabController.dispose();
    _requestController.removeListener(_alignComposers);
    _requestController.removeListener(_scheduleThreadViewStateSave);
    _discussionController.removeListener(_alignComposers);
    _discussionController.removeListener(_scheduleThreadViewStateSave);
    _tabController.removeListener(_onThreadTabChanged);
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
        attachments: _workAttachments,
        onAddFiles: _addWorkFiles,
        executionSelection: _workExecutionSelection,
        onExecutionSelectionChanged: (selection) {
          _updateState(() => _workExecutionSelection = {
                ..._workExecutionSelection,
                ...selection
              });
          _scheduleThreadViewStateSave();
        },
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
        onWorkflowChanged: (value) {
          _updateState(() {
            _workflow = value;
            _workExecutionSelection = {};
          });
          _scheduleThreadViewStateSave();
        },
        onRun: _runWork,
      );
}

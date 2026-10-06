part of '../projects_pages.dart';

class WorkstreamPage extends StatefulWidget {
  const WorkstreamPage({
    super.key,
    required this.project,
    required this.workstream,
    this.dataSource,
    this.discussionCache,
    this.workHistoryCache,
    this.currentUserId,
    this.currentUserName,
    required this.onBackToProject,
    required this.onArchive,
    this.onRename,
    this.onRunWork,
    this.realtimeEvents,
    this.initialTab = 0,
  });

  final AxProject project;
  final AxWorkstream workstream;
  final AxDataSource? dataSource;
  final AxDiscussionCache? discussionCache;
  final AxWorkHistoryCache? workHistoryCache;
  final String? currentUserId;
  final String? currentUserName;
  final VoidCallback onBackToProject;
  final VoidCallback onArchive;
  final Future<void> Function(String name)? onRename;
  final Future<String> Function(String prompt, String workflowId,
      List<Map<String, dynamic>> attachments)? onRunWork;
  final Stream<Map<String, dynamic>>? realtimeEvents;
  final int initialTab;

  @override
  State<WorkstreamPage> createState() => _WorkstreamPageState();
}

class _WorkstreamPageState extends State<WorkstreamPage>
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
  double _chatComposerSpace = 48;

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
        setState(() => _chatComposerSpace = space);
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
  late final TextEditingController _workstreamInstructionsController;
  String _workflow = '';
  List<AxBuiltinWorkflow> _workflowCatalog = const [];
  List<AxBuiltinWorkflow> get _currentWorkflows =>
      _currentWorkflowVersions(_workflowCatalog);
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
      _workHistoryCache.peek(widget.workstream.id).requests;
  set _workTimeline(List<AxWorkRequest> value) =>
      _workHistoryCache.replace(widget.workstream.id, value);
  void _subscribeWorkHistory() {
    _cancelWorkHistory?.call();
    _cancelWorkHistory = _workHistoryCache.watch(widget.workstream.id, () {
      if (!mounted) return;
      setState(() {
        final confirmed =
            _workHistoryCache.peek(widget.workstream.id).confirmedIds;
        _localWorkProgress.removeWhere((id, _) => confirmed.contains(id));
      });
    });
  }

  final Map<String, String> _localWorkProgress = {};
  bool get _loadingWorkTimeline =>
      !_workHistoryCache.peek(widget.workstream.id).initialLoaded &&
      _workHistoryCache.loading(widget.workstream.id);
  String? get _workTimelineError =>
      _workHistoryCache.error(widget.workstream.id)?.toString();
  String? _workSubmitError;
  StreamSubscription<Map<String, dynamic>>? _workEventSubscription;
  void Function()? _cancelWorkRealtime;
  bool _submittingWork = false;
  List<Map<String, dynamic>> _workAttachments = [];
  List<AxWorker> _projectWorkers = const [];
  List<AxWorker> _eligibleWorkers = const [];
  late Map<String, dynamic> _workConfig;
  bool _loadingWorkChoices = true;
  bool _savingWorkConfig = false;
  final _workSettingsChanges = ValueNotifier<int>(0);

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
            _workHistoryCache.peek(widget.workstream.id).olderCursor != null &&
            !_workHistoryCache.loadingOlder(widget.workstream.id) &&
            _workHistoryCache.error(widget.workstream.id) == null) {
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
          final state = _discussionCache.peek(widget.workstream.id);
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
    if (widget.initialTab == 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openWorkSettings(context);
        }
      });
    }
    _workConfig = Map<String, dynamic>.from(widget.workstream.workConfig);
    _workstreamInstructionsController = TextEditingController(
      text: _workConfig['workstreamInstructions']?.toString() ?? '',
    );
    _refreshWorkTimeline();
    _subscribeToWorkEvents();
    _loadWorkChoices();
    _loadWorkflowCatalog();
  }

  Future<void> _loadWorkflowCatalog() async {
    final ds = widget.dataSource;
    if (ds == null) {
      setState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Workflow catalog is unavailable.';
      });
      return;
    }
    try {
      final workflows = await ds.loadBuiltinWorkflowCatalog();
      if (!mounted) return;
      setState(() {
        _workflowCatalog = workflows;
        _loadingWorkflows = false;
        _workflowCatalogError =
            workflows.isEmpty ? 'No built-in Workflows are available.' : null;
        _workflow =
            workflows.isEmpty ? '' : _workstreamDefaultReference(workflows);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Could not load the Workflow catalog.';
      });
    }
  }

  String _workstreamDefaultReference(List<AxBuiltinWorkflow> workflows) {
    if (workflows.isEmpty) return '';
    final defaultId = _workConfig['defaultWorkflowId']?.toString();
    final current = _currentWorkflowVersions(workflows);
    return current
            .where((workflow) => workflow.id == defaultId)
            .map((workflow) => workflow.reference)
            .firstOrNull ??
        current.first.reference;
  }

  Future<void> _loadWorkChoices() async {
    final ds = widget.dataSource;
    if (ds == null) {
      setState(() => _loadingWorkChoices = false);
      return;
    }
    try {
      final loaded = await Future.wait([
        ds.loadWorkspaceWorkerInventory(),
        ds.loadProjectWorkspaces(projectId: widget.project.id),
      ]);
      if (!mounted) return;
      final grants = loaded[1] as List<Map<String, dynamic>>;
      final grantedWorkspaceIds = <String>{};
      for (final grant in grants) {
        final id = (grant['workspaceId'] ?? grant['id'] ?? '').toString();
        if (id.isEmpty) continue;
        grantedWorkspaceIds.add(id);
      }
      setState(() {
        _projectWorkers = (loaded[0] as List<AxWorker>)
            .where((worker) => grantedWorkspaceIds.contains(worker.workspaceId))
            .toList();
        _eligibleWorkers = _projectWorkers
            .where((worker) =>
                worker.activationState == 'enabled' &&
                worker.readinessState == 'ready' &&
                worker.catalogLifecycleState == 'active' &&
                worker.catalogVisibilityState == 'visible')
            .toList();
        _loadingWorkChoices = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingWorkChoices = false);
    }
  }

  @override
  void didUpdateWidget(WorkstreamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataSource != widget.dataSource ||
        oldWidget.discussionCache != widget.discussionCache) {
      _fallbackDiscussionCache = widget.discussionCache ??
          AxDiscussionCache.forSource(widget.dataSource);
    }
    if (oldWidget.workHistoryCache != widget.workHistoryCache ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.workstream.id != widget.workstream.id) {
      _cancelWorkRealtime?.call();
      _fallbackWorkHistoryCache = widget.workHistoryCache ??
          AxWorkHistoryCache.forSource(widget.dataSource);
      _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
          .listen(widget.realtimeEvents, workstreamId: widget.workstream.id);
      _subscribeWorkHistory();
      unawaited(_refreshWorkTimeline());
    }
    if (oldWidget.workstream.id != widget.workstream.id) {
      _discussionController.clear();
      _localWorkProgress.clear();
      _submittingWork = false;
      _followWork = _followChat = true;
    }
    if (oldWidget.initialTab != widget.initialTab) {
      final targetIndex =
          widget.initialTab == 2 ? 1 : widget.initialTab.clamp(0, 1);
      _tabController.animateTo(targetIndex);
      if (widget.initialTab == 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _openWorkSettings(context);
          }
        });
      }
    }
    if (oldWidget.workstream.workConfig != widget.workstream.workConfig) {
      _workConfig = Map<String, dynamic>.from(widget.workstream.workConfig);
      _workstreamInstructionsController.text =
          _workConfig['workstreamInstructions']?.toString() ?? '';
      if (_workflowCatalog.isNotEmpty) {
        _workflow = _workstreamDefaultReference(_workflowCatalog);
      }
    }
    if (oldWidget.realtimeEvents != widget.realtimeEvents) {
      _workEventSubscription?.cancel();
      _subscribeToWorkEvents();
    }
  }

  void _subscribeToWorkEvents() {
    _cancelWorkRealtime?.call();
    _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
        .listen(widget.realtimeEvents, workstreamId: widget.workstream.id);
    _workEventSubscription = widget.realtimeEvents?.listen((event) {
      final type = event['type'];
      final payload = event['payload'];
      if ((type is String &&
              type.startsWith('workstream.discussion.') &&
              ((payload is Map &&
                      payload['workstreamId'] == widget.workstream.id) ||
                  event['workstreamId'] == widget.workstream.id)) ||
          type == 'reconnect.required' ||
          (type == 'realtime.connection' && event['status'] == 'connected')) {
        unawaited(_discussionCache
            .synchronize(widget.workstream.id,
                reconcileNewest:
                    type is String && type.startsWith('workstream.discussion.'))
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      }
    });
  }

  bool get _canExecute =>
      widget.project.role == 'owner' || widget.workstream.canExecuteWork;
  bool get _canConfigureWork =>
      widget.project.role == 'owner' || widget.workstream.canConfigureWork;

  @override
  void dispose() {
    _cancelWorkHistory?.call();
    _cancelWorkRealtime?.call();
    _workEventSubscription?.cancel();
    _tabController.dispose();
    _requestController.dispose();
    _workHistoryController.dispose();
    _chatHistoryController.dispose();
    _discussionController.dispose();
    _workstreamInstructionsController.dispose();
    _workSettingsChanges.dispose();
    super.dispose();
  }

  void _updateState(VoidCallback callback) => setState(callback);

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
              key: ValueKey('workstream-$name-padding'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                key: ValueKey('workstream-$name-pane'),
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
                    const VerticalDivider(
                      width: 1,
                      thickness: 1,
                      indent: 20,
                      endIndent: 20,
                      color: ConclaveBrand.navigation,
                    ),
                    Expanded(child: pane('Work', _work(context))),
                  ]),
            ));
          }
          return Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
                key: const ValueKey('workstream-tab-padding'),
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
          workstreamId: widget.workstream.id,
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
      return _DiscussionItem(
          id: message.id,
          author: isMe ? 'You' : message.authorName ?? 'Member',
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
                        TextButton(
                            onPressed: () => _discussionCache
                                .synchronize(widget.workstream.id)
                                .then<void>((_) {},
                                    onError: (Object _, StackTrace __) {}),
                            child: const Text('Retry Chat sync')),
                      if (!state.hasData && state.isFetching)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Loading Chat…')),
                      if (messages.isEmpty &&
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
                            );
                          },
                        ),
                    ]))),
        const SizedBox(height: 16),
        MarkdownComposer(
          key: alignWithWork ? _chatComposerKey : null,
          controller: _discussionController,
          chatStyle: true,
          onSend: _sendDiscussion,
          additionalControlsBuilder: alignWithWork
              ? (_) => SizedBox(height: _chatComposerSpace)
              : null,
        ),
      ],
    );
  }

  Widget _work(BuildContext context) {
    _followLatest(_workHistoryController, _followWork);
    return _WorkComposer(
      composerKey: _workComposerKey,
      requestController: _requestController,
      historyController: _workHistoryController,
      currentUserId: widget.currentUserId,
      currentUserName: widget.currentUserName,
      workflow: _workflow,
      workflowCatalog: _workflowCatalog,
      loadingWorkflows: _loadingWorkflows,
      workflowCatalogError: _workflowCatalogError,
      canExecute: _canExecute,
      canConfigureWork: _canConfigureWork,
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
      onRemoveAttachment: (index) => setState(() {
        _workAttachments.removeAt(index);
      }),
      onRefresh: _retryWorkSync,
      hasOlder:
          _workHistoryCache.peek(widget.workstream.id).olderCursor != null,
      loadingOlder: _workHistoryCache.loadingOlder(widget.workstream.id),
      onLoadOlder: _loadOlderWorkHistory,
      onShowRunDetails: widget.dataSource == null ? null : _showRunDetails,
      onRetryStep: widget.dataSource == null ? null : _retryWorkRequestStep,
      onCancelRun: widget.dataSource == null ? null : _cancelFailedWorkRequest,
      onWorkflowChanged: (value) => setState(() => _workflow = value),
      onOpenSettings: () => _openWorkSettings(context),
      onRun: _runWork,
    );
  }
}

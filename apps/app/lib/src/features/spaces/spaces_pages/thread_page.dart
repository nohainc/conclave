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
    this.viewerEmail,
    required this.onBackToSpace,
    required this.onArchive,
    this.onRename,
    this.onViewStateChanged,
    this.onRunWork,
    this.onRunWorkWithSelection,
    this.realtimeEvents,
    this.initialTab = 0,
    this.isDraft = false,
    this.draftBusy = false,
    this.onSendDraftDiscussion,
  }) : assert(!isDraft ||
            (onSendDraftDiscussion != null && onRunWorkWithSelection != null));

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
  final String? viewerEmail;
  final VoidCallback onBackToSpace;
  final VoidCallback onArchive;
  final Future<void> Function(String name)? onRename;

  /// Persists the Thread's active tab and workflow/Worker/model/effort
  /// selection into the Thread metadata. Null values clear a stored key.
  final Future<void> Function(Map<String, dynamic> viewState)?
      onViewStateChanged;
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

  /// Draft views load Space configuration but never read or persist Thread data.
  final bool isDraft;
  final bool draftBusy;
  final Future<void> Function(String text)? onSendDraftDiscussion;

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
  bool _threadViewReady = false;
  bool _threadViewRevealScheduled = false;
  AxThreadViewState? _pendingThreadViewState;
  Map<String, dynamic>? _lastRemoteViewState;
  final _requestController = TextEditingController();
  final _workHistoryController = ScrollController();
  late final AxWorkerUsageController _workerUsage = AxWorkerUsageController(
      widget.dataSource is AxWorkerUsageDataSource
          ? widget.dataSource as AxWorkerUsageDataSource
          : null);
  final _chatHistoryController = ScrollController();
  final _chatIncomingAnchor = AxTimelineFollowAnchor();
  final _workIncomingAnchor = AxTimelineFollowAnchor();
  List<String>? _previousChatIds;
  Map<String, Object?>? _previousWorkReplies;
  bool _followWork = true;
  bool _followChat = true;
  // Opening a tab positions it once the Thread view state and history exist:
  // bottom when nothing is new, otherwise the last-seen item at the top.
  bool _openChatPending = true;
  bool _openWorkPending = true;
  String? _chatSeenId;
  String? _workSeenId;
  bool _chatFollowScheduled = false;
  bool _workFollowScheduled = false;
  int _interactionGeneration = 0;
  bool _loadingOlderChat = false;
  void _invalidateInteractionCallbacks() {
    _interactionGeneration++;
    _chatIncomingAnchor.reset(clearKeys: true);
    _workIncomingAnchor.reset(clearKeys: true);
    _previousChatIds = null;
    _previousWorkReplies = null;
    _chatFollowScheduled = false;
    _workFollowScheduled = false;
    _openChatPending = _openWorkPending = true;
  }

  List<(String, Object)> _chatSequence() => [
        for (final message in _chatPresentation.messages)
          (message.id, message.id),
      ];

  /// Work reads as request/response items so a response arriving later in an
  /// already-seen request counts as new.
  List<(String, Object)> _workSequence() {
    final items = <(String, Object)>[];
    for (final request in _workPresentation.requests) {
      items.add(('${request.id}|request', (request.id, 'request')));
      if (_workResponseText(request) != null || request.status == 'failed') {
        items.add(('${request.id}|response', (request.id, 'response')));
      }
    }
    return items;
  }

  /// A new item scrolls to the message before it so the reader sees where the
  /// new content starts; the first item has no predecessor and anchors itself.
  void _anchorIncoming(AxTimelineFollowAnchor anchor,
      ScrollController controller, List<Object> sequence, Object target) {
    if (anchor.active) return;
    final index = sequence.indexOf(target);
    if (index <= 0) {
      anchor.observe(target, controller);
      return;
    }
    anchor.anchorAt(sequence[index - 1],
        next: target, fraction: index / sequence.length, once: false);
  }

  bool _tabActive(bool isWork) => _tabController.index == (isWork ? 1 : 0);

  /// Returns true when the opening step ran and a rebuilt frame must reveal it.
  bool _openTab(bool isWork, ScrollController controller) {
    if (!(isWork ? _openWorkPending : _openChatPending)) return false;
    final hasData =
        isWork ? _workPresentation.hasData : _chatPresentation.hasData;
    if (!_threadViewStateRestored ||
        !hasData ||
        !_tabActive(isWork) ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions) {
      return false;
    }
    final items = isWork ? _workSequence() : _chatSequence();
    final seen = isWork ? _workSeenId : _chatSeenId;
    final seenIndex =
        seen == null ? -1 : items.indexWhere((item) => item.$1 == seen);
    final anchor = isWork ? _workIncomingAnchor : _chatIncomingAnchor;
    if (isWork) {
      _openWorkPending = false;
      _followWork = true;
    } else {
      _openChatPending = false;
      _followChat = true;
    }
    if (seenIndex < 0 || seenIndex >= items.length - 1) {
      anchor.reset();
      return false;
    }
    anchor.anchorAt(items[seenIndex].$2,
        next: items[seenIndex + 1].$2,
        fraction: (seenIndex + 1) / items.length);
    // The anchored row needs its GlobalKey attached by a rebuild first.
    setState(() {});
    return true;
  }

  void _markSeen(bool isWork, ScrollController controller) {
    if (isWork ? _openWorkPending : _openChatPending) return;
    if (!_tabActive(isWork) ||
        !controller.hasClients ||
        !controller.position.hasContentDimensions ||
        controller.position.extentAfter > 24) {
      return;
    }
    final items = isWork ? _workSequence() : _chatSequence();
    if (items.isEmpty) return;
    final last = items.last.$1;
    if (last == (isWork ? _workSeenId : _chatSeenId)) return;
    if (isWork) {
      _workSeenId = last;
    } else {
      _chatSeenId = last;
    }
    _scheduleThreadViewStateSave();
  }

  /// Scrolls to the end once the new row is laid out; a second pass covers
  /// rows whose height settles a frame later.
  void _jumpToLatest(ScrollController controller, {int pass = 0}) {
    final generation = _interactionGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _interactionGeneration ||
          !controller.hasClients ||
          !controller.position.hasContentDimensions) {
        return;
      }
      final max = controller.position.maxScrollExtent;
      if (controller.position.pixels != max) controller.jumpTo(max);
      if (pass < 2) _jumpToLatest(controller, pass: pass + 1);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _scheduleFollowLatest(ScrollController controller, {int attempt = 0}) {
    final isWork = controller == _workHistoryController;
    final follow = isWork ? _followWork : _followChat;
    if (!follow && !(isWork ? _openWorkPending : _openChatPending)) return;
    if (isWork ? _workFollowScheduled : _chatFollowScheduled) return;
    final generation = _interactionGeneration;
    if (isWork) {
      _workFollowScheduled = true;
    } else {
      _chatFollowScheduled = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _interactionGeneration) return;
      if (isWork) {
        _workFollowScheduled = false;
      } else {
        _chatFollowScheduled = false;
      }
      if (!mounted || !controller.hasClients) return;
      if (_openTab(isWork, controller)) {
        _scheduleFollowLatest(controller);
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      final stillFollowing =
          controller == _workHistoryController ? _followWork : _followChat;
      if (stillFollowing && !(isWork ? _openWorkPending : _openChatPending)) {
        final anchor = isWork ? _workIncomingAnchor : _chatIncomingAnchor;
        if (anchor.reveal(controller) && attempt < 6) {
          _scheduleFollowLatest(controller, attempt: attempt + 1);
          WidgetsBinding.instance.scheduleFrame();
          return;
        }
      }
      _markSeen(isWork, controller);
    });
  }

  void _onChatPresentationChanged() {
    final state = _chatPresentation;
    final ids = state.messages.map((message) => message.id).toList();
    final previous = _previousChatIds;
    _chatIncomingAnchor.retainMessages(ids);
    if (previous != null) {
      // Only appended entries count: older-page prepends and edits retain
      // the reader's position and never become incoming-message anchors.
      final frontier = previous.isEmpty ? -1 : ids.indexOf(previous.last);
      for (final id in ids.skip(frontier + 1)) {
        if (!previous.contains(id)) {
          final own = state.messages.any((m) => m.id == id && m.isMe);
          if (own) {
            // A message you just sent: jump to the latest content even when
            // the reader had scrolled up.
            _followChat = true;
            _chatIncomingAnchor.reset();
            _jumpToLatest(_chatHistoryController);
          } else if (_followChat) {
            _anchorIncoming(_chatIncomingAnchor, _chatHistoryController,
                List<Object>.of(ids), id);
          }
          break;
        }
      }
    }
    if (state.hasData) _previousChatIds = ids;
    _scheduleFollowLatest(_chatHistoryController);
  }

  void _onWorkPresentationChanged() {
    final state = _workPresentation;
    final previous = _previousWorkReplies;
    final replies = <String, Object?>{};
    _workIncomingAnchor.retainMessages([
      for (final request in state.requests) ...[
        (request.id, 'request'),
        (request.id, 'response'),
      ],
    ]);
    final frontier =
        state.requests.indexWhere((r) => previous?.containsKey(r.id) == true);
    for (final (index, request) in state.requests.indexed) {
      final response = _workResponseText(request);
      final reply = response == null && request.status != 'failed'
          ? null
          : (response, request.error, request.status == 'failed');
      replies[request.id] = reply;
      if (previous != null) {
        if (!previous.containsKey(request.id)) {
          // Prepending a history page must not move the viewport.
          if (previous.isEmpty || index > frontier) {
            final viewerId = widget.currentUserId;
            if (viewerId != null && request.requestedByUserId == viewerId) {
              // A request you just sent: jump to the latest content even
              // when the reader had scrolled up.
              _followWork = true;
              _workIncomingAnchor.reset();
              _jumpToLatest(_workHistoryController);
              continue;
            }
            if (!_followWork) continue;
            _anchorIncoming(
                _workIncomingAnchor,
                _workHistoryController,
                [for (final item in _workSequence()) item.$2],
                (request.id, 'request'));
          }
        } else if (_followWork &&
            reply != null &&
            reply != previous[request.id]) {
          _anchorIncoming(
              _workIncomingAnchor,
              _workHistoryController,
              [for (final item in _workSequence()) item.$2],
              (request.id, 'response'));
        }
      }
    }
    if (state.hasData) _previousWorkReplies = replies;
    _scheduleFollowLatest(_workHistoryController);
  }

  void _onWorkActivityChanged() {
    _scheduleFollowLatest(_workHistoryController);
  }

  void _onWorkHistoryScroll() {
    if (!_workHistoryController.hasClients) return;
    final position = _workHistoryController.position;
    if (position.userScrollDirection == ScrollDirection.idle) {
      _markSeen(true, _workHistoryController);
      return;
    }
    _followWork = position.extentAfter <= 24;
    _workIncomingAnchor.reset();
    _markSeen(true, _workHistoryController);
    if (position.userScrollDirection == ScrollDirection.forward &&
        position.extentBefore <= 24 &&
        _workHistoryCache.peek(widget.thread.id).olderCursor != null &&
        !_workHistoryCache.loadingOlder(widget.thread.id) &&
        _workHistoryCache.error(widget.thread.id) == null) {
      unawaited(_loadOlderWorkHistory());
    }
  }

  void _onChatHistoryScroll() {
    if (!_chatHistoryController.hasClients) return;
    final position = _chatHistoryController.position;
    if (position.userScrollDirection == ScrollDirection.idle) {
      _markSeen(false, _chatHistoryController);
      return;
    }
    _followChat = position.extentAfter <= 24;
    _chatIncomingAnchor.reset();
    _markSeen(false, _chatHistoryController);
    if (position.userScrollDirection == ScrollDirection.forward &&
        position.extentBefore <= 24) {
      final state = _discussionCache.peek(widget.thread.id);
      if (state.olderCursor != null &&
          !state.loadingOlder &&
          state.error == null) {
        unawaited(_loadOlderDiscussion());
      }
    }
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
      .where((workflow) =>
          canPreviewUnimplementedWorkflows(widget.viewerEmail) ||
          implementedWorkflowIds.contains(workflow.id))
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
  AxWorkRealtimeSync get _workRealtime =>
      AxWorkRealtimeSync.forCache(_workHistoryCache);
  final _workActivityStore = AxWorkActivityStore();
  late final ThreadPresentationController _presentation;
  // A terminal Worker activity precedes the result frame, so the request detail
  // is re-read shortly after only if Work status events have not caught up.
  final _terminalActivityChecks = <String, Timer>{};
  bool _loadingOlderWork = false;
  List<AxWorkRequest> get _workTimeline =>
      _presentation.work.value?.requests ?? const [];
  void _subscribeWorkHistory() {
    if (widget.isDraft) return;
    _presentation.attach(
      threadId: widget.thread.id,
      discussionCache: _discussionCache,
      workHistoryCache: _workHistoryCache,
    );
  }

  Map<String, String> get _localWorkProgress => _workPresentation.localProgress;

  ThreadWorkPresentationSnapshot get _workPresentation =>
      _presentation.work.value ??
      const ThreadWorkPresentationSnapshot(
        generation: 0,
        requests: [],
        hasData: false,
        isFetching: false,
        loadingOlder: false,
        olderCursor: null,
        error: null,
        submitting: false,
        localProgress: {},
      );

  ThreadChatPresentationSnapshot get _chatPresentation =>
      _presentation.chat.value ??
      const ThreadChatPresentationSnapshot(
        generation: 0,
        messages: [],
        hasData: false,
        isFetching: false,
        loadingOlder: false,
        olderCursor: null,
        error: null,
      );

  bool get _loadingWorkTimeline =>
      !_workPresentation.hasData && _workPresentation.isFetching;
  String? get _workTimelineError => _workPresentation.error?.toString();
  String? _workSubmitError;
  final _reportedIssues = <String, AxIssueReport>{};
  final _reportedIssueKeys = <String, String>{};
  final _issueReportErrors = <String, String>{};
  final _reportingIssueIds = <String>{};
  final _checkedIssueReportKeys = <String>{};
  final _issueReportLoads = <String, Future<void>>{};
  StreamSubscription<Map<String, dynamic>>? _workEventSubscription;
  void Function()? _cancelWorkRealtime;
  bool _draftSubmitting = false;
  bool get _submittingWork =>
      widget.draftBusy || _draftSubmitting || _workPresentation.submitting;
  List<Map<String, dynamic>> _workAttachments = [];
  Map<String, dynamic> _workExecutionSelection = {};
  List<AxWorker> _spaceWorkers = const [];
  List<AxWorker> _eligibleWorkers = const [];
  AxWorkflowConfigurations? _workflowConfigurations;
  void Function()? _cancelWorkflowConfigurations;
  void Function()? _cancelWorkflowDefault;
  String? _workflowDefaultId;
  List<AxUserWorkflowConfiguration> _userWorkflowConfigurations = const [];

  void _onPresentationWorkChanged() {
    if (!mounted) return;
    _scheduleIssueReportStatusLoads();
    _scheduleFollowLatest(_workHistoryController);
  }

  void _scheduleThreadViewStateSave() {
    if (widget.isDraft ||
        !_threadViewStateRestored ||
        widget.currentUserId == null) {
      return;
    }
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

  AxThreadViewState _currentThreadViewState() {
    final pending = _pendingThreadViewState;
    final workerId = _selectionValue('workerId');
    final workerTypeId = _spaceWorkers
            .where((worker) => worker.id == workerId)
            .firstOrNull
            ?.workerTypeId ??
        (pending?.workerId == workerId ? pending?.workerTypeId : null);
    return AxThreadViewState(
      tabIndex: _tabController.index,
      // A selection still waiting for the catalogs must survive a save made
      // before it is applied; the live values are only defaults at that point.
      workflowReference: pending != null
          ? pending.workflowReference
          : (_effectiveWorkflow.isEmpty ? null : _effectiveWorkflow),
      workerId: pending != null ? pending.workerId : workerId,
      workerTypeId: pending != null ? pending.workerTypeId : workerTypeId,
      model: pending != null ? pending.model : _selectionValue('model'),
      reasoningEffort: pending != null
          ? pending.reasoningEffort
          : _selectionValue('reasoningEffort'),
      catalogRevision: pending != null
          ? pending.catalogRevision
          : _selectionValue('catalogRevision'),
      chatDraft: _discussionController.text,
      workDraft: _requestController.text,
      chatSeenId: _chatSeenId,
      workSeenId: _workSeenId,
    );
  }

  Map<String, dynamic> _remoteViewStatePayload(AxThreadViewState state) => {
        'tabIndex': state.tabIndex.clamp(0, 1),
        'workflowReference': state.workflowReference,
        'workerId': state.workerId,
        'workerTypeId': state.workerTypeId,
        'model': state.model,
        'reasoningEffort': state.reasoningEffort,
        'catalogRevision': state.catalogRevision,
      };

  /// Thread metadata wins over the browser-local copy for the selection; the
  /// drafts stay local because they are never shared through Cloud.
  AxThreadViewState? _withRemoteViewState(AxThreadViewState? local) {
    final remote = widget.thread.viewState;
    if (remote.isEmpty) return local;
    String? string(String key) {
      final value = remote[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final tab = remote['tabIndex'];
    return AxThreadViewState(
      tabIndex: tab is int ? tab.clamp(0, 1) : local?.tabIndex ?? 0,
      workflowReference: string('workflowReference'),
      workerId: string('workerId'),
      workerTypeId: string('workerTypeId') ??
          (local?.workerId == string('workerId') ? local?.workerTypeId : null),
      model: string('model'),
      reasoningEffort: string('reasoningEffort'),
      catalogRevision: string('catalogRevision'),
      chatDraft: local?.chatDraft ?? '',
      workDraft: local?.workDraft ?? '',
      chatSeenId: local?.chatSeenId,
      workSeenId: local?.workSeenId,
    );
  }

  Future<void> _saveThreadViewState() async {
    if (widget.isDraft) return;
    final userId = widget.currentUserId;
    if (!_threadViewStateRestored || userId == null || userId.isEmpty) return;
    final state = _currentThreadViewState();
    await _threadViewStateStore.save(
      userId: userId,
      threadId: widget.thread.id,
      state: state,
    );
    _persistRemoteViewState(state);
  }

  void _persistRemoteViewState(AxThreadViewState state, [ThreadPage? owner]) {
    final source = owner ?? widget;
    final callback = source.onViewStateChanged;
    // While a saved selection is still waiting for the catalogs, the current
    // state is only defaults and must not replace the stored choice.
    if (callback == null ||
        !source.thread.canConfigureWork ||
        (owner == null && _pendingThreadViewState != null)) {
      return;
    }
    final payload = _remoteViewStatePayload(state);
    final previous = _lastRemoteViewState;
    if (previous != null && mapEquals(previous, payload)) return;
    _lastRemoteViewState = payload;
    callback(payload).catchError((Object _) {
      // Leave the next change (or reopen) to retry; local state is intact.
      if (mapEquals(_lastRemoteViewState, payload)) {
        _lastRemoteViewState = previous;
      }
    });
  }

  void _reconcilePendingThreadViewState() {
    final saved = _pendingThreadViewState;
    if (saved == null || _availableWorkflows.isEmpty) return;
    if (saved.workerId != null &&
        !_catalogs.engine.peek(_catalogs.workers).hasData) {
      return;
    }
    // Match the exact reference first, then the same workflow code at its
    // current version so a version bump keeps the stored choice.
    final savedId = saved.workflowReference?.split(':').first;
    final workflow = _availableWorkflows
            .where((item) => item.reference == saved.workflowReference)
            .firstOrNull ??
        (savedId == null
            ? null
            : _currentWorkflowVersions(_availableWorkflows)
                .where((item) => item.id == savedId)
                .firstOrNull);
    if (workflow == null) {
      if (!_loadingWorkflows) _pendingThreadViewState = null;
      return;
    }
    _workflow = workflow.reference;
    var workerId = saved.workerId;
    var catalogRevision = saved.catalogRevision;
    if (workerId != null && _spaceWorkers.isNotEmpty) {
      // Worker IDs can change when a Worker is rebuilt or re-registered; the
      // Worker type code does not. Re-bind by code when the ID is gone.
      var worker = _spaceWorkers.where((w) => w.id == workerId).firstOrNull;
      if (worker == null && saved.workerTypeId != null) {
        final sameType = _spaceWorkers
            .where((w) => w.workerTypeId == saved.workerTypeId)
            .toList();
        final ready = sameType.where((w) => w.isReady).toList();
        worker = ready.length == 1
            ? ready.single
            : sameType.length == 1
                ? sameType.single
                : null;
        if (worker != null) workerId = worker.id;
      }
      // The catalog revision changes with every rebuilt Worker catalog; model
      // and effort codes stay as saved.
      final current = worker?.executionOptions?.catalogRevision;
      if (current != null) catalogRevision = current;
    }
    // Restoring preferences never silently replaces unavailable saved choices.
    final selection = <String, dynamic>{
      if (workerId != null) 'workerId': workerId,
      if (saved.model != null) 'model': saved.model,
      if (saved.reasoningEffort != null)
        'reasoningEffort': saved.reasoningEffort,
      if (catalogRevision != null) 'catalogRevision': catalogRevision,
    };
    _workExecutionSelection = selection;
    _pendingThreadViewState = null;
    _updateComposerState(() {});
  }

  Future<void> _restoreThreadViewState() async {
    final userId = widget.currentUserId;
    final threadId = widget.thread.id;
    final generation = ++_threadViewStateGeneration;
    _threadViewStateRestored = false;
    _threadViewReady = false;
    _threadViewRevealScheduled = false;
    _pendingThreadViewState = null;
    if (widget.isDraft || userId == null || userId.isEmpty) {
      _threadViewStateRestored = true;
      _threadViewReady = true;
      return;
    }
    final saved = _withRemoteViewState(await _threadViewStateStore.load(
      userId: userId,
      threadId: threadId,
    ));
    if (!mounted ||
        generation != _threadViewStateGeneration ||
        widget.thread.id != threadId ||
        widget.currentUserId != userId) {
      return;
    }
    _threadViewStateRestored = true;
    if (widget.thread.viewState.isNotEmpty && saved != null) {
      _lastRemoteViewState = _remoteViewStatePayload(saved);
    }
    if (saved != null) {
      // A draft typed while the asynchronous restore was in flight belongs
      // to the current user, not to the persistence result. Never overwrite
      // non-empty input or an active edit session.
      if (_discussionController.text.isEmpty && saved.chatDraft.isNotEmpty) {
        _discussionController.value = TextEditingValue(
          text: saved.chatDraft,
          selection: TextSelection.collapsed(offset: saved.chatDraft.length),
        );
      }
      if (_requestController.text.isEmpty && saved.workDraft.isNotEmpty) {
        _requestController.value = TextEditingValue(
          text: saved.workDraft,
          selection: TextSelection.collapsed(offset: saved.workDraft.length),
        );
      }
      _chatSeenId = saved.chatSeenId;
      _workSeenId = saved.workSeenId;
      _pendingThreadViewState = saved;
      final targetIndex = saved.tabIndex.clamp(0, _tabController.length - 1);
      if (_tabController.index != targetIndex) {
        _tabController.index = targetIndex;
      }
      _reconcilePendingThreadViewState();
    }
    if (mounted) setState(() {});
    _scheduleThreadViewStateSave();
    _scheduleFollowLatest(_chatHistoryController);
    _scheduleFollowLatest(_workHistoryController);
  }

  void _onThreadTabChanged() {
    AxRenderDiagnostics.instance.updateContext(
      threadId: widget.thread.id,
      tab: _tabController.index == 1 ? 'work' : 'chat',
      component: 'ThreadPage',
      mounted: mounted,
      disposed: false,
    );
    final isWork = _tabController.index == 1;
    if (!_tabController.indexIsChanging) {
      if (isWork) {
        _openWorkPending = true;
      } else {
        _openChatPending = true;
      }
    }
    _scheduleFollowLatest(
        isWork ? _workHistoryController : _chatHistoryController);
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
            if (configuration?.selectionFor(step.kind).catalogRevision != null)
              'catalogRevision':
                  configuration!.selectionFor(step.kind).catalogRevision,
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

  @override
  void initState() {
    super.initState();
    AxRenderDiagnostics.instance.updateContext(
      threadId: widget.thread.id,
      tab: widget.initialTab == 1 ? 'work' : 'chat',
      component: 'ThreadPage',
      mounted: true,
      disposed: false,
    );
    _fallbackDiscussionCache = widget.discussionCache ??
        AxDiscussionCache.forSource(widget.dataSource);
    _fallbackWorkHistoryCache = widget.workHistoryCache ??
        AxWorkHistoryCache.forSource(widget.dataSource);
    _presentation = ThreadPresentationController(
      activityStore: _workActivityStore,
      onWorkChanged: _onPresentationWorkChanged,
    );
    _presentation.chat.addListener(_onChatPresentationChanged);
    _presentation.work.addListener(_onWorkPresentationChanged);
    _workActivityStore.addListener(_onWorkActivityChanged);
    _subscribeWorkHistory();
    _workHistoryController.addListener(_onWorkHistoryScroll);
    _chatHistoryController.addListener(_onChatHistoryScroll);
    _tabController = TabController(
      length: 2,
      initialIndex: widget.initialTab == 2 ? 1 : widget.initialTab.clamp(0, 1),
      vsync: this,
    );
    _tabController.addListener(_onThreadTabChanged);
    _refreshWorkTimeline();
    _requestController.addListener(_scheduleThreadViewStateSave);
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
    _workflowCatalog = visibleWorkflowDefinitions(
        workflows.data ?? const <AxBuiltinWorkflow>[],
        viewerEmail: widget.viewerEmail);
    _loadingWorkflows = !workflows.hasData;
    if (_workflowCatalog.isNotEmpty &&
        !_workflowCatalog.any((item) => item.reference == _workflow)) {
      _workflow = _threadDefaultReference(_workflowCatalog,
          preferredId: _workflowDefaultId);
    }
    _applyWorkers(_catalogs.engine.peek(_catalogs.workers).data ?? const []);
    _cancelWorkflows = _catalogs.engine.watch(_catalogs.workflows, (state) {
      if (!mounted) return;
      _updateComposerState(() {
        if (state.hasData) {
          _workflowCatalog = visibleWorkflowDefinitions(state.data!,
              viewerEmail: widget.viewerEmail);
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
      final visibleWorkflows = visibleWorkflowDefinitions(workflows,
          viewerEmail: widget.viewerEmail);
      _updateState(() {
        _workflowCatalog = visibleWorkflows;
        _loadingWorkflows = false;
        _workflowCatalogError = visibleWorkflows.isEmpty
            ? 'No built-in Workflows are available.'
            : null;
        if (visibleWorkflows.isEmpty) {
          _workflow = '';
        } else if (!visibleWorkflows
            .any((item) => item.reference == _workflow)) {
          _workflow = _threadDefaultReference(visibleWorkflows,
              preferredId: _workflowDefaultId);
        }
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
    final threadChanged = oldWidget.thread.id != widget.thread.id;
    if (threadChanged) _invalidateInteractionCallbacks();
    if (oldWidget.thread.id != widget.thread.id &&
        _threadViewStateRestored &&
        oldWidget.currentUserId != null &&
        oldWidget.currentUserId == widget.currentUserId) {
      _threadViewStateSaveTimer?.cancel();
      final leaving = _currentThreadViewState();
      unawaited(_threadViewStateStore.save(
        userId: oldWidget.currentUserId!,
        threadId: oldWidget.thread.id,
        state: leaving,
      ));
      // Persist the Cloud copy for the thread being left; otherwise the stale
      // Cloud metadata wins over the newer local copy when returning to it.
      _persistRemoteViewState(leaving, oldWidget);
    }
    if (oldWidget.thread.id != widget.thread.id ||
        oldWidget.space.id != widget.space.id ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.currentUserId != widget.currentUserId) {
      _workExecutionSelection = {};
      _reportedIssues.clear();
      _reportedIssueKeys.clear();
      _issueReportErrors.clear();
      _reportingIssueIds.clear();
      _checkedIssueReportKeys.clear();
      _issueReportLoads.clear();
    }
    if (oldWidget.workflowConfigurations != widget.workflowConfigurations ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.space.id != widget.space.id) {
      _cancelWorkflowConfigurations?.call();
      _subscribeWorkflowConfigurations();
    }
    if (oldWidget.catalogs != widget.catalogs ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.viewerEmail != widget.viewerEmail) {
      _subscribeCatalogs();
      unawaited(_loadWorkflowCatalog());
    }
    if (oldWidget.catalogs != widget.catalogs ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.space.id != widget.space.id) {
      _subscribeWorkflowWorkspace();
      unawaited(_loadWorkChoices());
    }
    var presentationSourcesChanged = false;
    if (oldWidget.dataSource != widget.dataSource ||
        oldWidget.discussionCache != widget.discussionCache) {
      _fallbackDiscussionCache = widget.discussionCache ??
          AxDiscussionCache.forSource(widget.dataSource);
      presentationSourcesChanged = true;
    }
    if (oldWidget.workHistoryCache != widget.workHistoryCache ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.thread.id != widget.thread.id) {
      _cancelWorkRealtime?.call();
      _fallbackWorkHistoryCache = widget.workHistoryCache ??
          AxWorkHistoryCache.forSource(widget.dataSource);
      _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
          .listen(widget.realtimeEvents, threadId: widget.thread.id);
      presentationSourcesChanged = true;
      unawaited(_refreshWorkTimeline());
    }
    if (threadChanged) {
      presentationSourcesChanged = true;
    }
    if (presentationSourcesChanged) _subscribeWorkHistory();
    if (oldWidget.thread.id != widget.thread.id) {
      _threadViewStateGeneration++;
      _threadViewStateRestored = false;
      _threadViewReady = false;
      _threadViewRevealScheduled = false;
      _pendingThreadViewState = null;
      _lastRemoteViewState = null;
      _discussionController.clear();
      _requestController.clear();
      _workExecutionSelection = {};
      _workflow = '';
      _followWork = _followChat = true;
      _chatSeenId = _workSeenId = null;
      _openChatPending = _openWorkPending = true;
      _workActivityStore.clear();
      _cancelTerminalActivityChecks();
      unawaited(_restoreThreadViewState());
    } else if (oldWidget.currentUserId != widget.currentUserId) {
      unawaited(_restoreThreadViewState());
    }
    if (oldWidget.initialTab != widget.initialTab) {
      final targetIndex =
          widget.initialTab == 2 ? 1 : widget.initialTab.clamp(0, 1);
      if (_tabController.index != targetIndex) {
        _tabController.index = targetIndex;
      }
    }
    if (oldWidget.realtimeEvents != widget.realtimeEvents) {
      _workEventSubscription?.cancel();
      _subscribeToWorkEvents();
    }
  }

  static const _terminalActivityTypes = {
    'execution.completed',
    'execution.failed',
    'execution.cancelled',
  };

  void _cancelTerminalActivityChecks() {
    for (final timer in _terminalActivityChecks.values) {
      timer.cancel();
    }
    _terminalActivityChecks.clear();
  }

  /// Worker activity can outrun the Work status events. When an execution
  /// reports a terminal activity, re-read the request once if it is still
  /// unfinished a moment later. This only triggers a sync; request status
  /// remains the authority for every terminal state.
  void _checkRequestAfterTerminalActivity(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is! Map ||
        !_terminalActivityTypes.contains(payload['activityType'])) {
      return;
    }
    final assignmentId = event['assignmentId'] ?? payload['entityId'];
    if (assignmentId is! String || assignmentId.isEmpty) return;
    if (_terminalActivityChecks.containsKey(assignmentId)) return;
    final threadId = widget.thread.id;
    _terminalActivityChecks[assignmentId] =
        Timer(const Duration(milliseconds: 1500), () {
      _terminalActivityChecks.remove(assignmentId);
      if (!mounted || widget.thread.id != threadId) return;
      final request = _workTimeline
          .where((r) =>
              AxWorkActivityStore.assignmentIdsFor(r).contains(assignmentId))
          .firstOrNull;
      if (request == null ||
          request.id.startsWith('local-') ||
          AxWorkProgress.terminalStatuses.contains(request.status)) {
        return;
      }
      unawaited(_workHistoryCache
          .refreshRequest(threadId, request.id)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    });
  }

  void _subscribeToWorkEvents() {
    if (widget.isDraft) return;
    _cancelWorkRealtime?.call();
    _cancelWorkRealtime = AxWorkRealtimeSync.forCache(_workHistoryCache)
        .listen(widget.realtimeEvents, threadId: widget.thread.id);
    _workEventSubscription = widget.realtimeEvents?.listen((event) {
      if (_workActivityStore.handle(event, threadId: widget.thread.id)) {
        _checkRequestAfterTerminalActivity(event);
      }
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

      // Handle thread mutation events (archive, clear, rename)
      if (type is String &&
          payload is Map &&
          payload['threadId'] == widget.thread.id) {
        if (type == 'thread.archived') {
          // Thread was archived by another user or session
          _handleThreadArchived(Map<String, dynamic>.from(payload));
        } else if (type == 'thread.chat_cleared') {
          // Chat was cleared by another session; drop retained messages, then
          // reconcile with the server.
          _discussionCache.resetHistory(widget.thread.id);
          unawaited(_discussionCache
              .synchronize(widget.thread.id, reconcileNewest: true)
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        } else if (type == 'thread.work_cleared') {
          // Discard retained pages before reconciling the remote clear.
          _workHistoryCache.resetHistory(widget.thread.id);
          unawaited(_refreshWorkTimeline()
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        }
      }
    });
  }

  bool get _canExecute =>
      (widget.isDraft
          ? widget.space.effectivePermissions.work &&
              widget.space.effectivePermissions.manageOwnThreads
          : (widget.space.role == 'owner' || widget.thread.canExecuteWork)) &&
      _effectiveWorkflow.isNotEmpty;
  @override
  void dispose() {
    _invalidateInteractionCallbacks();
    AxRenderDiagnostics.instance.updateContext(
      component: 'ThreadPage',
      mounted: false,
      disposed: true,
    );
    _workerUsage.dispose();
    _cancelWorkflowConfigurations?.call();
    _cancelWorkflowDefault?.call();
    _cancelWorkflows?.call();
    _cancelWorkers?.call();
    _cancelWorkflowWorkspace?.call();
    _cancelWorkRealtime?.call();
    _workEventSubscription?.cancel();
    _cancelTerminalActivityChecks();
    _threadViewStateSaveTimer?.cancel();
    unawaited(_saveThreadViewState());
    _tabController.dispose();
    _presentation.chat.removeListener(_onChatPresentationChanged);
    _presentation.work.removeListener(_onWorkPresentationChanged);
    _workActivityStore.removeListener(_onWorkActivityChanged);
    _workActivityStore.dispose();
    _requestController.removeListener(_scheduleThreadViewStateSave);
    _discussionController.removeListener(_scheduleThreadViewStateSave);
    _workHistoryController.removeListener(_onWorkHistoryScroll);
    _chatHistoryController.removeListener(_onChatHistoryScroll);
    _tabController.removeListener(_onThreadTabChanged);
    _requestController.dispose();
    _workHistoryController.dispose();
    _chatHistoryController.dispose();
    _discussionController.dispose();
    _presentation.dispose();
    super.dispose();
  }

  void _updateComposerState(VoidCallback callback) {
    callback();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'ThreadPage',
      operation: 'work.composer.changed',
    );
    _presentation.markComposerChanged();
  }

  void _updateIssueState(VoidCallback callback) {
    callback();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'ThreadPage',
      operation: 'work.issue.changed',
    );
    _presentation.markWorkChanged();
    _presentation.markComposerChanged();
  }

  void _updateState(VoidCallback callback) {
    if (widget.isDraft) {
      setState(callback);
      return;
    }
    callback();
    AxRenderDiagnostics.instance.notifierDispatch(
      component: 'ThreadPage',
      operation: 'thread.state.changed',
    );
    _presentation.markWorkChanged();
    _presentation.markComposerChanged();
  }

  @override
  Widget build(BuildContext context) {
    AxRenderDiagnostics.instance.widgetRebuild(
      component: 'ThreadPage',
      threadId: widget.thread.id,
      tab: _tabController.index == 1 ? 'work' : 'chat',
    );
    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
        if (_threadViewStateRestored &&
            !_threadViewReady &&
            !_threadViewRevealScheduled) {
          _threadViewRevealScheduled = true;
          final generation = _interactionGeneration;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || generation != _interactionGeneration) return;
            // Let the hidden first frame attach both scroll controllers and
            // settle at the saved position before revealing the new Thread.
            setState(() {
              _threadViewReady = true;
              _threadViewRevealScheduled = false;
            });
          });
        }
        Widget tabHeader(List<String> names, {TabController? controller}) =>
            DefaultTabController(
              length: names.length,
              child: Column(children: [
                Center(
                    child: TabBar(
                  controller: controller,
                  isScrollable: true,
                  tabAlignment: TabAlignment.center,
                  labelColor: Theme.of(context).colorScheme.onSurface,
                  unselectedLabelColor:
                      Theme.of(context).brightness == Brightness.dark
                          ? Colors.white38
                          : Colors.black45,
                  indicatorColor: Theme.of(context).colorScheme.onSurface,
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
                if (widget.isDraft) const Spacer(),
                tabHeader([name]),
                if (widget.isDraft) content else Expanded(child: content),
              ],
            ));
        late final Widget content;
        if (constraints.maxWidth >= 1000) {
          content = Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1681),
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: pane('Chat', _discuss(context, twoPane: true))),
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
        } else {
          content = Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
                key: const ValueKey('thread-tab-padding'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.isDraft) const Spacer(),
                    tabHeader(['Chat', 'Work'], controller: _tabController),
                    if (widget.isDraft)
                      _tabController.index == 0
                          ? _discuss(context)
                          : _work(context)
                    else
                      Expanded(
                          child: _tabController.index == 0
                              ? _discuss(context)
                              : _work(context)),
                  ],
                )),
          ));
        }
        return IgnorePointer(
          ignoring: !_threadViewReady,
          child: ExcludeSemantics(
            excluding: !_threadViewReady,
            child: Opacity(
              opacity: _threadViewReady ? 1 : 0,
              child: content,
            ),
          ),
        );
      }),
    );
  }

  Widget _discuss(BuildContext context, {bool twoPane = false}) =>
      ValueListenableBuilder<ThreadChatPresentationSnapshot?>(
        valueListenable: _presentation.chat,
        builder: (context, snapshot, _) => _discussionBody(
          context,
          snapshot ?? _chatPresentation,
          twoPane: twoPane,
        ),
      );

  Widget _discussionBody(
      BuildContext context, ThreadChatPresentationSnapshot state,
      {bool twoPane = false}) {
    final messages = state.messages.map((message) {
      final isMe =
          widget.currentUserId != null && widget.currentUserId!.isNotEmpty
              ? message.authorUserId == widget.currentUserId
              : message.isMe;
      final date = DateTime.tryParse(message.createdAt)?.toLocal();
      final edited = DateTime.tryParse(message.editedAt ?? '')?.toLocal();
      final rawAuthor = isMe ? 'You' : (message.authorName?.trim() ?? '');
      final displayAuthor = (rawAuthor.isEmpty ||
              rawAuthor == message.authorUserId ||
              rawAuthor.startsWith('usr_'))
          ? (isMe ? 'You' : 'Member')
          : rawAuthor;
      return _DiscussionItem(
          id: message.id,
          author: displayAuthor,
          authorId: message.authorUserId,
          date: date,
          text: message.body,
          sentAt: date == null ? null : _chatTimestamp(date),
          editedAt: edited == null ? null : _chatTimestamp(edited),
          isMe: isMe);
    }).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showEmpty = messages.isEmpty &&
        state.error == null &&
        (!state.isFetching || state.hasData);
    final empty = showEmpty
        ? Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Share context, decisions, or questions with your team below.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ),
          )
        : null;

    if (widget.isDraft) return _discussionComposer(twoPane: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
            child: TimelineScrollOverlay(
                key: ValueKey('chat-scroll-overlay-${widget.thread.id}'),
                controller: _chatHistoryController,
                onFollowLatest: () {
                  _chatIncomingAnchor.reset();
                  _followChat = true;
                },
                child: AxTimelineContainer(
                  scrollKey: const ValueKey('chat-history-scroll'),
                  controller: _chatHistoryController,
                  headerSlivers: [
                    if (state.olderCursor != null)
                      SliverToBoxAdapter(
                        child: TextButton(
                          onPressed:
                              state.loadingOlder ? null : _loadOlderDiscussion,
                          child: Text(state.loadingOlder
                              ? 'Loading older messages…'
                              : 'Load older messages'),
                        ),
                      ),
                    if (state.error != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Text.rich(
                            TextSpan(
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 13,
                              ),
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
                                              onError:
                                                  (Object _, StackTrace __) {}),
                                      child: Text(
                                        'Retry Chat sync',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error,
                                          decoration: TextDecoration.underline,
                                          decorationColor: Theme.of(context)
                                              .colorScheme
                                              .error,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
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
                                              'Chat could not synchronize: ${state.error}'),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (!state.hasData && state.isFetching)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Loading Chat…'),
                        ),
                      ),
                  ],
                  itemCount: messages.length,
                  empty: empty,
                  separatorBuilder: (_, index) => SizedBox(
                    height:
                        _continuesDiscussionGroup(messages, index + 1) ? 4 : 12,
                  ),
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final index = messages
                        .indexWhere((message) => message.id == key.value);
                    return index < 0 ? null : index;
                  },
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return KeyedSubtree(
                      key: ValueKey(message.id),
                      child: KeyedSubtree(
                        key: _chatIncomingAnchor.keyFor(message.id),
                        child: MessageDayBoundary(
                          date: message.date,
                          previousDate:
                              index == 0 ? null : messages[index - 1].date,
                          child: _DiscussionMessageBubble(
                            item: message,
                            grouped: _continuesDiscussionGroup(messages, index),
                            onCopy: () {
                              Clipboard.setData(
                                  ClipboardData(text: message.text));
                            },
                            onEdit: (newText) =>
                                _editDiscussion(message.id, newText),
                            onDelete: () => _deleteDiscussion(message.id),
                          ),
                        ),
                      ),
                    );
                  },
                ))),
        const SizedBox(height: 16),
        _discussionComposer(twoPane: twoPane),
      ],
    );
  }

  Widget _discussionComposer({bool twoPane = false}) => MarkdownComposer(
        controller: _discussionController,
        hintText: 'Write a message...',
        chatStyle: true,
        enabled: !widget.draftBusy &&
            widget.space.effectivePermissions.chat &&
            (!widget.isDraft ||
                widget.space.effectivePermissions.manageOwnThreads),
        onSend: _sendDiscussion,
        sendEnabled: !_draftSubmitting && !widget.draftBusy,
        showMarkdownControls: !twoPane,
        showMarkdownControlsInSuffix: !twoPane,
        showSendInSuffix: !twoPane,
        sendInFormattingToolbar: twoPane,
      );

  Widget _work(BuildContext context) => widget.isDraft
      ? ValueListenableBuilder<ThreadComposerPresentationSnapshot>(
          valueListenable: _presentation.composer,
          builder: (context, _, __) => _workComposer().controls(context))
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
                child: TimelineScrollOverlay(
                    key: ValueKey('work-scroll-overlay-${widget.thread.id}'),
                    controller: _workHistoryController,
                    onFollowLatest: () {
                      _workIncomingAnchor.reset();
                      _followWork = true;
                    },
                    child: ListenableBuilder(
                        listenable: _workRealtime,
                        builder: (context, _) => ValueListenableBuilder<
                                ThreadWorkPresentationSnapshot?>(
                            valueListenable: _presentation.work,
                            builder: (context, snapshot, _) {
                              return _workComposer().history(context);
                            })))),
            const SizedBox(height: 16),
            ValueListenableBuilder<ThreadComposerPresentationSnapshot>(
                valueListenable: _presentation.composer,
                builder: (context, _, __) => _workComposer().controls(context)),
          ],
        );

  _WorkComposer _workComposer() => _WorkComposer(
        requestController: _requestController,
        historyController: _workHistoryController,
        incomingAnchor: _workIncomingAnchor,
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
        activityStore: _workActivityStore,
        realtimeStatus: _workRealtime.displayStatus,
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
        hasOlder: _workPresentation.olderCursor != null,
        loadingOlder: _workPresentation.loadingOlder,
        onLoadOlder: _loadOlderWorkHistory,
        onReportIssue: widget.dataSource == null ? null : _reportIssue,
        reportedIssues: _reportedIssues,
        reportingIssueIds: _reportingIssueIds,
        issueReportErrors: _issueReportErrors,
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
        usageController: _workerUsage,
      );
}

part of '../spaces_pages.dart';

class ThreadPage extends StatefulWidget {
  /// Clears the session-wide Work queues so tests start independent.
  @visibleForTesting
  static void resetWorkQueues() {
    _ThreadPageState._queuedWorkByThread.clear();
    _ThreadPageState._pausedWorkQueues.clear();
  }

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
    this.initialAiHistoryOpen = false,
    this.onClearConversation,
    this.onClearAiHistory,
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

  /// Opens the read-only AI History panel when the page is created.
  final bool initialAiHistoryOpen;

  /// Deletes the Thread's Chat messages, including archived AI answers.
  final Future<void> Function()? onClearConversation;

  /// Deletes AI History and resets Worker session context; completed answers
  /// are archived into the Conversation.
  final Future<void> Function()? onClearAiHistory;

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
  bool? _paneAwaitingReveal;
  AxThreadViewState? _pendingThreadViewState;
  String? _selectionUpdatedAt;
  Map<String, dynamic>? _lastRemoteViewState;
  final _requestController = TextEditingController();
  bool _requestHistoryOpen = false;
  int _requestHistoryDirection = 1;

  /// Work messages sent while a request was processing, per user and Thread,
  /// oldest first. Kept for the app session so leaving the Thread page and
  /// returning keeps the queue; see `_dispatchQueuedWork`.
  static final _queuedWorkByThread = <String, List<_QueuedWorkMessage>>{};
  static final _pausedWorkQueues = <String>{};
  bool _dispatchingQueuedWork = false;
  String get _workQueueKey =>
      '${widget.currentUserId ?? ''}|${widget.thread.id}';
  bool get _workQueuePaused => _pausedWorkQueues.contains(_workQueueKey);
  set _workQueuePaused(bool paused) => paused
      ? _pausedWorkQueues.add(_workQueueKey)
      : _pausedWorkQueues.remove(_workQueueKey);
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

  /// The saved Thread tab now selects the conversation composer target:
  /// index 0 sends a Chat message, index 1 asks AI (a Work Request).
  bool get _askAiMode => _tabController.index == 1;

  /// Read-only AI History (the former Work timeline) beside or, on narrow
  /// layouts, instead of the conversation.
  late bool _aiHistoryOpen = widget.initialAiHistoryOpen;
  // AI History stays mounted once opened so switching keeps both lists and
  // their scroll positions; a positioned pane is revealed without hiding.
  late bool _aiHistoryMounted = _aiHistoryOpen;
  bool _chatPositioned = false;
  bool _workPositioned = false;

  Future<void> _confirmClear({required bool history}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        constraints: ConclaveDialogStyle.small,
        title:
            Text(history ? 'Clear AI History' : 'Clear Conversation History'),
        content: Text(history
            ? 'Delete all AI requests, activity and diagnostics, and reset the '
                'Workers\' session context? Completed AI answers stay in the '
                'Conversation. This action cannot be undone.'
            : 'Delete all Conversation messages and AI History, including '
                'saved AI answers, activity and diagnostics, and reset the '
                'Workers\' session context? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await (history ? widget.onClearAiHistory : widget.onClearConversation)
        ?.call();
  }

  void _setAiHistoryOpen(bool open) {
    if (open == _aiHistoryOpen) return;
    if (open ? _workPositioned : _chatPositioned) {
      setState(() => _aiHistoryOpen = open);
      final controller = open ? _workHistoryController : _chatHistoryController;
      if (open ? _followWork : _followChat) _scheduleFollowLatest(controller);
      return;
    }
    setState(() {
      _aiHistoryMounted |= open;
      _aiHistoryOpen = open;
      // Lay out and position the destination without painting intermediate
      // scroll offsets. The follow callback reveals it after its final pass.
      _paneAwaitingReveal = open;
      _threadViewReady = false;
      if (open) _openWorkPending = true;
      if (!open) _openChatPending = true;
    });
    _scheduleFollowLatest(
        open ? _workHistoryController : _chatHistoryController);
  }

  void _invalidateInteractionCallbacks() {
    _interactionGeneration++;
    _paneAwaitingReveal = null;
    _chatIncomingAnchor.reset(clearKeys: true);
    _workIncomingAnchor.reset(clearKeys: true);
    _previousChatIds = null;
    _previousWorkReplies = null;
    _chatFollowScheduled = false;
    _workFollowScheduled = false;
    _openChatPending = _openWorkPending = true;
    _chatPositioned = _workPositioned = false;
    _lastMaxExtent.clear();
  }

  List<(String, Object)> _chatSequence() => [
        for (final message in _chatPresentation.messages)
          (message.id, message.id),
      ];

  /// Work reads as request/response items so a response arriving later in an
  /// already-seen request counts as new.
  List<(String, Object)> _workSequence() {
    final items = <(String, Object)>[];
    for (final request in _afterAiHistoryClear(_workPresentation.requests)) {
      items.add(('${request.id}|request', (request.id, 'request')));
      if (_workResponseText(request) != null || request.status == 'failed') {
        items.add(('${request.id}|response', (request.id, 'response')));
      }
    }
    return items;
  }

  /// A reader at the latest content keeps following it: a new item scrolls
  /// the timeline to its end. Callers only invoke this while following.
  void _anchorIncoming(AxTimelineFollowAnchor anchor,
      ScrollController controller, List<Object> sequence, Object target) {
    anchor.reset();
    _jumpToLatest(controller);
  }

  final _lastMaxExtent = <bool, double>{};

  /// Keeps a following timeline pinned to its end while content grows in
  /// place, such as a Worker's in-progress output or a row settling height.
  /// Only growth follows, so programmatic jumps elsewhere are left alone.
  bool _onTimelineMetricsChanged(ScrollMetricsNotification notification) {
    for (final (isWork, controller) in [
      (false, _chatHistoryController),
      (true, _workHistoryController),
    ]) {
      if (!(isWork ? _followWork : _followChat) ||
          (isWork ? _openWorkPending : _openChatPending) ||
          (isWork ? _workIncomingAnchor : _chatIncomingAnchor).active ||
          !controller.hasClients ||
          !controller.position.hasContentDimensions) {
        continue;
      }
      final position = controller.position;
      final previous = _lastMaxExtent[isWork];
      _lastMaxExtent[isWork] = position.maxScrollExtent;
      if (previous != null &&
          position.maxScrollExtent > previous + 0.5 &&
          previous - position.pixels <= 24) {
        _jumpToLatest(controller);
      }
    }
    return false;
  }

  bool _tabActive(bool isWork) => isWork ? _aiHistoryOpen : true;

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
      if (_tabActive(isWork) && _threadViewStateRestored) {
        if (isWork) {
          _workPositioned = true;
        } else {
          _chatPositioned = true;
        }
      }
      if (_paneAwaitingReveal == isWork) {
        setState(() {
          _paneAwaitingReveal = null;
          _threadViewReady = true;
        });
      }
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
                List<Object>.of(_conversationIds()), id);
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
              _followChat = true;
              _chatIncomingAnchor.reset();
              _jumpToLatest(_chatHistoryController);
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
    _followWorkInConversation(state, previous);
    _scheduleFollowLatest(_chatHistoryController);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => mounted ? _dispatchQueuedWork() : null);
  }

  /// Conversation item IDs in display order; see [_mergeWorkIntoConversation].
  List<String> _conversationIds() {
    final groups = <(DateTime?, List<String>)>[
      for (final message in _chatPresentation.messages)
        (DateTime.tryParse(message.createdAt)?.toLocal(), [message.id]),
      for (final request in _workPresentation.requests)
        (
          DateTime.tryParse(request.createdAt)?.toLocal(),
          ['work-${request.id}-request', 'work-${request.id}-answer'],
        ),
    ];
    final indexed = groups.indexed.toList()..sort(_byConversationTime);
    return [for (final entry in indexed) ...entry.$2.$2];
  }

  static int _byConversationTime(
      (int, (DateTime?, Object)) a, (int, (DateTime?, Object)) b) {
    final left = a.$2.$1, right = b.$2.$1;
    final byDate = left == null || right == null ? 0 : left.compareTo(right);
    return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
  }

  /// Work Requests are conversation entries too. The first Work page keeps a
  /// following reader at the latest content; later requests and answers are
  /// revealed from their opening like incoming Chat messages.
  void _followWorkInConversation(
      ThreadWorkPresentationSnapshot state, Map<String, Object?>? previous) {
    if (!state.hasData || !_followChat) return;
    if (previous == null) {
      if (!_chatIncomingAnchor.active) _jumpToLatest(_chatHistoryController);
      return;
    }
    for (final request in state.requests) {
      final reply = _previousWorkReplies?[request.id];
      final String target;
      if (!previous.containsKey(request.id)) {
        target = 'work-${request.id}-request';
      } else if (reply != null && reply != previous[request.id]) {
        target = 'work-${request.id}-answer';
      } else {
        continue;
      }
      _anchorIncoming(_chatIncomingAnchor, _chatHistoryController,
          List<Object>.of(_conversationIds()), target);
      return;
    }
  }

  void _onWorkActivityChanged() {
    _scheduleFollowLatest(_workHistoryController);
    if (_followChat && !_openChatPending) _jumpToLatest(_chatHistoryController);
    if (_followWork && !_openWorkPending) _jumpToLatest(_workHistoryController);
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

  final _composerInputHeight = ComposerInputHeight();
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

  /// AI History starts after its last clear; the Conversation keeps every
  /// request through [_workTimeline].
  List<AxWorkRequest> get _aiHistoryTimeline =>
      _afterAiHistoryClear(_workTimeline);

  List<AxWorkRequest> _afterAiHistoryClear(List<AxWorkRequest> requests) {
    final clearedAt = DateTime.tryParse(
        _workHistoryCache.aiHistoryClearedAt(widget.thread.id) ?? '');
    if (clearedAt == null) return requests;
    return requests
        .where((request) =>
            DateTime.tryParse(request.createdAt)?.isAfter(clearedAt) ?? true)
        .toList();
  }

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
      selectionUpdatedAt:
          pending != null ? pending.selectionUpdatedAt : _selectionUpdatedAt,
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
        'selectionUpdatedAt': state.selectionUpdatedAt,
      };

  AxThreadViewState? _withRemoteViewState(AxThreadViewState? local) =>
      AxThreadViewState.withRemote(local, widget.thread.viewState);

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

  /// An explicit choice supersedes a saved selection still waiting for the
  /// catalogs; otherwise saves keep the old values and the late restore
  /// overwrites the user's choice.
  void _markSelectionChangedByUser() {
    final pending = _pendingThreadViewState;
    if (pending != null) {
      if (pending.workflowReference != null &&
          _availableWorkflows
              .any((item) => item.reference == pending.workflowReference)) {
        _workflow = pending.workflowReference!;
      }
      _pendingThreadViewState = null;
    }
    _selectionUpdatedAt = DateTime.now().toUtc().toIso8601String();
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

  /// Both stores read synchronously, so the saved view is applied before the
  /// Thread's first frame instead of after an extra async round trip.
  void _restoreThreadViewState() {
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
    final saved = _withRemoteViewState(_threadViewStateStore.loadSync(
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
      // Never overwrite non-empty input or an active edit session with the
      // persisted draft.
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
      _selectionUpdatedAt = saved.selectionUpdatedAt;
      _pendingThreadViewState = saved;
      final targetIndex = saved.tabIndex.clamp(0, _tabController.length - 1);
      if (_tabController.index != targetIndex) {
        _tabController.index = targetIndex;
      }
      _reconcilePendingThreadViewState();
    }
    // Callers run in initState/didUpdateWidget, which always rebuild next.
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
    _restoreThreadViewState();
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
      _composerInputHeight.reset();
      _discussionController.clear();
      _requestController.clear();
      _workExecutionSelection = {};
      _selectionUpdatedAt = null;
      _workflow = '';
      _followWork = _followChat = true;
      _chatSeenId = _workSeenId = null;
      _openChatPending = _openWorkPending = true;
      _chatPositioned = _workPositioned = false;
      _aiHistoryMounted = _aiHistoryOpen;
      // Activity is keyed by assignment, so it is kept: returning to a Thread
      // shows its earlier operations immediately while details reload.
      _cancelTerminalActivityChecks();
      _restoreThreadViewState();
    } else if (oldWidget.currentUserId != widget.currentUserId) {
      _restoreThreadViewState();
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
          // The Conversation was cleared by another session: Chat and all
          // Work are gone. Drop retained data, then reconcile.
          _discussionCache.resetHistory(widget.thread.id);
          _workHistoryCache.resetHistory(widget.thread.id);
          unawaited(_discussionCache
              .synchronize(widget.thread.id, reconcileNewest: true)
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
          unawaited(_refreshWorkTimeline()
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        } else if (type == 'thread.work_cleared') {
          // AI History moved its cutoff; Work itself is kept, so refreshing
          // brings the new cutoff without discarding the Conversation.
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
    _composerInputHeight.dispose();
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
            _paneAwaitingReveal == null &&
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
        final historyOpen = !widget.isDraft && _aiHistoryOpen;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        // Same active-icon color as the composer's Message / Ask AI switch.
        final activeTabIcon = isDark
            ? ConclaveColors.focusBorderDark
            : ConclaveColors.primaryForegroundLight;
        Widget header(String title, {required bool history}) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 46,
                  child: Row(children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          TextButton.icon(
                            key: ValueKey(history
                                ? 'ai-history-conversation'
                                : 'conversation-tab'),
                            onPressed: () => _setAiHistoryOpen(false),
                            style: TextButton.styleFrom(
                              foregroundColor: history
                                  ? ConclaveColors.textSecondary(isDark)
                                  : ConclaveColors.textPrimary(isDark),
                            ),
                            icon: Icon(Icons.chat_bubble_outline_rounded,
                                size: 18,
                                color: history ? null : activeTabIcon),
                            label: const Text('Conversation'),
                          ),
                          if (!widget.isDraft)
                            TextButton.icon(
                              key: ValueKey(history
                                  ? 'ai-history-tab'
                                  : 'ai-history-toggle'),
                              onPressed: () => _setAiHistoryOpen(true),
                              style: TextButton.styleFrom(
                                foregroundColor: history
                                    ? ConclaveColors.textPrimary(isDark)
                                    : ConclaveColors.textSecondary(isDark),
                              ),
                              icon: Icon(Icons.history_rounded,
                                  size: 18,
                                  color: history ? activeTabIcon : null),
                              label: const Text('AI History'),
                            ),
                        ]),
                      ),
                    ),
                    if (!widget.isDraft &&
                        (history
                                ? widget.onClearAiHistory
                                : widget.onClearConversation) !=
                            null)
                      IconButton(
                        key: ValueKey(history
                            ? 'clear-ai-history'
                            : 'clear-conversation-history'),
                        tooltip: history
                            ? 'Clear AI History'
                            : 'Clear Conversation History',
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        onPressed: () => _confirmClear(history: history),
                      ),
                  ]),
                ),
                const Divider(height: 1, thickness: 1),
                const SizedBox(height: 16),
              ],
            );
        Widget pane(String name, Widget content, {bool history = false}) =>
            Padding(
                key: ValueKey('thread-$name-padding'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  key: ValueKey('thread-$name-pane'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header(name, history: history),
                    if (widget.isDraft) content else Expanded(child: content),
                  ],
                ));
        final conversation = pane('Conversation',
            _discuss(context, twoPane: constraints.maxWidth >= 1000));
        final Widget content = Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: widget.isDraft
              ? conversation
              : IndexedStack(
                  key: const ValueKey('thread-panes'),
                  index: historyOpen ? 1 : 0,
                  sizing: StackFit.expand,
                  children: [
                    conversation,
                    if (_aiHistoryMounted || historyOpen)
                      pane('AI History', _work(context), history: true)
                    else
                      const SizedBox.shrink(),
                  ],
                ),
        ));
        return IgnorePointer(
          ignoring: !_threadViewReady,
          child: ExcludeSemantics(
            excluding: !_threadViewReady,
            child: Opacity(
              key: const ValueKey('thread-view-visibility'),
              opacity: _threadViewReady ? 1 : 0,
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: _onTimelineMetricsChanged,
                child: content,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _discuss(BuildContext context, {bool twoPane = false}) =>
      ListenableBuilder(
        key: const ValueKey('conversation-timeline'),
        listenable: Listenable.merge(
            [_presentation.chat, _presentation.work, _workRealtime]),
        builder: (context, _) => _discussionBody(
          context,
          _presentation.chat.value ?? _chatPresentation,
          twoPane: twoPane,
        ),
      );

  // Rebuilt only when messages, Work requests or the viewer change, not on
  // every realtime activity tick or follow/reveal pass.
  (Object, Object, String?, bool, List<_DiscussionItem>)? _conversationCache;

  List<_DiscussionItem> _conversationItems(
      ThreadChatPresentationSnapshot state) {
    final cached = _conversationCache;
    final requests = _workTimeline;
    if (cached != null &&
        identical(cached.$1, state) &&
        identical(cached.$2, requests) &&
        cached.$3 == widget.currentUserId &&
        cached.$4 == widget.isDraft) {
      return cached.$5;
    }
    final items = state.messages.map((message) {
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
      // An archived AI answer is the Worker speaking, not its requester.
      final worker = message.workerDisplayName?.trim();
      final answer = message.isAiAnswer;
      return _DiscussionItem(
          id: message.id,
          author: answer
              ? (worker == null || worker.isEmpty ? 'AI' : worker)
              : displayAuthor,
          authorId: answer
              ? 'ai:${message.workRequestId ?? message.id}'
              : message.authorUserId,
          date: date,
          text: message.body,
          sentAt: date == null ? null : _chatTimestamp(date),
          editedAt: edited == null ? null : _chatTimestamp(edited),
          editedDate: edited,
          isMe: isMe && !answer,
          aiKind: message.isAiEntry ? message.kind : null);
    }).toList();
    if (!widget.isDraft) _mergeWorkIntoConversation(items);
    _conversationCache =
        (state, requests, widget.currentUserId, widget.isDraft, items);
    return items;
  }

  Widget _discussionBody(
      BuildContext context, ThreadChatPresentationSnapshot state,
      {bool twoPane = false}) {
    final messages = _conversationItems(state);
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
                const Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 42,
                  color: ConclaveColors.neutral,
                ),
                const SizedBox(height: 12),
                Text(
                  'No chat messages yet',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: ConclaveColors.textSecondary(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Share context, decisions, or questions with your team below.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: ConclaveColors.neutral,
                  ),
                ),
              ],
            ),
          )
        : null;

    if (widget.isDraft) return _conversationComposer(twoPane: true);
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
                  itemId: (index) => messages[index].id,
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
                          child: message.workRequest != null
                              ? _workComposer().requestCard(
                                  context, message.workRequest!,
                                  responseAnchorKey: _chatIncomingAnchor.keyFor(
                                      'work-${message.workRequest!.id}-answer'))
                              : _DiscussionMessageBubble(
                                  item: message,
                                  grouped: _continuesDiscussionGroup(
                                      messages, index),
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
        _conversationComposer(twoPane: twoPane),
      ],
    );
  }

  /// One conversation: Work Requests still in Work history appear between
  /// Chat messages by request time, each followed by its answer or status.
  void _mergeWorkIntoConversation(List<_DiscussionItem> messages) {
    final requests = _workTimeline;
    if (requests.isEmpty) return;
    final groups = <(DateTime?, List<_DiscussionItem>)>[
      for (final message in messages) (message.date, [message]),
      for (final request in requests)
        (
          DateTime.tryParse(request.createdAt)?.toLocal(),
          [_workConversationItem(request)],
        ),
    ];
    final indexed = groups.indexed.toList()..sort(_byConversationTime);
    messages
      ..clear()
      ..addAll(indexed.expand((entry) => entry.$2.$2));
  }

  /// Message / Ask AI switch stacked in the composer's 32px left rail.
  Widget _composerModeControls() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Indicate the active mode with icon color only in both themes.
    final selectedForeground = dark
        ? ConclaveColors.focusBorderDark
        : ConclaveColors.primaryForegroundLight;
    Widget toggle(bool askAi, String tooltip, IconData icon) {
      final selected = _askAiMode == askAi;
      return IconButton(
        key: ValueKey('composer-mode-${askAi ? 'ai' : 'message'}'),
        tooltip: tooltip,
        isSelected: selected,
        onPressed: selected
            ? null
            : () => _updateState(() => _tabController.index = askAi ? 1 : 0),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
        ),
        icon: Icon(icon,
            semanticLabel: tooltip,
            size: 16,
            color: selected
                ? selectedForeground
                : Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }

    return Semantics(
      key: const ValueKey('conversation-composer-mode'),
      container: true,
      label: _askAiMode ? 'Ask AI mode' : 'Message mode',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          toggle(false, 'Message', Icons.chat_bubble_outline_rounded),
          const SizedBox(height: 4),
          toggle(true, 'Ask AI', Icons.auto_awesome_rounded),
        ],
      ),
    );
  }

  Widget _conversationComposer({bool twoPane = false}) => _askAiMode
      ? ValueListenableBuilder<ThreadComposerPresentationSnapshot>(
          valueListenable: _presentation.composer,
          builder: (context, _, __) => _workComposer().controls(context))
      : _discussionComposer(twoPane: twoPane);

  Widget _discussionComposer({bool twoPane = false}) => MarkdownComposer(
        leadingControls: _composerModeControls(),
        inputHeight: _composerInputHeight,
        showControlTooltips: false,
        controller: _discussionController,
        hintText: 'Write a message...',
        chatStyle: true,
        enabled: !widget.draftBusy &&
            widget.space.effectivePermissions.chat &&
            (!widget.isDraft ||
                widget.space.effectivePermissions.manageOwnThreads),
        onSend: _sendDiscussion,
        sendEnabled: !_draftSubmitting && !widget.draftBusy,
        twoRowLayout: true,
        maxLines: 6,
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
          ],
        );

  _WorkComposer _workComposer() => _WorkComposer(
        leadingControls: _composerModeControls(),
        inputHeight: _composerInputHeight,
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
        workTimeline: _aiHistoryTimeline,
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
          _updateState(() {
            _markSelectionChangedByUser();
            _workExecutionSelection = {
              ..._workExecutionSelection,
              ...selection
            };
          });
          _scheduleThreadViewStateSave();
        },
        onRemoveAttachment: (index) => _updateState(() {
          _workAttachments.removeAt(index);
        }),
        hasOlder: _workPresentation.olderCursor != null,
        loadingOlder: _workPresentation.loadingOlder,
        onLoadOlder: _loadOlderWorkHistory,
        onReportIssue: widget.dataSource == null ? null : _reportIssue,
        reportedIssues: _reportedIssues,
        reportingIssueIds: _reportingIssueIds,
        issueReportErrors: _issueReportErrors,
        onRetryStep: widget.dataSource == null ? null : _retryWorkRequestStep,
        onCancelRun: widget.dataSource == null ? null : _cancelWorkRequest,
        onHistoryNavigate: _openRequestHistory,
        historyPrompts: _requestHistoryOpen ? _requestHistoryPrompts : null,
        historyOpenDirection: _requestHistoryDirection,
        queuedMessages: widget.isDraft ? const [] : List.of(_workQueue),
        queuePaused: _workQueuePaused,
        onQueuedEdit: _editQueuedWork,
        onQueuedRemove: _removeQueuedWork,
        onQueuedSendNow: (message) => unawaited(_sendQueuedWorkNow(message)),
        onHistorySelected: _selectHistoryPrompt,
        onHistoryClosed: _closeRequestHistory,
        onWorkflowChanged: (value) {
          _updateState(() {
            _markSelectionChangedByUser();
            _workflow = value;
            _workExecutionSelection = {};
          });
          _scheduleThreadViewStateSave();
        },
        onRun: _runWork,
        usageController: _workerUsage,
      );
}

part of '../spaces_pages.dart';

extension _ThreadActions on _ThreadPageState {
  Future<void> _runWork() async {
    final text = _requestController.text;
    final submit = widget.onRunWork;
    if (!_canExecute ||
        (text.trim().isEmpty && _workAttachments.isEmpty) ||
        (submit == null && widget.onRunWorkWithSelection == null) ||
        _submittingWork) {
      return;
    }
    if (widget.isDraft) {
      final requestText = text.trim().isEmpty
          ? 'Please use the attached inputs to complete the request.'
          : text;
      final inputs = List<Map<String, dynamic>>.from(_workAttachments);
      final selection = Map<String, dynamic>.from(_workExecutionSelection);
      _updateState(() {
        _draftSubmitting = true;
        _workSubmitError = null;
      });
      try {
        await widget.onRunWorkWithSelection!(requestText,
            _effectiveWorkflow.split(':').first, inputs, '', selection);
      } catch (error) {
        if (mounted) _updateState(() => _workSubmitError = error.toString());
      } finally {
        if (mounted) _updateState(() => _draftSubmitting = false);
      }
      return;
    }
    final message = _QueuedWorkMessage(
      text: text,
      attachments: List<Map<String, dynamic>>.from(_workAttachments),
      executionSelection: Map<String, dynamic>.from(_workExecutionSelection),
      workflow: _effectiveWorkflow,
    );
    _updateState(() {
      _workSubmitError = null;
      _workAttachments = [];
    });
    _requestController.clear();
    // While a request is processing, or earlier messages are still waiting,
    // the message waits its turn; [_dispatchQueuedWork] sends it later.
    if (_activeWorkRequests.isNotEmpty || _workQueue.isNotEmpty) {
      _updateState(() {
        _workQueue.add(message);
        _workQueuePaused = false;
      });
      _dispatchQueuedWork();
      return;
    }
    await _submitWorkMessage(message);
  }

  /// Saved requests of this Thread that are still processing.
  List<AxWorkRequest> get _activeWorkRequests => _workTimeline
      .where((request) =>
          !request.id.startsWith('local-') &&
          const {'queued', 'running', 'waiting'}.contains(request.status))
      .toList(growable: false);

  /// Messages waiting for this Thread's active request to finish.
  List<_QueuedWorkMessage> get _workQueue =>
      _ThreadPageState._queuedWorkByThread.putIfAbsent(_workQueueKey, () => []);

  /// Sends the next queued message once nothing is processing. A failed send
  /// pauses the queue until the user sends or edits a message.
  void _dispatchQueuedWork() {
    if (widget.isDraft ||
        _dispatchingQueuedWork ||
        _workQueuePaused ||
        _submittingWork ||
        // Until this Thread's requests are loaded, a processing request may be
        // missing from the timeline, and the queue would be sent too early.
        !_workPresentation.hasData ||
        _workPresentation.isFetching ||
        _workQueue.isEmpty ||
        _activeWorkRequests.isNotEmpty) {
      return;
    }
    final threadId = widget.thread.id;
    final message = _workQueue.first;
    _dispatchingQueuedWork = true;
    _updateState(() => _workQueue.removeAt(0));
    _followLatestWork();
    unawaited(_submitWorkMessage(message, fromQueue: true).whenComplete(() {
      if (mounted && widget.thread.id == threadId) _followLatestWork();
      _dispatchingQueuedWork = false;
      if (mounted && widget.thread.id == threadId) {
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => mounted ? _dispatchQueuedWork() : null);
      }
    }));
  }

  /// Cancels the processing request(s) and sends the queued message now.
  Future<void> _sendQueuedWorkNow(_QueuedWorkMessage message) async {
    final active = _activeWorkRequests;
    if (active.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          constraints: ConclaveDialogStyle.small,
          title: const Text('Cancel previous request?'),
          content: Text(active.length == 1
              ? 'A request is still processing. Cancel it and send this request instead?'
              : '${active.length} requests are still processing. Cancel them and send this request instead?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep processing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Cancel and send'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (!_workQueue.contains(message)) return;
    _dispatchingQueuedWork = true;
    try {
      for (final request in active) {
        final cancelled = await _cancelWorkRequest(
          request.id,
          showFeedback: false,
        );
        if (!cancelled || !mounted) return;
      }
      _updateState(() {
        _workQueue.remove(message);
        _workQueuePaused = false;
      });
      _followLatestWork();
      await _submitWorkMessage(message, fromQueue: true);
      if (mounted) _followLatestWork();
    } finally {
      _dispatchingQueuedWork = false;
      if (mounted) _dispatchQueuedWork();
    }
  }

  /// A request sent from the queue scrolls the conversation to its newest
  /// content, even when the reader had scrolled up.
  void _followLatestWork() {
    _followWork = true;
    _workIncomingAnchor.reset();
    _jumpToLatest(_workHistoryController);
    _followChat = true;
    _chatIncomingAnchor.reset();
    _jumpToLatest(_chatHistoryController);
  }

  void _removeQueuedWork(_QueuedWorkMessage message) =>
      _updateState(() => _workQueue.remove(message));

  /// Moves a queued message into the composer for editing. A draft already in
  /// the composer takes its place in the queue, so nothing is lost.
  void _editQueuedWork(_QueuedWorkMessage message) {
    final index = _workQueue.indexOf(message);
    if (index < 0) return;
    final draft = _requestController.text;
    final draftAttachments = _workAttachments;
    _updateState(() {
      if (draft.trim().isNotEmpty || draftAttachments.isNotEmpty) {
        _workQueue[index] = _QueuedWorkMessage(
          text: draft,
          attachments: draftAttachments,
          executionSelection:
              Map<String, dynamic>.from(_workExecutionSelection),
          workflow: _effectiveWorkflow,
        );
      } else {
        _workQueue.removeAt(index);
      }
      _workAttachments = List.of(message.attachments);
      _workQueuePaused = false;
    });
    _requestController.value = TextEditingValue(
      text: message.text,
      selection: TextSelection.collapsed(offset: message.text.length),
    );
  }

  Future<void> _submitWorkMessage(_QueuedWorkMessage message,
      {bool fromQueue = false}) async {
    final submit = widget.onRunWork;
    final text = message.text;
    final requestText = text.trim().isEmpty
        ? 'Please use the attached inputs to complete the request.'
        : text;
    final attachments = message.attachments;
    final executionSelection = message.executionSelection;
    final workflowId = message.workflow.split(':').first;
    final workflowVersion =
        int.tryParse(message.workflow.split(':v').last) ?? 1;
    final threadId = widget.thread.id;
    final queueKey = _workQueueKey;
    final workCache = _workHistoryCache;
    final workflowName = _currentWorkflows
            .where((w) => w.id == workflowId)
            .map((w) => w.name)
            .firstOrNull ??
        workflowId;
    try {
      await workCache.createRequest(threadId,
          prompt: requestText,
          workflowId: workflowId,
          workflowVersion: workflowVersion,
          workflowName: workflowName,
          requestedByUserId: widget.currentUserId,
          attachments: attachments,
          executionSelection: executionSelection,
          execute: (prompt, workflow, inputs, key) => submit == null
              ? throw StateError('Work submission is unavailable')
              : submit(prompt, workflow, inputs, key),
          executeWithSelection: widget.onRunWorkWithSelection == null
              ? null
              : (prompt, workflow, inputs, key, selection) =>
                  widget.onRunWorkWithSelection!(
                      prompt, workflow, inputs, key, selection));
    } catch (error) {
      if (fromQueue &&
          error is! AxMutationSuperseded &&
          (!mounted || widget.thread.id != threadId)) {
        // The page was left mid-send: keep the message queued for the return.
        (_ThreadPageState._queuedWorkByThread[queueKey] ??= [])
            .insert(0, message);
        _ThreadPageState._pausedWorkQueues.add(queueKey);
        return;
      }
      if (!mounted ||
          widget.thread.id != threadId ||
          error is AxMutationSuperseded) {
        return;
      }
      _updateState(() {
        if (fromQueue) {
          // Keep the message first in line and wait for the user.
          _workQueue.insert(0, message);
          _workQueuePaused = true;
          return;
        }
        // Authored form data stays in this form; mutation/history state is shared.
        if (_requestController.text.isEmpty) _requestController.text = text;
        if (_workAttachments.isEmpty) _workAttachments = attachments;
      });
    }
  }

  /// Prompts of this Thread's earlier requests, newest first.
  List<String> get _requestHistoryPrompts => [
        for (final request in _workTimeline.reversed)
          if (!request.id.startsWith('local-') &&
              request.prompt.trim().isNotEmpty)
            request.prompt
      ];

  bool _openRequestHistory(int direction) {
    if (_requestHistoryOpen) return true;
    _updateState(() {
      _requestHistoryDirection = direction;
      _requestHistoryOpen = true;
    });
    return true;
  }

  void _closeRequestHistory() {
    if (_requestHistoryOpen) _updateState(() => _requestHistoryOpen = false);
  }

  void _selectHistoryPrompt(String prompt) {
    _requestController.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _closeRequestHistory();
  }

  Future<void> _addWorkFiles() async {
    try {
      final selected = await work_request_files.pickWorkRequestFiles();
      if (_workAttachments.length + selected.length > 10 ||
          selected.any(
              (item) => (item['sizeBytes'] as int? ?? 0) > 2 * 1024 * 1024)) {
        throw const FormatException(
          'Choose up to 10 files, each under 2 MB.',
        );
      }
      if (mounted && selected.isNotEmpty) {
        _updateState(
            () => _workAttachments = [..._workAttachments, ...selected]);
      }
    } on UnsupportedError catch (error) {
      if (mounted) {
        _updateState(() => _workSubmitError = error.message.toString());
      }
    } on FormatException catch (error) {
      if (mounted) {
        _updateState(() => _workSubmitError = error.message.toString());
      }
    }
  }

  Future<void> _refreshWorkTimeline({bool activeOnly = false}) async {
    if (widget.isDraft) return;
    final cache = _workHistoryCache;
    final id = widget.thread.id;
    try {
      await cache.refresh(id, activeOnly: activeOnly);
      // List pages omit activity history. The page-local live projection is
      // cleared on navigation, so restore active requests from their details
      // after the list is available, even before realtime reports healthy.
      // Capture the scope above so a late read cannot refresh another Thread.
      if (!mounted || widget.thread.id != id || _workHistoryCache != cache) {
        return;
      }
      await Future.wait(cache
          .activeIds(id)
          .map((requestId) => cache.refreshRequest(id, requestId)));
      _scheduleIssueReportStatusLoads();
    } catch (_) {
      // Query state retains cached history and exposes the existing retry UI.
    }
  }

  String? _issueAttemptId(AxWorkRequest request) => request.steps
      .where((step) => step.status == 'failed')
      .map((step) => step.assignmentId)
      .whereType<String>()
      .firstOrNull;

  void _scheduleIssueReportStatusLoads() {
    for (final request
        in _workTimeline.where((item) => item.status == 'failed')) {
      final attemptId = _issueAttemptId(request);
      final key = '${request.id}:${attemptId ?? ''}';
      if (_checkedIssueReportKeys.contains(key) ||
          _issueReportLoads.containsKey(key)) {
        continue;
      }
      final future = _loadIssueReportStatus(request, key);
      _issueReportLoads[key] = future;
      unawaited(future.whenComplete(() => _issueReportLoads.remove(key)));
    }
  }

  Future<void> _loadIssueReportStatus(
      AxWorkRequest request, String lookupKey) async {
    final source = widget.dataSource;
    if (source == null) return;
    try {
      final report = await source.loadIssueReport(
        requestId: request.id,
        assignmentId: _issueAttemptId(request),
      );
      if (!mounted || request.id.isEmpty) return;
      if (_reportedIssues.containsKey(request.id) &&
          _checkedIssueReportKeys.contains(lookupKey)) {
        return;
      }
      _updateIssueState(() {
        _checkedIssueReportKeys.add(lookupKey);
        if (report == null) {
          if (_reportedIssueKeys[request.id] == lookupKey) {
            _reportedIssues.remove(request.id);
            _reportedIssueKeys.remove(request.id);
            _issueReportErrors.remove(request.id);
          }
        } else {
          _reportedIssues[request.id] = report;
          _reportedIssueKeys[request.id] = lookupKey;
          _issueReportErrors.remove(request.id);
        }
      });
    } catch (_) {
      // Reporting status is auxiliary; keep the failure action available.
    }
  }

  Future<void> _reportIssue(String requestId) async {
    final source = widget.dataSource;
    if (source == null || _reportingIssueIds.contains(requestId)) return;
    _updateIssueState(() {
      _reportingIssueIds.add(requestId);
      _issueReportErrors.remove(requestId);
    });
    try {
      final report = await source.reportIssue(requestId: requestId);
      if (!mounted) return;
      final request =
          _workTimeline.where((item) => item.id == requestId).firstOrNull;
      final key = request == null
          ? requestId
          : '$requestId:${_issueAttemptId(request) ?? ''}';
      _updateIssueState(() {
        _reportedIssues[requestId] = report;
        _reportedIssueKeys[requestId] = key;
        _checkedIssueReportKeys.add(key);
      });
    } catch (_) {
      if (mounted) {
        _updateIssueState(() => _issueReportErrors[requestId] =
            "Couldn't send the report. Try again.");
      }
    } finally {
      if (mounted) {
        _updateIssueState(() => _reportingIssueIds.remove(requestId));
      }
    }
  }

  Future<void> _loadOlderWorkHistory() async {
    if (_loadingOlderWork) return;
    _loadingOlderWork = true;
    final cache = _workHistoryCache;
    final id = widget.thread.id;
    final controller = _workHistoryController;
    final interactionGeneration = _interactionGeneration;
    final offset = controller.hasClients ? controller.offset : 0.0;
    final extent =
        controller.hasClients ? controller.position.maxScrollExtent : 0.0;
    _followWork = false;
    try {
      await cache.loadOlder(id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            interactionGeneration == _interactionGeneration &&
            widget.thread.id == id &&
            identical(cache, _workHistoryCache) &&
            controller.hasClients) {
          controller.jumpTo(
              (offset + controller.position.maxScrollExtent - extent)
                  .clamp(0.0, controller.position.maxScrollExtent));
        }
      });
    } catch (error) {
      if (mounted && widget.thread.id == id) {
        ScaffoldMessenger.of(context).showNotice(SnackBar(
            content: Text('Failed to load older Work history: $error')));
      }
    } finally {
      _loadingOlderWork = false;
    }
  }

  Future<void> _retryWorkRequestStep(
      String workRequestId, AxWorkRequestStep step) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    var confirmSideEffects = false;
    if (!step.retryAllowed) return;
    if (step.retryRequiresConfirmation) {
      // Cloud saw evidence the provider may already have acted, so repeating
      // the step can repeat its changes. Require an explicit decision.
      final folderExists = step.errorCode == 'space_folder_exists';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          constraints: ConclaveDialogStyle.small,
          title: Text(folderExists ? 'Use existing folder?' : 'Retry anyway?'),
          content: Text(
            folderExists
                ? 'A folder with this Space’s name already exists on your '
                    'Workspace and is not empty. Conclave will not create a '
                    'second folder. Use the existing folder for this Space?'
                : 'The previous execution may already have made changes. '
                    'Retrying can repeat them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(folderExists ? 'Use this folder' : 'Retry anyway'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      confirmSideEffects = true;
    }
    if (!mounted) return;
    String? sessionStrategy;
    if (step.kind == 'implement') {
      final resumeRecommended = const {
        'provider_unavailable',
        'authentication_required',
        'quota_exhausted',
        'worker_not_ready',
        'cli_not_found',
        'unsupported_cli_version',
        'model_not_supported',
        'permission_denied',
        'space_folder_exists',
      }.contains(step.errorCode);
      final recommendation = resumeRecommended
          ? 'The failure looks like it happened before the Worker completed a turn. Resuming is recommended.'
          : 'The failure may have happened after work began. Starting fresh is recommended.';
      sessionStrategy = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Retry request'),
          content: Text(
            '$recommendation\n\nChoose whether to continue with the previous context or start fresh.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'resume'),
              child: Text(
                resumeRecommended
                    ? 'Resume previous session · Recommended'
                    : 'Resume previous session',
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'fresh'),
              child: Text(
                resumeRecommended ? 'Start fresh' : 'Start fresh · Recommended',
              ),
            ),
          ],
        ),
      );
      if (sessionStrategy == null) return;
    }
    try {
      await dataSource.retryWorkRequestStep(
        workRequestId: workRequestId,
        stepKind: step.kind,
        sessionStrategy: sessionStrategy,
        confirmSideEffects: confirmSideEffects,
      );
      if (!mounted) return;
      unawaited(_workHistoryCache
          .refreshRequest(widget.thread.id, workRequestId, supersede: true)
          .catchError((Object _) {}));
      ScaffoldMessenger.of(context).showNotice(
        const SnackBar(content: Text('Retrying your request.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showNotice(
        const SnackBar(
          content:
              Text('Could not retry your request. Check Worker readiness.'),
        ),
      );
    }
  }

  Future<bool> _cancelWorkRequest(
    String workRequestId, {
    bool showFeedback = true,
  }) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return false;
    try {
      await dataSource.cancelWorkRequest(workRequestId: workRequestId);
      final current =
          _workHistoryCache.request(widget.thread.id, workRequestId);
      if (current != null) {
        _workHistoryCache.patchRequest(
          widget.thread.id,
          current.copyWith(status: 'cancelled'),
        );
      }
      if (!mounted) return false;
      unawaited(_workHistoryCache
          .refreshRequest(widget.thread.id, workRequestId, supersede: true)
          .catchError((Object _) {}));
      if (showFeedback) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('Request cancelled.')),
        );
      }
      return true;
    } catch (_) {
      if (!mounted) return false;
      if (showFeedback) {
        ScaffoldMessenger.of(context).showNotice(
          const SnackBar(content: Text('Could not cancel this request.')),
        );
      }
      return false;
    }
  }

  Future<void> _sendDiscussion() async {
    if (!widget.space.effectivePermissions.chat ||
        (widget.isDraft &&
            !widget.space.effectivePermissions.manageOwnThreads)) {
      return;
    }
    final text = _discussionController.text;
    if (text.trim().isEmpty || _draftSubmitting || widget.draftBusy) return;
    if (widget.isDraft) {
      _updateState(() => _draftSubmitting = true);
      try {
        await widget.onSendDraftDiscussion!(text);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showNotice(
              SnackBar(content: Text('Failed to send message: $error')));
        }
      } finally {
        if (mounted) _updateState(() => _draftSubmitting = false);
      }
      return;
    }
    _discussionController.clear();
    final cache = _discussionCache;
    final id = widget.thread.id;
    try {
      await cache.send(id, text,
          userId: widget.currentUserId, userName: widget.currentUserName);
    } catch (error) {
      if (!mounted) return;
      if (_discussionController.text.isEmpty) {
        _discussionController.text = text;
      }
      ScaffoldMessenger.of(context).showNotice(SnackBar(
          content: Text('Failed to save message: $error'),
          backgroundColor: ConclaveColors.error));
    }
  }

  Future<void> _editDiscussion(String messageId, String newText) async {
    final cache = _discussionCache;
    final id = widget.thread.id;
    try {
      await cache.edit(id, messageId, newText);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showNotice(SnackBar(
          content: Text('Failed to update message: $error'),
          backgroundColor: ConclaveColors.error));
    }
  }

  Future<void> _deleteDiscussion(String messageId) async {
    final cache = _discussionCache;
    final id = widget.thread.id;
    try {
      await cache.delete(id, messageId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showNotice(const SnackBar(
          content: Text('Message deleted'), duration: Duration(seconds: 2)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showNotice(SnackBar(
          content: Text('Failed to delete message: $error'),
          backgroundColor: ConclaveColors.error));
    }
  }

  Future<void> _loadOlderDiscussion() async {
    if (_loadingOlderChat) return;
    _loadingOlderChat = true;
    final threadId = widget.thread.id;
    final cache = _discussionCache;
    final controller = _chatHistoryController;
    final interactionGeneration = _interactionGeneration;
    final offset = controller.hasClients ? controller.offset : 0.0;
    final extent =
        controller.hasClients ? controller.position.maxScrollExtent : 0.0;
    _followChat = false;
    try {
      await cache.loadOlder(threadId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            interactionGeneration == _interactionGeneration &&
            widget.thread.id == threadId &&
            identical(cache, _discussionCache) &&
            controller.hasClients) {
          controller.jumpTo(
              (offset + controller.position.maxScrollExtent - extent)
                  .clamp(0.0, controller.position.maxScrollExtent));
        }
      });
    } catch (error) {
      if (!mounted ||
          widget.thread.id != threadId ||
          !identical(cache, _discussionCache)) {
        return;
      }
      ScaffoldMessenger.of(context).showNotice(
          SnackBar(content: Text('Failed to load older messages: $error')));
    } finally {
      _loadingOlderChat = false;
    }
  }

  void _handleThreadArchived(Map<String, dynamic> payload) {
    if (!mounted) return;
    final isArchived = payload['archived'] == true;
    final archivedBy = payload['archivedBy'] as String?;
    final byAnother = archivedBy != null && archivedBy != widget.currentUserId;

    if (isArchived && byAnother) {
      ScaffoldMessenger.of(context).showNotice(
        const SnackBar(
          content: Text('This Thread was archived.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }
}

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
    final activeRequests = _workTimeline
        .where((request) =>
            !request.id.startsWith('local-') &&
            const {'queued', 'running', 'waiting'}.contains(request.status))
        .toList(growable: false);
    if (activeRequests.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Cancel previous request?'),
          content: Text(activeRequests.length == 1
              ? 'A request is still processing. Cancel it and send this request instead?'
              : '${activeRequests.length} requests are still processing. Cancel them and send this request instead?'),
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
      for (final request in activeRequests) {
        final cancelled = await _cancelWorkRequest(
          request.id,
          showFeedback: false,
        );
        if (!cancelled || !mounted) return;
      }
    }
    final requestText = text.trim().isEmpty
        ? 'Please use the attached inputs to complete the request.'
        : text;
    final attachments = List<Map<String, dynamic>>.from(_workAttachments);
    final executionSelection =
        Map<String, dynamic>.from(_workExecutionSelection);
    final workflowId = _effectiveWorkflow.split(':').first;
    final workflowVersion =
        int.tryParse(_effectiveWorkflow.split(':v').last) ?? 1;
    final threadId = widget.thread.id;
    final workCache = _workHistoryCache;
    final workflowName = _currentWorkflows
            .where((w) => w.id == workflowId)
            .map((w) => w.name)
            .firstOrNull ??
        workflowId;
    _updateState(() {
      _workSubmitError = null;
      _workAttachments = [];
    });
    _requestController.clear();
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
      if (mounted && widget.thread.id == threadId) {
        _updateState(() => _workExecutionSelection = {});
      }
    } catch (error) {
      if (!mounted ||
          widget.thread.id != threadId ||
          error is AxMutationSuperseded) {
        return;
      }
      _updateState(() {
        // Authored form data stays in this form; mutation/history state is shared.
        if (_requestController.text.isEmpty) _requestController.text = text;
        if (_workAttachments.isEmpty) _workAttachments = attachments;
      });
    }
  }

  Future<void> _addWorkFiles() async {
    try {
      final selected = await work_request_files.pickWorkRequestFiles();
      final currentBytes = _workAttachments.fold<int>(
        0,
        (sum, item) => sum + (item['sizeBytes'] as int? ?? 0),
      );
      final selectedBytes = selected.fold<int>(
        0,
        (sum, item) => sum + (item['sizeBytes'] as int? ?? 0),
      );
      if (_workAttachments.length + selected.length > 10 ||
          currentBytes + selectedBytes > 1024 * 1024 ||
          selected
              .any((item) => (item['sizeBytes'] as int? ?? 0) > 1024 * 1024)) {
        throw const FormatException(
          'Choose up to 10 files, with each file and the total under 1 MB.',
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

  Future<void> _retryWorkSync() async {
    final cache = _workHistoryCache;
    final id = widget.thread.id;
    final dirty = cache.dirtyIds(id);
    if (dirty.isEmpty) {
      await _refreshWorkTimeline();
      return;
    }
    try {
      await Future.wait(
          dirty.map((requestId) => cache.refreshRequest(id, requestId)));
    } catch (_) {
      /* Individual request errors remain available in query state. */
    }
  }

  Future<void> _refreshWorkTimeline({bool activeOnly = false}) async {
    final cache = _workHistoryCache;
    final id = widget.thread.id;
    try {
      await cache.refresh(id, activeOnly: activeOnly);
    } catch (_) {
      // Query state retains cached history and exposes the existing retry UI.
    }
  }

  Future<void> _loadOlderWorkHistory() async {
    if (_loadingOlderWork) return;
    _loadingOlderWork = true;
    final cache = _workHistoryCache;
    final id = widget.thread.id;
    final controller = _workHistoryController;
    final offset = controller.hasClients ? controller.offset : 0.0;
    final extent =
        controller.hasClients ? controller.position.maxScrollExtent : 0.0;
    _followWork = false;
    try {
      await cache.loadOlder(id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to load older Work history: $error')));
      }
    } finally {
      _loadingOlderWork = false;
    }
  }

  Future<void> _showRunDetails(String workRequestId) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    final details = dataSource.loadWorkRequest(workRequestId: workRequestId);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FutureBuilder<AxWorkRequestStatus>(
        future: details,
        builder: (context, snapshot) {
          final height = MediaQuery.sizeOf(context).height * 0.88;
          if (snapshot.hasError) {
            return SizedBox(
              height: height,
              child:
                  const Center(child: Text('Could not load request details.')),
            );
          }
          if (!snapshot.hasData) {
            return SizedBox(
              height: height,
              child: const Center(child: CircularProgressIndicator()),
            );
          }
          return _WorkRequestDetailsSheet(
            details: snapshot.data!,
            onRetryStep: (step) => _retryWorkRequestStep(
              workRequestId,
              step,
              closeDetails: true,
            ),
            onCancelRun: () => _cancelWorkRequest(
              workRequestId,
              closeDetails: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _retryWorkRequestStep(
      String workRequestId, AxWorkRequestStep step,
      {bool closeDetails = false}) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
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
      );
      if (!mounted) return;
      if (closeDetails) Navigator.of(context).pop();
      unawaited(_workHistoryCache
          .refreshRequest(widget.thread.id, workRequestId, supersede: true)
          .catchError((Object _) {}));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Retrying your request.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Could not retry your request. Check Worker readiness.'),
        ),
      );
    }
  }

  Future<bool> _cancelWorkRequest(
    String workRequestId, {
    bool closeDetails = false,
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
      if (closeDetails) Navigator.of(context).pop();
      unawaited(_workHistoryCache
          .refreshRequest(widget.thread.id, workRequestId, supersede: true)
          .catchError((Object _) {}));
      if (showFeedback) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request cancelled.')),
        );
      }
      return true;
    } catch (_) {
      if (!mounted) return false;
      if (showFeedback) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not cancel this request.')),
        );
      }
      return false;
    }
  }

  Future<void> _sendDiscussion() async {
    if (!widget.space.effectivePermissions.chat) return;
    final text = _discussionController.text;
    if (text.trim().isEmpty) return;
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Message deleted'), duration: Duration(seconds: 2)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
    final offset = controller.hasClients ? controller.offset : 0.0;
    final extent =
        controller.hasClients ? controller.position.maxScrollExtent : 0.0;
    _followChat = false;
    try {
      await cache.loadOlder(threadId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
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
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load older messages: $error')));
    } finally {
      _loadingOlderChat = false;
    }
  }
}

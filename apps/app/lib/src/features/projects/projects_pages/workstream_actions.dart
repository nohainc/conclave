part of '../projects_pages.dart';

extension _WorkstreamActions on _WorkstreamPageState {
  Future<void> _saveWorkConfig(Map<String, dynamic> config) async {
    if (!_canConfigureWork) return;
    final ds = widget.dataSource;
    if (ds == null) return;
    _updateState(() => _savingWorkConfig = true);
    try {
      final updated = await ds.updateWorkstream(
        workstreamId: widget.workstream.id,
        workConfig: config,
      );
      if (!mounted) return;
      _updateState(() {
        _workConfig = Map<String, dynamic>.from(updated.workConfig);
        _workstreamInstructionsController.text =
            _workConfig['workstreamInstructions']?.toString() ?? '';
        _savingWorkConfig = false;
      });
      final defaultId = _workConfig['defaultWorkflowId']?.toString();
      final selectedDefault = _workflowCatalog
          .where((workflow) => workflow.id == defaultId)
          .map((workflow) => workflow.reference)
          .firstOrNull;
      if (selectedDefault != null) _workflow = selectedDefault;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Work settings saved')),
      );
    } catch (error) {
      if (!mounted) return;
      _updateState(() => _savingWorkConfig = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save Work settings: $error')),
      );
    }
  }

  Future<void> _runWork() async {
    final text = _requestController.text;
    final submit = widget.onRunWork;
    final dataSource = widget.dataSource;
    if (!_canExecute ||
        (text.trim().isEmpty && _workAttachments.isEmpty) ||
        submit == null ||
        _awaitingWorkResponse) {
      return;
    }
    final requestText = text.trim().isEmpty
        ? 'Please use the attached inputs to complete the request.'
        : text;
    final attachments = List<Map<String, dynamic>>.from(_workAttachments);
    final workflowId = _workflow.split(':').first;
    final workstreamId = widget.workstream.id;
    final createdAt = DateTime.now().toUtc().toIso8601String();
    var localId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    AxWorkRequest localRequest({String status = 'queued', String? error}) =>
        AxWorkRequest(
          id: localId,
          requestedByName: 'You',
          requestedByUserId: widget.currentUserId,
          prompt: requestText,
          workflowId: workflowId,
          workflowVersion: 1,
          status: status,
          createdAt: createdAt,
          steps: const [],
          error: error,
        );
    void progress(String message) {
      if (mounted && widget.workstream.id == workstreamId) {
        _updateState(() => _localWorkProgress[localId] = message);
      }
    }

    void fail(String message) {
      if (!mounted || widget.workstream.id != workstreamId) return;
      _updateState(() {
        _workTimeline = [
          for (final request in _workTimeline)
            request.id == localId
                ? localRequest(status: 'failed', error: message)
                : request
        ];
        _localWorkProgress[localId] = message;
        // Preserve authored input for correction/retry after a rejected send.
        if (_requestController.text.isEmpty) _requestController.text = text;
        if (_workAttachments.isEmpty) _workAttachments = attachments;
      });
    }

    _updateState(() {
      _submittingWork = true;
      _workSubmitError = null;
      _workTimeline = [..._workTimeline, localRequest()];
      _localWorkProgress[localId] = 'Preparing your request…';
      _workAttachments = [];
    });
    _requestController.clear();
    try {
      if (dataSource != null) {
        progress('Checking that everything is ready…');
        final issues = await dataSource.validateWorkRequestEligibility(
            workstreamId: workstreamId,
            workflowId: workflowId,
            attachments: attachments);
        if (!mounted || widget.workstream.id != workstreamId) return;
        if (issues.isNotEmpty) {
          final workflowName = _workflowCatalog
                  .where((definition) => definition.id == workflowId)
                  .map((definition) => definition.name)
                  .firstOrNull ??
              workflowId;
          fail(
              'Cannot run $workflowName\n${issues.map((issue) => '• $issue').join('\n')}');
          return;
        }
      }
      progress('Sending your request…');
      final workRequestId = await submit(requestText, workflowId, attachments);
      if (!mounted || widget.workstream.id != workstreamId) {
        return;
      }
      final previousId = localId;
      localId = workRequestId;
      _updateState(() {
        _localWorkProgress.remove(previousId);
        _localWorkProgress[localId] = 'Request received. Waiting to start…';
        _workTimeline = [
          for (final request in _workTimeline)
            if (request.id != workRequestId)
              request.id == previousId ? localRequest() : request
        ];
      });
      if (dataSource != null) await _refreshWorkTimeline();
    } catch (error) {
      fail(error is AxApiException && error.message.startsWith('Cannot run ')
          ? error.message
          : 'Could not send your request: $error');
    } finally {
      if (mounted && widget.workstream.id == workstreamId) {
        _updateState(() => _submittingWork = false);
      }
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

  Future<void> _addWorkReference() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add link'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    if (_workAttachments.length >= 10) {
      if (mounted) {
        _updateState(() => _workSubmitError =
            'A Work Request can include up to 10 attachments.');
      }
      return;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        value.length > 2048) {
      if (mounted) {
        _updateState(() => _workSubmitError =
            'Enter a valid http or https link (up to 2,048 characters).');
      }
      return;
    }
    if (mounted) {
      _updateState(() => _workAttachments = [
            ..._workAttachments,
            {
              'kind': 'url',
              'name': uri.host,
              'url': uri.toString(),
              'mediaType': 'text/uri-list',
              'sizeBytes': 0,
            },
          ]);
    }
  }

  Future<void> _refreshWorkTimeline({bool activeOnly = false}) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) {
      if (_loadingWorkTimeline) {
        _updateState(() => _loadingWorkTimeline = false);
      }
      return;
    }
    if (_refreshingWorkTimeline) {
      _workTimelineRefreshPending = true;
      return;
    }
    _refreshingWorkTimeline = true;
    try {
      final requests = await dataSource.loadWorkstreamWorkRequests(
        workstreamId: widget.workstream.id,
        activeOnly: activeOnly,
      );
      if (!mounted) return;
      _updateState(() {
        for (final request in requests) {
          _localWorkProgress.remove(request.id);
        }
        if (activeOnly) {
          final updatedById = {
            for (final request in requests) request.id: request
          };
          _workTimeline = [
            for (final existing in _workTimeline)
              updatedById.remove(existing.id) ?? existing,
            ...updatedById.values,
          ]..sort((left, right) => left.createdAt.compareTo(right.createdAt));
        } else {
          _workTimeline = [
            ...requests,
            ..._workTimeline
                .where((request) => _localWorkProgress.containsKey(request.id))
          ]..sort((left, right) => left.createdAt.compareTo(right.createdAt));
        }
        _loadingWorkTimeline = false;
        _workTimelineError = null;
      });
    } catch (error) {
      if (mounted) {
        _updateState(() {
          _loadingWorkTimeline = false;
          _workTimelineError = error.toString();
        });
      }
    } finally {
      _refreshingWorkTimeline = false;
      _workRefreshTimer?.cancel();
      if (mounted &&
          _workTimeline.any((request) => const {'queued', 'running', 'waiting'}
              .contains(request.status))) {
        _workRefreshTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) unawaited(_refreshWorkTimeline(activeOnly: true));
        });
      }
      if (_workTimelineRefreshPending && mounted) {
        _workTimelineRefreshPending = false;
        unawaited(_refreshWorkTimeline(activeOnly: activeOnly));
      }
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
              child: const Center(child: Text('Could not load Run details.')),
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
            onCancelRun: () => _cancelFailedWorkRequest(
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
          title: const Text('Retry Implement'),
          content: Text(
            '$recommendation\n\nChoose how the retry should use provider context.',
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
      unawaited(_refreshWorkTimeline());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Retrying ${step.kind} Step.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not retry this Step. Check Worker readiness.'),
        ),
      );
    }
  }

  Future<void> _cancelFailedWorkRequest(
    String workRequestId, {
    bool closeDetails = false,
  }) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    try {
      await dataSource.cancelWorkRequest(workRequestId: workRequestId);
      if (!mounted) return;
      if (closeDetails) Navigator.of(context).pop();
      unawaited(_refreshWorkTimeline());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run cancelled.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not cancel this Run.')),
      );
    }
  }

  Future<void> _sendDiscussion() async {
    final text = _discussionController.text;
    if (text.trim().isEmpty) return;
    _discussionController.clear();
    final now = DateTime.now();
    final tempId = 'temp-${DateTime.now().microsecondsSinceEpoch}';
    _updateState(() {
      _discussion.add(
        _DiscussionItem(
          id: tempId,
          author: 'You',
          text: text,
          sentAt: _chatTimestamp(now),
          isMe: true,
        ),
      );
    });

    final ds = widget.dataSource;
    if (ds != null) {
      try {
        final saved = await ds.sendDiscussionMessage(
          workstreamId: widget.workstream.id,
          text: text,
        );
        if (!mounted) return;
        _updateState(() {
          final idx = _discussion.indexWhere((item) => item.id == tempId);
          if (idx != -1) {
            final dt = DateTime.tryParse(saved.createdAt)?.toLocal();
            final timeStr = _chatTimestamp(dt ?? now);
            _discussion[idx] = _DiscussionItem(
              id: saved.id,
              author: 'You',
              text: saved.body,
              sentAt: timeStr,
              isMe: true,
            );
          }
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _editDiscussion(String messageId, String newText) async {
    _updateState(() {
      final idx = _discussion.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        final old = _discussion[idx];
        _discussion[idx] = _DiscussionItem(
          id: old.id,
          author: old.author,
          text: newText,
          sentAt: old.sentAt,
          isMe: old.isMe,
        );
      }
    });

    final ds = widget.dataSource;
    if (ds != null && !messageId.startsWith('temp-')) {
      try {
        await ds.editDiscussionMessage(
          messageId: messageId,
          text: newText,
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }
}

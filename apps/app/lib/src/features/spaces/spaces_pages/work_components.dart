part of '../spaces_pages.dart';

String _modelDisplayName(String? modelId, {AxWorker? worker}) {
  if (modelId == null || modelId.trim().isEmpty) return '';
  return worker?.executionOptions?.models
          .where((m) => m.id == modelId)
          .firstOrNull
          ?.name ??
      modelId;
}

// Execution diagnostics remain in Workspace/Engine logs, not conversation text.
String _executionFailureMessage(String? code, {String? validationMessage}) =>
    switch (code) {
      'session_resume_failed' =>
        'The worker could not continue the previous conversation. Please retry your request.',
      'worker_not_ready' =>
        'The selected worker is not ready on its workspace.',
      'cli_not_found' ||
      'provider_tool_unavailable' =>
        'The worker needs to be set up on its workspace before it can respond.',
      'authentication_required' ||
      'provider_authentication_required' =>
        'Sign in to the worker on its workspace, then retry your request.',
      'unsupported_cli_version' ||
      'unsupported_provider_tool_version' =>
        'Update the worker on its workspace, then retry your request.',
      'model_not_supported' =>
        'The selected model is not available for this worker. Choose another model and retry.',
      'permission_denied' =>
        'The worker does not have the access needed to complete your request.',
      'quota_exhausted' => 'The worker’s usage limit has been reached.',
      'provider_unavailable' =>
        'The worker is temporarily unavailable. Please try again later.',
      'timeout' ||
      'deadline_exceeded' =>
        'The worker took too long to respond. Please retry your request.',
      'cancelled' => 'Request cancelled.',
      null => validationMessage ??
          'Your request could not be completed. Please retry.',
      _ => 'Your request could not be completed. Please retry.',
    };

Future<T?> _showAnchoredMenu<T>({
  required BuildContext buttonContext,
  required GlobalKey inputKey,
  required List<PopupMenuEntry<T>> items,
  required double itemHeight,
  int dividerCount = 0,
}) async {
  final box = buttonContext.findRenderObject()! as RenderBox;
  final overlay =
      Overlay.of(buttonContext).context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final inputBox = inputKey.currentContext?.findRenderObject() as RenderBox?;
  final anchorBottom = inputBox == null
      ? rect.top
      : inputBox.localToGlobal(Offset.zero, ancestor: overlay).dy +
          inputBox.size.height;
  final availableHeight = (anchorBottom - 8).clamp(0.0, overlay.size.height);
  final itemCount = items.length - dividerCount;
  final exactHeight = (itemCount * itemHeight) + (dividerCount * 16.0) + 16.0;
  final menuHeight = exactHeight.clamp(0.0, availableHeight);
  return showMenu<T>(
    context: buttonContext,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    constraints: BoxConstraints(maxHeight: menuHeight),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(rect.left, anchorBottom - menuHeight, rect.width, 0),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

class _WorkComposer extends StatelessWidget {
  const _WorkComposer({
    required this.requestController,
    required this.historyController,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflow,
    required this.workflowCatalog,
    this.workConfig = const <String, dynamic>{},
    this.spaceWorkers = const <AxWorker>[],
    this.eligibleWorkers = const <AxWorker>[],
    required this.loadingWorkflows,
    required this.workflowCatalogError,
    required this.canExecute,
    required this.workTimeline,
    required this.activityStore,
    required this.localWorkProgress,
    required this.loadingTimeline,
    required this.timelineError,
    required this.submitError,
    required this.submitting,
    required this.composerKey,
    required this.attachments,
    required this.onAddFiles,
    required this.executionSelection,
    required this.onExecutionSelectionChanged,
    required this.onRemoveAttachment,
    required this.onRefresh,
    required this.hasOlder,
    required this.loadingOlder,
    required this.onLoadOlder,
    required this.onReportIssue,
    required this.reportedIssues,
    required this.reportingIssueIds,
    required this.issueReportErrors,
    required this.onRetryStep,
    required this.onCancelRun,
    required this.onWorkflowChanged,
    required this.onRun,
  });

  final TextEditingController requestController;
  final ScrollController historyController;
  final String? currentUserId;
  final String? currentUserName;
  final String workflow;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final Map<String, dynamic> workConfig;
  final List<AxWorker> spaceWorkers;
  final List<AxWorker> eligibleWorkers;
  final bool loadingWorkflows;
  final String? workflowCatalogError;
  final bool canExecute;
  final List<AxWorkRequest> workTimeline;
  final AxWorkActivityStore activityStore;
  final Map<String, String> localWorkProgress;
  final bool loadingTimeline;
  final String? timelineError;
  final String? submitError;
  final bool submitting;
  final GlobalKey composerKey;
  final List<Map<String, dynamic>> attachments;
  final Future<void> Function() onAddFiles;
  final Map<String, dynamic> executionSelection;
  final ValueChanged<Map<String, dynamic>> onExecutionSelectionChanged;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onRefresh;
  final bool hasOlder;
  final bool loadingOlder;
  final Future<void> Function() onLoadOlder;
  final Future<void> Function(String)? onReportIssue;
  final Map<String, AxIssueReport> reportedIssues;
  final Set<String> reportingIssueIds;
  final Map<String, String> issueReportErrors;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;
  final ValueChanged<String> onWorkflowChanged;
  final Future<void> Function() onRun;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: history(context)),
        const SizedBox(height: 16),
        controls(context)
      ]);

  Widget history(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
        controller: historyController,
        key: const ValueKey('work-history-scroll'),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (hasOlder)
            TextButton(
                onPressed: loadingOlder ? null : onLoadOlder,
                child: Text(loadingOlder
                    ? 'Loading older Work history…'
                    : 'Load older Work history')),
          if (timelineError != null && workTimeline.isNotEmpty)
            TextButton(
                onPressed: onRefresh, child: const Text('Retry Work sync')),
          if (loadingTimeline && workTimeline.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: LinearProgressIndicator(),
            )
          else if (timelineError != null && workTimeline.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Could not load Work history: $timelineError',
                style: TextStyle(color: colors.error),
              ),
            )
          else if (workTimeline.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
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
                    'No work requests yet',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Ask AI to do something for the team. Nothing runs until you send the request.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ],
              ),
            )
          else
            // Only the card whose assignment changed rebuilds on Worker
            // activity; the list itself depends on the Work history alone.
            ListView.separated(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: workTimeline.length,
              // Preserve render and selection state by request when entries move.
              findItemIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final index = workTimeline.indexWhere((r) => r.id == key.value);
                return index < 0 ? null : index;
              },
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final request = workTimeline[index];
                return ListenableBuilder(
                  key: ValueKey(request.id),
                  listenable: activityStore.listenableForRequest(request),
                  builder: (context, _) => _WorkTimelineCard(
                    request: request,
                    activities: activityStore.forRequest(request),
                    clockOffset: activityStore.clockOffsetForRequest(request),
                    progressText: localWorkProgress[request.id],
                    currentUserId: currentUserId,
                    currentUserName: currentUserName,
                    workflowCatalog: workflowCatalog,
                    onReportIssue: localWorkProgress.containsKey(request.id)
                        ? null
                        : onReportIssue,
                    reportedIssue: reportedIssues[request.id],
                    reportingIssue: reportingIssueIds.contains(request.id),
                    issueReportError: issueReportErrors[request.id],
                    onRetryStep: localWorkProgress.containsKey(request.id)
                        ? null
                        : onRetryStep,
                    onCancelRun: localWorkProgress.containsKey(request.id)
                        ? null
                        : onCancelRun,
                  ),
                );
              },
            ),
        ]));
  }

  Widget controls(BuildContext context) => _buildComposerInput(
      context,
      Theme.of(context).brightness == Brightness.dark,
      Theme.of(context).colorScheme);

  Widget _additionalControls(BuildContext context, GlobalKey inputKey) {
    final selectedWorkflow = workflowCatalog
            .where((item) => item.reference == workflow)
            .firstOrNull ??
        workflowCatalog
            .where((item) => item.id == workflow.split(':').first)
            .firstOrNull;

    final bindings = workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final stepKind = selectedWorkflow?.composerBindingId;
    final rawBinding = stepKind == null ? null : bindings[stepKind];
    final binding = rawBinding is Map
        ? Map<String, dynamic>.from(rawBinding)
        : <String, dynamic>{};
    final policy =
        selectedWorkflow?.executionPolicy ?? const AxWorkflowCapabilities();
    final selectedWorkerId = (executionSelection.containsKey('workerId')
            ? executionSelection['workerId']
            : binding['workerId'])
        ?.toString()
        .trim();
    final selectedModel = (executionSelection.containsKey('model')
                ? executionSelection['model']
                : binding['model'])
            ?.toString()
            .trim() ??
        '';
    final selectedReasoningEffort =
        (executionSelection.containsKey('reasoningEffort')
                    ? executionSelection['reasoningEffort']
                    : binding['reasoningEffort'])
                ?.toString()
                .trim() ??
            '';
    final controlBg = Colors.transparent;
    const controlBorderRadius = BorderRadius.all(Radius.circular(6));

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (buttonContext) => Tooltip(
              message: 'Add attachments',
              child: Material(
                color: controlBg,
                borderRadius: controlBorderRadius,
                child: InkWell(
                  borderRadius: controlBorderRadius,
                  onTap: () async {
                    final value = await _showAnchoredMenu<String>(
                      buttonContext: buttonContext,
                      inputKey: inputKey,
                      itemHeight: 48.0,
                      items: [
                        PopupMenuItem(
                          value: 'files',
                          enabled: canExecute && !submitting,
                          child: const ListTile(
                            dense: true,
                            leading: Icon(Icons.attach_file, size: 18),
                            title: Text('Add files'),
                          ),
                        ),
                      ],
                    );
                    if (!buttonContext.mounted || value == null) return;
                    if (value == 'files') {
                      onAddFiles();
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Icon(Icons.add, size: 16),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Builder(
            builder: (workflowBtnContext) => Tooltip(
              message: 'Choose workflow',
              child: Material(
                color: controlBg,
                borderRadius: controlBorderRadius,
                child: InkWell(
                  borderRadius: controlBorderRadius,
                  onTap: canExecute && !submitting && workflowCatalog.isNotEmpty
                      ? () async {
                          final versions =
                              _currentWorkflowVersions(workflowCatalog);
                          final value = await _showAnchoredMenu<String>(
                            buttonContext: workflowBtnContext,
                            inputKey: inputKey,
                            itemHeight: 48.0,
                            items: [
                              for (final item in versions)
                                CheckedPopupMenuItem(
                                  value: item.reference,
                                  checked: item.reference == workflow,
                                  enabled: canExecute && !submitting,
                                  child: Tooltip(
                                    message: item.description,
                                    child: Text(item.name),
                                  ),
                                ),
                            ],
                          );
                          if (!workflowBtnContext.mounted || value == null) {
                            return;
                          }
                          onWorkflowChanged(value);
                        }
                      : null,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 130),
                          child: Text(
                            selectedWorkflow?.name ?? 'Choose workflow',
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Icons.keyboard_arrow_down, size: 14),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ModelEffortSelector(
            scope: 'work-composer',
            helperMessage: eligibleWorkers
                        .where((worker) => worker.id == selectedWorkerId)
                        .firstOrNull
                        ?.executionOptions
                        ?.modelSwitchSupported ==
                    false
                ? 'Changing the model starts a new session with the conversation context. Effort changes that select another model follow the same rule.'
                : null,
            compact: true,
            showWorkerInCompactSummary: false,
            showWorker: true,
            showModel: true,
            showEffort: true,
            showCatalog: false,
            allowWorkerChange: policy.userSelectsWorker,
            allowModelChange: policy.userSelectsModel,
            allowEffortChange: policy.userSelectsEffort,
            catalog:
                AxWorkflowSelectionOptions(eligibleWorkers).sharedCatalog,
            value: ExecutionSelection(
                worker: selectedWorkerId,
                catalogRevision: (executionSelection['catalogRevision'] ??
                    binding['catalogRevision']) as String?,
                model: selectedModel.isEmpty ? null : selectedModel,
                effort: selectedReasoningEffort.isEmpty
                    ? null
                    : selectedReasoningEffort),
            readOnly: !canExecute ||
                submitting ||
                !(policy.userSelectsWorker ||
                    policy.userSelectsModel ||
                    policy.userSelectsEffort),
            onChanged: (value) => onExecutionSelectionChanged({
              'workerId': value.worker,
              'model': value.model,
              'reasoningEffort': value.effort,
              if (value.catalogRevision != null)
                'catalogRevision': value.catalogRevision,
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildComposerInput(
    BuildContext context,
    bool isDark,
    ColorScheme colors,
  ) {
    return Container(
      padding: EdgeInsets.zero,
      key: composerKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MarkdownComposer(
            controller: requestController,
            chatStyle: true,
            minLines: 1,
            maxLines: 6,
            enabled: canExecute,
            onSend: () => onRun(),
            sendTooltip: 'Send request',
            sendEnabled: canExecute &&
                !submitting &&
                !loadingWorkflows &&
                workflowCatalogError == null,
            showMarkdownControlsInSuffix: false,
            showSendInSuffix: true,
            sendInToolbar: true,
            executionControlsBuilder: (inputKey) =>
                _additionalControls(context, inputKey),
          ),
          if (attachments.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < attachments.length; i++)
                  InputChip(
                    avatar: const Icon(Icons.insert_drive_file, size: 14),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        (attachments[i]['name'] ?? 'Attachment').toString(),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    onDeleted: canExecute && !submitting
                        ? () => onRemoveAttachment(i)
                        : null,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Up to 10 file attachments. Files total 1 MB.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          if (loadingWorkflows) const LinearProgressIndicator(),
          if (workflowCatalogError != null)
            Text(workflowCatalogError!, style: TextStyle(color: colors.error)),
          if (!canExecute)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Viewer access can read the thread but cannot run Work.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (submitError != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: SelectableText(
                  submitError!,
                  style: ConclaveMessageTypography.fromTheme(Theme.of(context))
                      .copyWith(color: colors.error),
                ),
              ),
              IconButton(
                tooltip: 'Copy request error',
                icon: const Icon(Icons.copy_outlined, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: submitError!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Request error copied')),
                    );
                  }
                },
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

class _WorkTimelineCard extends StatelessWidget {
  const _WorkTimelineCard({
    super.key,
    required this.request,
    required this.activities,
    this.clockOffset = Duration.zero,
    this.progressText,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflowCatalog,
    required this.onReportIssue,
    required this.reportedIssue,
    required this.reportingIssue,
    required this.issueReportError,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final AxWorkRequest request;
  final List<AxWorkActivity> activities;
  final Duration clockOffset;
  final String? progressText;
  final String? currentUserId;
  final String? currentUserName;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final Future<void> Function(String)? onReportIssue;
  final AxIssueReport? reportedIssue;
  final bool reportingIssue;
  final String? issueReportError;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;

  String get _workflowName =>
      request.workflowName ??
      workflowCatalog
          .where((workflow) =>
              workflow.id == request.workflowId &&
              workflow.version == request.workflowVersion)
          .map((workflow) => workflow.name)
          .firstOrNull ??
      request.workflowId;

  String _elapsed(int? milliseconds) {
    if (milliseconds == null) return '';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  int get _totalElapsedMs => request.steps
      .map((step) => step.elapsedMs)
      .whereType<int>()
      .fold<int>(0, (total, value) => total + value);

  String _totalElapsed() {
    final elapsed = _totalElapsedMs;
    return elapsed == 0 ? '' : _elapsed(elapsed);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final metaColor = isDark ? Colors.white38 : Colors.black45;

    final timestamp = DateTime.tryParse(request.createdAt)?.toLocal();
    final timeLabel = timestamp == null ? '' : _chatTimestamp(timestamp);
    final rawRequesterName = request.requestedByName.trim();
    final effectiveRequesterName = (rawRequesterName.isEmpty ||
            rawRequesterName == request.requestedByUserId ||
            rawRequesterName.startsWith('usr_'))
        ? 'Team member'
        : rawRequesterName;
    final requesterInitials = effectiveRequesterName.isNotEmpty
        ? effectiveRequesterName
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';
    final normalizedRequesterName = effectiveRequesterName.trim().toLowerCase();
    final normalizedCurrentName = currentUserName?.trim().toLowerCase();
    final isOwnRequest = (currentUserId != null &&
            currentUserId!.isNotEmpty &&
            request.requestedByUserId == currentUserId) ||
        (normalizedCurrentName != null &&
            normalizedCurrentName.isNotEmpty &&
            (normalizedRequesterName == normalizedCurrentName ||
                rawRequesterName.toLowerCase() == normalizedCurrentName));
    final showRequesterIdentity = !isOwnRequest;

    final failedStep =
        request.steps.where((step) => step.status == 'failed').firstOrNull;
    final lastCompletedStep = request.steps
        .where((step) =>
            step.status == 'completed' &&
            step.resultText?.trim().isNotEmpty == true)
        .lastOrNull;
    final activeStep = request.steps
        .where((step) => step.status == 'running' || step.status == 'waiting')
        .firstOrNull;
    final stepForContext =
        activeStep ?? lastCompletedStep ?? request.steps.firstOrNull;
    final response = request.finalText?.trim().isNotEmpty == true
        ? request.finalText!
        : request.turns
                .where((turn) =>
                    turn.status == 'completed' &&
                    turn.resultText?.trim().isNotEmpty == true)
                .lastOrNull
                ?.resultText ??
            request.steps
                .map((step) => step.resultText)
                .whereType<String>()
                .where((text) => text.trim().isNotEmpty)
                .firstOrNull;
    final rawError = request.error?.trim().isNotEmpty == true
        ? request.error!
        : failedStep?.errorMessage;
    final error = request.status == 'failed' || rawError?.isNotEmpty == true
        ? _executionFailureMessage(
            failedStep?.errorCode,
            validationMessage: request.steps.isEmpty
                ? rawError
                : null,
          )
        : null;
    final isError = error?.isNotEmpty == true;

    // Waiting/queued messages belong to Conclave. A running Step is the
    // product's worker execution signal; no final text is required to attribute it.
    final senderStep = activeStep?.status == 'running'
        ? activeStep
        : lastCompletedStep ?? stepForContext;
    final stepStartedAt =
        DateTime.tryParse((activeStep ?? senderStep)?.startedAt ?? '')
            ?.toLocal();
    AxWorkProgress resolveProgress(DateTime now) => AxWorkProgress.resolve(
          requestStatus: request.status,
          activities: activities,
          now: now,
          stepStartedAt: stepStartedAt,
          serverElapsedMs: _totalElapsedMs == 0 ? null : _totalElapsedMs,
          clockOffset: clockOffset,
        );
    final progress = resolveProgress(DateTime.now());
    final senderTurn = request.turns
        .where((turn) => turn.assignmentId == senderStep?.assignmentId)
        .lastOrNull;
    final selectedModel =
        (senderTurn != null ? senderTurn.modelId : senderStep?.model)?.trim();
    final selectedReasoningEffort =
        (senderTurn != null ? senderTurn.effort : senderStep?.reasoningEffort)
            ?.trim();
    final workerType = (senderTurn?.workerTypeId ?? senderStep?.workerTypeId)
        ?.trim()
        .toLowerCase();
    final workerDisplayName =
        (senderTurn?.workerDisplayName ?? senderStep?.workerDisplayName)
            ?.trim();
    final presentation =
        WorkerPresentation.resolve(workerType, workerDisplayName);
    final workerName = presentation.name;
    final isWorkerResponse = !isError &&
        (senderStep?.status == 'running' ||
            progress.isExecuting ||
            response?.isNotEmpty == true) &&
        (workerDisplayName?.isNotEmpty == true ||
            workerType?.isNotEmpty == true);
    final senderName = isWorkerResponse ? workerName : 'Conclave';
    final workerIcon = presentation.iconAsset;

    final frozenModelName = senderTurn?.modelName ?? senderStep?.modelName;
    String? formattedModelInfo;
    if (selectedModel != null && selectedModel.isNotEmpty) {
      final modelName = frozenModelName ?? _modelDisplayName(selectedModel);
      if (selectedReasoningEffort != null &&
          selectedReasoningEffort.isNotEmpty) {
        formattedModelInfo =
            '$modelName · ${executionEffortDisplayName(selectedReasoningEffort)}';
      } else {
        formattedModelInfo = modelName;
      }
    } else if (selectedReasoningEffort != null &&
        selectedReasoningEffort.isNotEmpty) {
      formattedModelInfo =
          'Default model · ${executionEffortDisplayName(selectedReasoningEffort)}';
    }

    if (senderTurn != null) {
      final modelLabel = selectedModel?.isNotEmpty == true
          ? frozenModelName ?? _modelDisplayName(selectedModel)
          : 'Default model';
      final effortLabel = selectedReasoningEffort?.isNotEmpty == true
          ? executionEffortDisplayName(selectedReasoningEffort)
          : 'Default effort';
      formattedModelInfo = '$modelLabel · $effortLabel';
    }
    // Live elapsed time comes from the Worker flow while the request is
    // unfinished; the server-reported duration replaces it once it is not.
    String metadataAt(DateTime now) {
      final live = progress.showsLiveElapsed
          ? resolveProgress(now).elapsedAt(now)
          : null;
      final elapsed = live != null
          ? AxWorkProgress.formatDuration(live)
          : progress.showsLiveElapsed
              ? ''
              : _totalElapsed();
      final segments = [
        if (_workflowName.isNotEmpty) _workflowName,
        if (elapsed.isNotEmpty) elapsed,
      ];
      return segments.isEmpty ? '' : '· ${segments.join(' · ')}';
    }

    final hasMetadata = _workflowName.isNotEmpty ||
        progress.showsLiveElapsed ||
        _totalElapsedMs != 0;
    final senderIconOpacity = isDark ? 0.72 : 0.85;

    final Widget senderAvatar = isWorkerResponse
        ? (workerIcon != null
            ? Opacity(
                opacity: senderIconOpacity,
                child: Image.asset(workerIcon,
                    width: 22,
                    height: 22,
                    fit: BoxFit.contain,
                    semanticLabel: '$workerName icon'),
              )
            : CircleAvatar(
                radius: 11,
                backgroundColor: ConclaveColors.primarySoftColor(isDark),
                child: Text(workerName.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                        fontSize: 12,
                        color: metaColor)),
              ))
        : Opacity(
            opacity: senderIconOpacity,
            child: Image.asset(
              ConclaveBrandAssets.logoPng32,
              width: 20,
              height: 20,
              fit: BoxFit.contain,
              errorBuilder: (ctx, err, stack) => Icon(
                Icons.auto_awesome,
                size: 14,
                color: metaColor,
              ),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // User prompt bubble
        LayoutBuilder(
          builder: (context, constraints) {
            final maxBubbleWidth = math.min(640.0, constraints.maxWidth * 0.9);
            return Align(
              alignment:
                  isOwnRequest ? Alignment.centerRight : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                child: Container(
                  decoration: BoxDecoration(
                    color: isOwnRequest
                        ? ConclaveColors.ownMessageBackground(isDark)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding:
                      EdgeInsets.fromLTRB(isOwnRequest ? 14 : 0, 10, 14, 10),
                  child: Column(
                    crossAxisAlignment: isOwnRequest
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showRequesterIdentity) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor:
                                  ConclaveColors.primarySoftColor(isDark),
                              child: Text(
                                requesterInitials,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color:
                                      ConclaveColors.primaryForeground(isDark),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              effectiveRequesterName,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                      ],
                      ConclaveMarkdownBody(
                        data: request.prompt,
                        fitContent: true,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (timeLabel.isNotEmpty) ...[
                            Text(
                              timeLabel,
                              style: TextStyle(fontSize: 11, color: metaColor),
                            ),
                            const SizedBox(width: 8),
                          ],
                          _AnimatedMessageAction(
                            tooltip: 'Copy Markdown',
                            icon: Icons.copy_rounded,
                            color: metaColor,
                            onTap: () {
                              Clipboard.setData(
                                  ClipboardData(text: request.prompt));
                            },
                          ),
                        ].orderedForMessage(isOwnRequest),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        // AI Execution & response bubble
        LayoutBuilder(
          builder: (context, constraints) {
            final maxBubbleWidth = math.min(680.0, constraints.maxWidth * 0.9);
            return Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          senderAvatar,
                          const SizedBox(width: 6),
                          Text(
                            senderName,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: metaColor,
                            ),
                          ),
                          if (isWorkerResponse &&
                              formattedModelInfo != null) ...[
                            const SizedBox(width: 6),
                            Tooltip(
                              message: formattedModelInfo,
                              triggerMode: TooltipTriggerMode.tap,
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(Icons.info_outline_rounded,
                                    size: 14, color: metaColor),
                              ),
                            ),
                          ],
                          if (hasMetadata) ...[
                            const SizedBox(width: 6),
                            Expanded(
                              child: AxLiveTicker(
                                active: progress.isTicking,
                                builder: (context, now) => Text(
                                  metadataAt(now),
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      TextStyle(fontSize: 12, color: metaColor),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      Builder(builder: (context) {
                        // The body shows the Worker's live status while the
                        // request is unfinished and the real outcome at the end.
                        final String? message = error?.isNotEmpty == true
                            ? error
                            : response?.isNotEmpty == true
                                ? response
                                : request.status == 'cancelled'
                                    ? 'Request cancelled.'
                                    : (progress.isExecuting
                                            ? null
                                            : progressText) ??
                                        switch (request.status) {
                                          'completed' => 'Request completed.',
                                          'failed' =>
                                            'Your request could not be completed.',
                                          'timed_out' =>
                                            'The worker took too long to respond. Please retry your request.',
                                          'lost' =>
                                            'The connection to the worker was lost. Please retry your request.',
                                          _ => null,
                                        };
                        final showLiveStatus =
                            message == null && !progress.isTerminal;
                        final isError = error?.isNotEmpty == true;
                        Widget compactAction({
                          required String tooltip,
                          required IconData icon,
                          required VoidCallback? onPressed,
                        }) =>
                            Tooltip(
                              message: tooltip,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: onPressed,
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Icon(
                                    icon,
                                    size: 15,
                                    color: metaColor,
                                  ),
                                ),
                              ),
                            );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (showLiveStatus) ...[
                              AxLiveTicker(
                                active: progress.isTicking,
                                builder: (context, now) {
                                  final live = resolveProgress(now);
                                  final text = live.currentAction ?? '';
                                  return Text(
                                    live.isStale
                                        ? '$text · no recent updates'
                                        : text,
                                    key: const ValueKey('work-live-status'),
                                    style: ConclaveMessageTypography
                                            .fromTheme(Theme.of(context))
                                        .copyWith(
                                      color: isDark
                                          ? Colors.white60
                                          : Colors.black54,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (message != null) ...[
                              if (isError)
                                SelectableText(
                                  message,
                                  style: ConclaveMessageTypography.fromTheme(
                                          Theme.of(context))
                                      .copyWith(color: colors.error),
                                )
                              else
                                ConclaveMarkdownBody(
                                  key: ValueKey((request.id, message)),
                                  data: message,
                                ),
                              const SizedBox(height: 8),
                            ],
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (response?.isNotEmpty == true ||
                                    error?.isNotEmpty == true)
                                  compactAction(
                                    tooltip: isError
                                        ? 'Copy error'
                                        : 'Copy Markdown',
                                    icon: Icons.copy_outlined,
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(
                                        text: isError ? error! : response!,
                                      ));
                                    },
                                  ),
                                if ((request.status == 'queued' ||
                                        request.status == 'running') &&
                                    onCancelRun != null)
                                  compactAction(
                                    tooltip: 'Cancel request',
                                    icon: Icons.cancel_outlined,
                                    onPressed: () => onCancelRun!(request.id),
                                  ),
                                if (request.status == 'failed' &&
                                    onReportIssue != null)
                                  if (reportedIssue != null)
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.check_circle_outline,
                                            size: 15, color: colors.primary),
                                        const SizedBox(width: 3),
                                        Text('Reported',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: colors.primary)),
                                      ],
                                    )
                                  else
                                    compactAction(
                                      tooltip: reportingIssue
                                          ? 'Sending issue report'
                                          : 'Report issue — sends sanitized technical diagnostics only',
                                      icon: reportingIssue
                                          ? Icons.hourglass_top_rounded
                                          : Icons.flag_outlined,
                                      onPressed: reportingIssue
                                          ? null
                                          : () => onReportIssue!(request.id),
                                    ),
                                const SizedBox(width: 8),
                                if (timeLabel.isNotEmpty)
                                  Text(
                                    timeLabel,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: metaColor,
                                    ),
                                  ),
                              ],
                            ),
                            if (reportedIssue != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Thanks — sanitized technical diagnostics were sent.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: metaColor,
                                ),
                              ),
                            ],
                            if (issueReportError != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                "Couldn't send the report. Try again.",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.error,
                                ),
                              ),
                            ],
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Rebuilds [builder] once a second while [active], handing it the current
/// time. Used for live elapsed time and stale-progress hints that must keep
/// moving between Worker events.
class AxLiveTicker extends StatefulWidget {
  const AxLiveTicker({
    super.key,
    required this.active,
    required this.builder,
    this.clock,
  });

  final bool active;
  final Widget Function(BuildContext context, DateTime now) builder;

  /// Overrides the wall clock; used by tests.
  final DateTime Function()? clock;

  @override
  State<AxLiveTicker> createState() => _AxLiveTickerState();
}

class _AxLiveTickerState extends State<AxLiveTicker> {
  Timer? _timer;
  late DateTime _now;

  DateTime _clock() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _now = _clock();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AxLiveTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _now = _clock();
    _sync();
  }

  void _sync() {
    if (widget.active && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _now = _clock());
      });
    } else if (!widget.active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}

class _DiscussionItem {
  const _DiscussionItem({
    required this.id,
    required this.author,
    required this.text,
    this.sentAt,
    this.editedAt,
    this.isMe = true,
  });

  final String id;
  final String author;
  final String text;
  final String? sentAt;
  final String? editedAt;
  final bool isMe;
}

class _DiscussionMessageBubble extends StatefulWidget {
  const _DiscussionMessageBubble({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onEdit,
    this.onDelete,
  });

  final _DiscussionItem item;
  final VoidCallback onCopy;
  final ValueChanged<String> onEdit;
  final VoidCallback? onDelete;

  @override
  State<_DiscussionMessageBubble> createState() =>
      _DiscussionMessageBubbleState();
}

class _DiscussionMessageBubbleState extends State<_DiscussionMessageBubble> {
  bool _isEditing = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.item.text);
  }

  @override
  void didUpdateWidget(covariant _DiscussionMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.text != widget.item.text && !_isEditing) {
      _editController.text = widget.item.text;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  void _saveEdit() {
    final text = _editController.text;
    if (text.trim().isNotEmpty) {
      widget.onEdit(text);
    }
    setState(() => _isEditing = false);
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text(
            'Are you sure you want to delete this message? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && widget.onDelete != null) {
      widget.onDelete!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = widget.item.isMe;

    final initials = widget.item.author.isNotEmpty
        ? widget.item.author
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';

    final metaColor = isDark ? Colors.white38 : Colors.black45;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBubbleWidth = math.min(640.0, constraints.maxWidth * 0.9);
        return Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: Container(
              decoration: BoxDecoration(
                color: isMe
                    ? ConclaveColors.ownMessageBackground(isDark)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: EdgeInsets.fromLTRB(isMe ? 14 : 0, 10, 14, 10),
              child: Column(
                crossAxisAlignment:
                    isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isMe) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor:
                              ConclaveColors.primarySoftColor(isDark),
                          child: Text(
                            initials,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: ConclaveColors.primaryForeground(isDark),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.item.author,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (_isEditing) ...[
                    MarkdownComposer(
                      controller: _editController,
                      compact: true,
                      maxLines: 6,
                      autofocus: true,
                      chatStyle: true,
                      onSubmit: _saveEdit,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _editController.text = widget.item.text;
                            _isEditing = false;
                          }),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _saveEdit,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ] else ...[
                    ConclaveMarkdownBody(
                      data: widget.item.text,
                      fitContent: true,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.item.editedAt != null) ...[
                          Text(
                            'Edited ${widget.item.editedAt}',
                            style: TextStyle(
                              fontSize: 11,
                              color: metaColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ] else if (widget.item.sentAt != null) ...[
                          Text(
                            widget.item.sentAt!,
                            style: TextStyle(
                              fontSize: 11,
                              color: metaColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (isMe &&
                            widget.onDelete != null &&
                            !widget.item.id.startsWith('temp-')) ...[
                          _AnimatedMessageAction(
                            tooltip: 'Delete message',
                            icon: Icons.delete_outline_rounded,
                            color: metaColor,
                            onTap: () => _confirmDelete(context),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (!widget.item.id.startsWith('temp-')) ...[
                          _AnimatedMessageAction(
                            tooltip: 'Edit message',
                            icon: Icons.edit_outlined,
                            color: metaColor,
                            onTap: () => setState(() {
                              _editController.text = widget.item.text;
                              _isEditing = true;
                            }),
                          ),
                          const SizedBox(width: 6),
                        ],
                        _AnimatedMessageAction(
                          tooltip: 'Copy Markdown',
                          icon: Icons.copy_rounded,
                          color: metaColor,
                          onTap: widget.onCopy,
                        ),
                      ].orderedForMessage(isMe),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AnimatedMessageAction extends StatefulWidget {
  const _AnimatedMessageAction({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_AnimatedMessageAction> createState() => _AnimatedMessageActionState();
}

class _AnimatedMessageActionState extends State<_AnimatedMessageAction> {
  Timer? _releaseTimer;
  bool _pressed = false;

  @override
  void dispose() {
    _releaseTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    _releaseTimer?.cancel();
    setState(() => _pressed = true);
    widget.onTap();
    _releaseTimer = Timer(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: _handleTap,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: AnimatedScale(
                scale: _pressed ? 0.78 : 1,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOutBack,
                child: Icon(widget.icon, size: 14, color: widget.color),
              ),
            ),
          ),
        ),
      );
}

// Own-message metadata follows reading order toward the right edge.
extension _MessageFooterOrder on List<Widget> {
  List<Widget> orderedForMessage(bool own) => own ? this : reversed.toList();
}

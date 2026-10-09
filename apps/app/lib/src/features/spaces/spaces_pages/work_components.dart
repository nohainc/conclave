part of '../spaces_pages.dart';

class AxModelOption {
  const AxModelOption({
    required this.id,
    required this.name,
    required this.badge,
    required this.description,
    this.minCliVersion,
    this.defaultReasoningEffort,
    this.supportedReasoningEfforts = const [],
  });

  final String id;
  final String name;
  final String badge;
  final String description;
  final String? minCliVersion;
  final String? defaultReasoningEffort;
  final List<String> supportedReasoningEfforts;
}

List<AxModelOption> _modelsForWorker(AxWorker worker) {
  final options = worker.executionOptions;
  if (options != null && options.models.isNotEmpty) {
    return options.models
        .map((model) => AxModelOption(
              id: model.id,
              name: model.name,
              badge: '',
              description: '',
              defaultReasoningEffort: model.effort.defaultValue,
              supportedReasoningEfforts:
                  model.effort.supported ? model.effort.values : const [],
            ))
        .toList();
  }

  return const [];
}

String _modelDisplayName(String? modelId, {AxWorker? worker}) {
  if (modelId == null || modelId.trim().isEmpty) return '';
  final list =
      worker != null ? _modelsForWorker(worker) : const <AxModelOption>[];
  final found = list.where((m) => m.id == modelId).firstOrNull;
  if (found != null) return found.name;
  return modelId;
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

String _reasoningEffortDisplayName(String? effort) {
  if (effort == null || effort.trim().isEmpty) return '';
  return switch (effort.trim().toLowerCase()) {
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' || 'extra-high' => 'Extra High',
    'max' => 'Max',
    'ultra' => 'Ultra',
    _ => effort,
  };
}

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

Widget _workerIcon(BuildContext context, AxWorker worker) {
  final asset =
      WorkerPresentation.resolve(worker.workerTypeId, worker.displayName)
          .iconAsset;
  return SizedBox(
      width: 18,
      height: 18,
      child: asset != null
          ? Image.asset(asset,
              fit: BoxFit.contain, semanticLabel: '${worker.displayName} icon')
          : CircleAvatar(
              child: Text(
                  worker.displayName.isEmpty ? '?' : worker.displayName[0],
                  style: const TextStyle(fontSize: 10))));
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
    required this.localWorkProgress,
    required this.loadingTimeline,
    required this.timelineError,
    required this.submitError,
    required this.submitting,
    required this.awaitingResponse,
    required this.composerKey,
    required this.attachments,
    required this.onAddFiles,
    required this.onAddReference,
    required this.onRemoveAttachment,
    required this.onRefresh,
    required this.hasOlder,
    required this.loadingOlder,
    required this.onLoadOlder,
    required this.onShowRunDetails,
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
  final Map<String, String> localWorkProgress;
  final bool loadingTimeline;
  final String? timelineError;
  final String? submitError;
  final bool submitting;
  final bool awaitingResponse;
  final GlobalKey composerKey;
  final List<Map<String, dynamic>> attachments;
  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddReference;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onRefresh;
  final bool hasOlder;
  final bool loadingOlder;
  final Future<void> Function() onLoadOlder;
  final ValueChanged<String>? onShowRunDetails;
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
                return _WorkTimelineCard(
                  key: ValueKey(request.id),
                  request: request,
                  progressText: localWorkProgress[request.id],
                  currentUserId: currentUserId,
                  currentUserName: currentUserName,
                  workflowCatalog: workflowCatalog,
                  onShowRunDetails: localWorkProgress.containsKey(request.id)
                      ? null
                      : onShowRunDetails,
                  onRetryStep: localWorkProgress.containsKey(request.id)
                      ? null
                      : onRetryStep,
                  onCancelRun: localWorkProgress.containsKey(request.id)
                      ? null
                      : onCancelRun,
                );
              },
            ),
        ]));
  }

  AxWorker? get _assignedWorker {
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
    final workerId = binding['workerId']?.toString() ?? '';
    if (workerId.isEmpty) return null;
    return eligibleWorkers.where((w) => w.id == workerId).firstOrNull ??
        spaceWorkers.where((w) => w.id == workerId).firstOrNull;
  }

  bool get _isWorkerAssigned {
    final worker = _assignedWorker;
    return worker != null && eligibleWorkers.any((w) => w.id == worker.id);
  }

  Widget controls(BuildContext context) => _buildComposerInput(
      context,
      Theme.of(context).brightness == Brightness.dark,
      Theme.of(context).colorScheme);

  Widget _additionalControls(BuildContext context, GlobalKey inputKey) {
    final colors = Theme.of(context).colorScheme;
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
    final assignedWorker = _assignedWorker;
    final isWorkerAssigned = _isWorkerAssigned;
    final policy =
        selectedWorkflow?.executionPolicy ?? const AxWorkflowCapabilities();
    final selectedModel = binding['model']?.toString().trim() ?? '';
    final selectedReasoningEffort =
        binding['reasoningEffort']?.toString().trim() ?? '';
    final effortOptions = assignedWorker?.executionOptions
        ?.effortsForModel(selectedModel.isEmpty ? null : selectedModel);
    final supportedEfforts = effortOptions?.supported == true
        ? effortOptions!.values
        : const <String>[];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (buttonContext) => IconButton(
              tooltip: 'Add attachments',
              icon: const Icon(Icons.add, size: 18),
              onPressed: () async {
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
                    PopupMenuItem(
                      value: 'link',
                      enabled: canExecute && !submitting,
                      child: const ListTile(
                        dense: true,
                        leading: Icon(Icons.link, size: 18),
                        title: Text('Add link'),
                      ),
                    ),
                  ],
                );
                if (!buttonContext.mounted || value == null) return;
                if (value == 'files') {
                  onAddFiles();
                } else if (value == 'link') {
                  onAddReference();
                }
              },
            ),
          ),
          const SizedBox(width: 4),
          Builder(
            builder: (workflowBtnContext) => Tooltip(
              message: 'Choose workflow',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
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
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
          if (stepKind != null && policy.userSelectsWorker) ...[
            const SizedBox(width: 4),
            Builder(
                builder: (workerContext) => Tooltip(
                      message: 'Worker · configured in Workflows',
                      child: InkWell(
                        key: const ValueKey('work-composer-worker'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: null,
                        child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              if (assignedWorker != null) ...[
                                _workerIcon(context, assignedWorker),
                                const SizedBox(width: 4)
                              ],
                              ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 140),
                                  child: Text(
                                    assignedWorker?.displayName ??
                                        (binding['workerId'] == null
                                            ? 'Automatic'
                                            : 'Unavailable Worker'),
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color:
                                                binding['workerId'] == null ||
                                                        isWorkerAssigned
                                                    ? null
                                                    : colors.error),
                                  )),
                              const Icon(Icons.keyboard_arrow_down, size: 14),
                            ])),
                      ),
                    )),
          ],
          if (stepKind != null && isWorkerAssigned) ...[
            if (policy.userSelectsModel &&
                (assignedWorker?.executionOptions?.modelSelectionSupported ??
                    true)) ...[
              const SizedBox(width: 4),
              Builder(
                builder: (modelBtnContext) => Tooltip(
                  message: 'Model · configured in Workflows',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 130),
                            child: Text(
                              _modelDisplayName(selectedModel,
                                          worker: assignedWorker)
                                      .isEmpty
                                  ? 'Default model'
                                  : _modelDisplayName(selectedModel,
                                      worker: assignedWorker),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
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
            ],
            if (policy.userSelectsEffort && supportedEfforts.isNotEmpty) ...[
              const SizedBox(width: 4),
              Builder(
                builder: (reasoningBtnContext) => Tooltip(
                  message: 'Effort · configured in Workflows',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 110),
                            child: Text(
                              selectedReasoningEffort.isEmpty
                                  ? 'Default effort'
                                  : '${_reasoningEffortDisplayName(selectedReasoningEffort)} effort',
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
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
            ],
          ],
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
                !awaitingResponse &&
                !loadingWorkflows &&
                workflowCatalogError == null,
            additionalControlsBuilder: (inputKey) =>
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
                    avatar: Icon(
                      attachments[i]['kind'] == 'url'
                          ? Icons.link
                          : Icons.insert_drive_file,
                      size: 14,
                    ),
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
                'Up to 10 attachments. Files total 1 MB; links are passed as references.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          if (loadingWorkflows) const LinearProgressIndicator(),
          if (awaitingResponse && !submitting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                const Expanded(
                  child: Text(
                    'A previous request is still in progress. You can draft your next message or cancel the pending request.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                if (onCancelRun != null)
                  TextButton(
                    onPressed: () async {
                      for (final request in workTimeline.where((request) =>
                          const {'queued', 'running', 'waiting'}
                              .contains(request.status))) {
                        await onCancelRun!(request.id);
                      }
                    },
                    child: const Text('Cancel pending request'),
                  ),
              ]),
            ),
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
    this.progressText,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflowCatalog,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final AxWorkRequest request;
  final String? progressText;
  final String? currentUserId;
  final String? currentUserName;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final ValueChanged<String>? onShowRunDetails;
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

  String _totalElapsed() {
    final elapsed = request.steps
        .map((step) => step.elapsedMs)
        .whereType<int>()
        .fold<int>(0, (total, value) => total + value);
    return elapsed == 0 ? '' : _elapsed(elapsed);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final metaColor = isDark ? Colors.white38 : Colors.black45;

    final timestamp = DateTime.tryParse(request.createdAt)?.toLocal();
    final timeLabel = timestamp == null ? '' : _chatTimestamp(timestamp);
    final elapsed = _totalElapsed();
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
        ? _executionFailureMessage(failedStep?.errorCode,
            validationMessage: request.steps.isEmpty ? rawError : null)
        : null;
    final isError = error?.isNotEmpty == true;

    // Waiting/queued messages belong to Conclave. A running Step is the
    // product's worker execution signal; no final text is required to attribute it.
    final senderStep = activeStep?.status == 'running'
        ? activeStep
        : lastCompletedStep ?? stepForContext;
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
        (senderStep?.status == 'running' || response?.isNotEmpty == true) &&
        (workerDisplayName?.isNotEmpty == true ||
            workerType?.isNotEmpty == true);
    final senderName = isWorkerResponse ? workerName : 'Conclave';
    final workerIcon = presentation.iconAsset;

    String? formattedModelInfo;
    if (selectedModel != null && selectedModel.isNotEmpty) {
      final modelName = _modelDisplayName(selectedModel);
      if (selectedReasoningEffort != null &&
          selectedReasoningEffort.isNotEmpty) {
        formattedModelInfo =
            '$modelName · ${_reasoningEffortDisplayName(selectedReasoningEffort)}';
      } else {
        formattedModelInfo = modelName;
      }
    } else if (selectedReasoningEffort != null &&
        selectedReasoningEffort.isNotEmpty) {
      formattedModelInfo =
          'Default model · ${_reasoningEffortDisplayName(selectedReasoningEffort)}';
    }

    if (senderTurn != null) {
      final modelLabel = selectedModel?.isNotEmpty == true
          ? _modelDisplayName(selectedModel)
          : 'Default model';
      final effortLabel = selectedReasoningEffort?.isNotEmpty == true
          ? _reasoningEffortDisplayName(selectedReasoningEffort)
          : 'Default effort';
      formattedModelInfo = '$modelLabel · $effortLabel';
    }
    final metadataSegments = [
      if (_workflowName.isNotEmpty) _workflowName,
      if (elapsed.isNotEmpty) elapsed,
    ];
    final metadataString =
        metadataSegments.isEmpty ? '' : '· ${metadataSegments.join(' · ')}';

    final Widget senderAvatar = isWorkerResponse
        ? (workerIcon != null
            ? Image.asset(workerIcon,
                width: 22,
                height: 22,
                fit: BoxFit.contain,
                semanticLabel: '$workerName icon')
            : CircleAvatar(
                radius: 11,
                backgroundColor: ConclaveColors.primarySoftColor(isDark),
                child: Text(workerName.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                        fontSize: 12,
                        color: ConclaveColors.primaryForeground(isDark))),
              ))
        : Image.asset(
            ConclaveBrandAssets.logoPng32,
            width: 20,
            height: 20,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => Icon(
              Icons.auto_awesome,
              size: 14,
              color: ConclaveColors.primaryForeground(isDark),
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
                        ? ConclaveColors.primarySoftColor(isDark)
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
                          Tooltip(
                            message: 'Copy Markdown',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: request.prompt));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Prompt copied to clipboard'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.copy_rounded,
                                  size: 14,
                                  color: metaColor,
                                ),
                              ),
                            ),
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
                              color: isDark ? Colors.white : Colors.black87,
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
                          if (metadataString.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                metadataString,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    TextStyle(fontSize: 12, color: metaColor),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      Builder(builder: (context) {
                        final failedStep = request.steps
                            .where((step) => step.status == 'failed')
                            .firstOrNull;
                        final message = error?.isNotEmpty == true
                            ? error!
                            : response?.isNotEmpty == true
                                ? response!
                                : request.status == 'cancelled'
                                    ? 'Request cancelled.'
                                    : progressText ??
                                        switch (request.status) {
                                          'running' =>
                                            'Working on your request…',
                                          'waiting' => 'Waiting to continue…',
                                          'completed' => 'Request completed.',
                                          'failed' =>
                                            'Your request could not be completed.',
                                          _ => 'Preparing your request…',
                                        };
                        final isError = error?.isNotEmpty == true;
                        Widget compactAction({
                          required String tooltip,
                          required IconData icon,
                          required VoidCallback onPressed,
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
                                if (onShowRunDetails != null)
                                  compactAction(
                                    tooltip: 'View request details',
                                    icon: Icons.info_outline,
                                    onPressed: () =>
                                        onShowRunDetails!(request.id),
                                  ),
                                if (request.status == 'failed' &&
                                    failedStep != null &&
                                    onRetryStep != null)
                                  compactAction(
                                    tooltip: 'Retry request',
                                    icon: Icons.refresh,
                                    onPressed: () =>
                                        onRetryStep!(request.id, failedStep),
                                  ),
                                if ((request.status == 'queued' ||
                                        request.status == 'running') &&
                                    onCancelRun != null)
                                  compactAction(
                                    tooltip: 'Cancel request',
                                    icon: Icons.cancel_outlined,
                                    onPressed: () => onCancelRun!(request.id),
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

class _WorkRequestDetailsSheet extends StatelessWidget {
  const _WorkRequestDetailsSheet({
    required this.details,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final AxWorkRequestStatus details;
  final Future<void> Function(AxWorkRequestStep step) onRetryStep;
  final Future<void> Function() onCancelRun;

  String _workerName(AxWorkRequestStep step) =>
      step.workerDisplayName ?? 'Worker';

  String _timestamp(String? value) {
    if (value == null) return '—';
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return '—';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
        '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
  }

  String _duration(int? milliseconds) {
    if (milliseconds == null) return '—';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.88,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('Request details',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Text(
                  'Status · ${details.status}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Builder(builder: (context) {
                  final rawDetailName = details.requestedByName?.trim();
                  final displayDetailName = (rawDetailName == null ||
                          rawDetailName.isEmpty ||
                          rawDetailName == details.requestedByUserId ||
                          rawDetailName.startsWith('usr_'))
                      ? (details.requestedByUserId?.isNotEmpty == true
                          ? 'Team member'
                          : null)
                      : rawDetailName;
                  if (displayDetailName == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Requested by $displayDetailName'),
                  );
                }),
                const SizedBox(height: 16),
                Text('Original request',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                ConclaveMarkdownBody(
                    data: details.originalRequest?.isNotEmpty == true
                        ? details.originalRequest!
                        : 'No request text was recorded.'),
                const SizedBox(height: 20),
                for (final turn in details.turns.where((turn) => !details.steps
                    .any(
                        (step) => step.assignmentId == turn.assignmentId))) ...[
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Earlier attempt · ${turn.workerDisplayName}',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              Text(
                                  '${turn.modelId == null ? 'Default model' : _modelDisplayName(turn.modelId)} · ${turn.effort == null ? 'Default effort' : _reasoningEffortDisplayName(turn.effort)} · ${turn.status}'),
                              if (turn.resultText?.isNotEmpty == true) ...[
                                const SizedBox(height: 8),
                                ConclaveMarkdownBody(data: turn.resultText!),
                              ],
                            ],
                          ))),
                ],
                for (final step in details.steps) ...[
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(_workerName(step),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              Text(step.status),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            [
                              if (step.model?.isNotEmpty == true)
                                step.reasoningEffort?.isNotEmpty == true
                                    ? '${_modelDisplayName(step.model)} (${_reasoningEffortDisplayName(step.reasoningEffort).toLowerCase()})'
                                    : _modelDisplayName(step.model)
                              else if (step.reasoningEffort?.isNotEmpty == true)
                                'Reasoning: ${_reasoningEffortDisplayName(step.reasoningEffort).toLowerCase()}',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 18,
                            runSpacing: 6,
                            children: [
                              Text('Started · ${_timestamp(step.startedAt)}'),
                              Text('Ended · ${_timestamp(step.completedAt)}'),
                              Text('Duration · ${_duration(step.elapsedMs)}'),
                            ],
                          ),
                          if (step.resultText?.isNotEmpty == true) ...[
                            const Divider(height: 24),
                            Text('Result',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 6),
                            ConclaveMarkdownBody(data: step.resultText!),
                          ] else if (step.status == 'failed') ...[
                            const Divider(height: 24),
                            SelectableText(
                              _executionFailureMessage(
                                  step.errorCode ?? details.errorCode),
                              style: ConclaveMessageTypography.fromTheme(
                                      Theme.of(context))
                                  .copyWith(color: colors.error),
                            ),
                            if (details.status == 'failed') ...[
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () => onRetryStep(step),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry request'),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                if (details.status == 'failed' && details.steps.isEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(_executionFailureMessage(details.errorCode),
                      style: TextStyle(color: colors.error)),
                ],
                if (details.status == 'failed' ||
                    details.status == 'queued' ||
                    details.status == 'running') ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onCancelRun,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel request'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscussionItem {
  const _DiscussionItem({
    required this.id,
    required this.author,
    required this.text,
    this.sentAt,
    this.isMe = true,
  });

  final String id;
  final String author;
  final String text;
  final String? sentAt;
  final bool isMe;
}

class _DiscussionMessageBubble extends StatefulWidget {
  const _DiscussionMessageBubble({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onEdit,
  });

  final _DiscussionItem item;
  final VoidCallback onCopy;
  final ValueChanged<String> onEdit;

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
                    ? ConclaveColors.primarySoftColor(isDark)
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
                        if (widget.item.sentAt != null) ...[
                          Text(
                            widget.item.sentAt!,
                            style: TextStyle(
                              fontSize: 11,
                              color: metaColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (!widget.item.id.startsWith('temp-'))
                          Tooltip(
                            message: 'Edit message',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () => setState(() {
                                _editController.text = widget.item.text;
                                _isEditing = true;
                              }),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.edit_outlined,
                                  size: 14,
                                  color: metaColor,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'Copy Markdown',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: widget.onCopy,
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                Icons.copy_rounded,
                                size: 14,
                                color: metaColor,
                              ),
                            ),
                          ),
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

// Own-message metadata follows reading order toward the right edge.
extension _MessageFooterOrder on List<Widget> {
  List<Widget> orderedForMessage(bool own) => own ? this : reversed.toList();
}

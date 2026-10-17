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
      'context_limit_exceeded' =>
        'This conversation exceeds the supported context limit. Start a new Thread with the relevant context.',
      'session_resume_failed' =>
        'The worker could not continue the previous conversation. Please retry your request.',
      'worker_not_ready' =>
        'The selected worker is not ready on its workspace.',
      'space_folder_exists' => 'Retry to choose whether to use it.',
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

/// Cloud's fixed public failure category, with the code-specific guidance
/// appended only when the code says more than the category already does.
String _publicFailureMessage(AxWorkRequestStep? step, String guidance) {
  final headline = step?.failureCategoryMessage?.trim();
  if (headline == null || headline.isEmpty) return guidance;
  final code = step?.errorCode;
  if (code == null ||
      code == 'execution_failed' ||
      code == 'timeout' ||
      code == 'context_limit_exceeded') {
    return headline;
  }
  return '$headline. $guidance';
}

Future<T?> _showAnchoredMenu<T>({
  required BuildContext buttonContext,
  required List<PopupMenuEntry<T>> items,
  required double itemHeight,
  int dividerCount = 0,
}) async {
  final isDark = Theme.of(buttonContext).brightness == Brightness.dark;
  final box = buttonContext.findRenderObject()! as RenderBox;
  // showMenu positions against the Navigator's overlay, so measure there.
  final overlay = Navigator.of(buttonContext)
      .overlay!
      .context
      .findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final anchorBottom = rect.top - 8;
  final availableHeight = (anchorBottom - 8).clamp(0.0, overlay.size.height);
  // Measure the real rows offstage; fixed per-row estimates drift with
  // density and icon sizes.
  final measureKey = GlobalKey();
  final entry = OverlayEntry(
    builder: (_) => Offstage(
      child: Align(
        alignment: Alignment.topLeft,
        child: Material(
          child: Theme(
            data: Theme.of(buttonContext),
            child: Padding(
              key: measureKey,
              padding: ConclaveMenuStyle.padding,
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in items)
                      item is ConclaveMenuEntry<T>
                          ? item.child
                          : SizedBox(height: item.height),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Overlay.of(buttonContext).insert(entry);
  await WidgetsBinding.instance.endOfFrame;
  final measured = (measureKey.currentContext?.findRenderObject() as RenderBox?)
          ?.size
          .height ??
      (items.length - dividerCount) * itemHeight + 12.0;
  entry.remove();
  entry.dispose();
  if (!buttonContext.mounted) return null;
  final menuHeight = measured.clamp(0.0, availableHeight);
  return showMenu<T>(
    context: buttonContext,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    color: ConclaveColors.composerBackground(isDark),
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: ConclaveMenuStyle.shadow(isDark),
    shape: ConclaveMenuStyle.shape(isDark),
    menuPadding: ConclaveMenuStyle.padding,
    constraints: BoxConstraints(minHeight: menuHeight, maxHeight: menuHeight),
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
    required this.incomingAnchor,
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
    required this.realtimeStatus,
    required this.localWorkProgress,
    required this.loadingTimeline,
    required this.timelineError,
    required this.submitError,
    required this.submitting,
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
    this.usageController,
  });

  final TextEditingController requestController;
  final ScrollController historyController;
  final AxTimelineFollowAnchor incomingAnchor;
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
  final AxWorkRealtimeStatus realtimeStatus;
  final Map<String, String> localWorkProgress;
  final bool loadingTimeline;
  final String? timelineError;
  final String? submitError;
  final bool submitting;
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

  /// Local view state for the Worker usage card; null when the data source
  /// cannot read usage.
  final AxWorkerUsageController? usageController;

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
    final empty = workTimeline.isEmpty &&
            !loadingTimeline &&
            timelineError == null
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
        : null;
    return AxTimelineContainer(
      scrollKey: const ValueKey('work-history-scroll'),
      controller: historyController,
      headerSlivers: [
        if (hasOlder)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: loadingOlder ? null : onLoadOlder,
              child: Text(loadingOlder
                  ? 'Loading older Work history…'
                  : 'Load older Work history'),
            ),
          ),
        if (timelineError != null && workTimeline.isNotEmpty)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: onRefresh,
              child: const Text('Retry Work sync'),
            ),
          ),
        if (loadingTimeline && workTimeline.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: LinearProgressIndicator(),
            ),
          )
        else if (timelineError != null && workTimeline.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Could not load Work history: $timelineError',
                style: TextStyle(color: colors.error),
              ),
            ),
          ),
      ],
      itemCount: workTimeline.length,
      empty: empty,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = workTimeline.indexWhere((r) => r.id == key.value);
        return index < 0 ? null : index;
      },
      itemBuilder: (context, index) {
        final request = workTimeline[index];
        return ListenableBuilder(
          key: ValueKey(request.id),
          listenable: activityStore.listenableForRequest(request),
          builder: (context, _) => KeyedSubtree(
            key: incomingAnchor.keyFor((request.id, 'request')),
            child: MessageDayBoundary(
              date: DateTime.tryParse(request.createdAt)?.toLocal(),
              previousDate: index == 0
                  ? null
                  : DateTime.tryParse(workTimeline[index - 1].createdAt)
                      ?.toLocal(),
              child: _WorkTimelineCard(
                responseAnchorKey:
                    incomingAnchor.keyFor((request.id, 'response')),
                request: request,
                activities: activityStore.forRequest(request),
                clockOffset: activityStore.clockOffsetForRequest(request),
                realtimeStatus: realtimeStatus,
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
            ),
          ),
        );
      },
    );
  }

  Widget controls(BuildContext context) => _buildComposerInput(
      context,
      Theme.of(context).brightness == Brightness.dark,
      Theme.of(context).colorScheme);

  AxBuiltinWorkflow? _selectedWorkflow() =>
      workflowCatalog.where((item) => item.reference == workflow).firstOrNull ??
      workflowCatalog
          .where((item) => item.id == workflow.split(':').first)
          .firstOrNull;

  Map<String, dynamic> _stepBinding() {
    final bindings = workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final stepKind = _selectedWorkflow()?.composerBindingId;
    final rawBinding = stepKind == null ? null : bindings[stepKind];
    return rawBinding is Map
        ? Map<String, dynamic>.from(rawBinding)
        : <String, dynamic>{};
  }

  String? _selectedWorkerId() => (executionSelection.containsKey('workerId')
          ? executionSelection['workerId']
          : _stepBinding()['workerId'])
      ?.toString()
      .trim();

  Widget _additionalControls(BuildContext context) {
    final selectedWorkflow = _selectedWorkflow();
    final binding = _stepBinding();
    final policy =
        selectedWorkflow?.executionPolicy ?? const AxWorkflowCapabilities();
    final selectedWorkerId = _selectedWorkerId();
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
            builder: (buttonContext) => Semantics(
              key: const ValueKey('work-add-attachments'),
              label: 'Add attachments',
              child: Material(
                color: controlBg,
                borderRadius: controlBorderRadius,
                child: InkWell(
                  borderRadius: controlBorderRadius,
                  onTap: () async {
                    final value = await _showAnchoredMenu<String>(
                      buttonContext: buttonContext,
                      itemHeight: 36.0,
                      items: [
                        ConclaveMenuEntry<String>(
                          value: 'files',
                          child: MenuItemButton(
                            style: ConclaveMenuStyle.item(
                                Theme.of(context).brightness ==
                                    Brightness.dark),
                            leadingIcon:
                                const Icon(Icons.attach_file, size: 16),
                            onPressed: canExecute && !submitting
                                ? () => Navigator.pop(buttonContext, 'files')
                                : null,
                            child: const Text('Add files',
                                style: ConclaveMenuStyle.textStyle),
                          ),
                        ),
                        if (usageController?.supported ?? false)
                          ConclaveMenuEntry<String>(
                            value: 'usage',
                            child: MenuItemButton(
                              key: const ValueKey('work-menu-usage'),
                              style: ConclaveMenuStyle.item(
                                  Theme.of(context).brightness ==
                                      Brightness.dark),
                              leadingIcon: const Icon(Icons.speed, size: 16),
                              onPressed: () =>
                                  Navigator.pop(buttonContext, 'usage'),
                              child: const Text('Usage',
                                  style: ConclaveMenuStyle.textStyle),
                            ),
                          ),
                      ],
                    );
                    if (!buttonContext.mounted || value == null) return;
                    if (value == 'files') {
                      onAddFiles();
                    } else if (value == 'usage') {
                      _runComposerCommand(_usageCommand);
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
            builder: (workflowBtnContext) => Semantics(
              key: const ValueKey('work-choose-workflow'),
              label: 'Choose workflow',
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
                            itemHeight: 36.0,
                            items: [
                              for (final item in versions)
                                ConclaveMenuEntry<String>(
                                  value: item.reference,
                                  child: Semantics(
                                    label: item.description,
                                    child: MenuItemButton(
                                      style: ConclaveMenuStyle.item(
                                          Theme.of(context).brightness ==
                                              Brightness.dark),
                                      leadingIcon: Icon(
                                        item.reference == workflow
                                            ? Icons.check_circle_rounded
                                            : Icons.circle_outlined,
                                        size: 15,
                                      ),
                                      onPressed: () => Navigator.pop(
                                          workflowBtnContext, item.reference),
                                      child: Text(item.name,
                                          style: ConclaveMenuStyle.textStyle),
                                    ),
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
            immediatePopup: true,
            workerIconBuilder: (capability) {
              final worker = eligibleWorkers
                  .where((w) => w.id == capability.id)
                  .firstOrNull;
              final asset = WorkerPresentation.resolve(
                      worker?.workerTypeId, capability.name)
                  .iconAsset;
              return asset == null
                  ? const Icon(Icons.smart_toy_outlined, size: 22)
                  : Image.asset(asset, width: 22, height: 22);
            },
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
            catalog: AxWorkflowSelectionOptions(eligibleWorkers).sharedCatalog,
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

  /// Runs a composer command against the Worker selected for the current Step.
  void _runComposerCommand(_ComposerCommand command) {
    final controller = usageController;
    if (controller == null || command.id != _usageCommand.id) return;
    final selectedId = _selectedWorkerId();
    final worker = [...spaceWorkers, ...eligibleWorkers]
        .where((item) => item.id == selectedId)
        .firstOrNull;
    if (worker == null) {
      controller.showMessage('Choose a Worker to read its usage.');
      return;
    }
    controller.load(
      workspaceId: worker.workspaceId,
      workerId: worker.id,
      workerName: worker.displayName,
    );
  }

  /// A message that is exactly one known `/command` runs it instead of being
  /// sent as a request. Any other text, including paths such as `/etc/hosts`,
  /// is sent normally.
  bool _tryRunSlashCommand() {
    if (!(usageController?.supported ?? false)) return false;
    final text = requestController.text.trim();
    if (!RegExp(r'^/[a-z]+$').hasMatch(text)) return false;
    final matches = _composerCommands
        .where((command) => command.id.startsWith(text.substring(1)))
        .toList();
    if (matches.length != 1) return false;
    requestController.clear();
    _runComposerCommand(matches.single);
    return true;
  }

  Widget _buildComposerInput(
    BuildContext context,
    bool isDark,
    ColorScheme colors,
  ) {
    return Container(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (usageController != null)
            AxWorkerUsagePanel(
              controller: usageController!,
              onRefresh: () => _runComposerCommand(_usageCommand),
            ),
          if (usageController?.supported ?? false)
            _SlashCommandPalette(
              textController: requestController,
              commands: _composerCommands,
              onSelected: (command) {
                requestController.clear();
                _runComposerCommand(command);
              },
            ),
          MarkdownComposer(
            controller: requestController,
            hintText: 'Write a message...',
            chatStyle: true,
            minLines: 1,
            maxLines: 6,
            enabled: canExecute,
            onSend: () {
              if (_tryRunSlashCommand()) return;
              onRun();
            },
            sendTooltip: 'Send request',
            showSendTooltip: false,
            sendEnabled: canExecute &&
                !submitting &&
                !loadingWorkflows &&
                workflowCatalogError == null,
            showMarkdownControls: false,
            showMarkdownControlsInSuffix: true,
            showSendInSuffix: true,
            sendInToolbar: true,
            executionControlsBuilder: (_) => _additionalControls(context),
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
                'Up to 10 file attachments, 2 MB each.',
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
                    ScaffoldMessenger.of(context).showNotice(
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

/// A command available from the `/` palette and the `+` menu. Commands are
/// local to the composer: they never create a Work Request.
class _ComposerCommand {
  const _ComposerCommand({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
  });

  final String id;
  final String label;
  final String description;
  final IconData icon;
}

const _usageCommand = _ComposerCommand(
  id: 'usage',
  label: 'Usage',
  description: 'Show the selected Worker\'s usage and limits',
  icon: Icons.speed,
);

const _composerCommands = <_ComposerCommand>[_usageCommand];

/// Lists matching commands while the composer holds a lone `/word`.
class _SlashCommandPalette extends StatelessWidget {
  const _SlashCommandPalette({
    required this.textController,
    required this.commands,
    required this.onSelected,
  });

  final TextEditingController textController;
  final List<_ComposerCommand> commands;
  final ValueChanged<_ComposerCommand> onSelected;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: textController,
        builder: (context, value, _) {
          final text = value.text;
          if (!RegExp(r'^/[a-z]*$').hasMatch(text)) {
            return const SizedBox.shrink();
          }
          final matches = commands
              .where((command) => command.id.startsWith(text.substring(1)))
              .toList();
          if (matches.isEmpty) return const SizedBox.shrink();
          final colors = Theme.of(context).colorScheme;
          return Padding(
            key: const ValueKey('slash-command-palette'),
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final command in matches)
                    ListTile(
                      key: ValueKey('slash-command-${command.id}'),
                      dense: true,
                      leading: Icon(command.icon, size: 18),
                      title: Text('/${command.id}',
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(command.description,
                          style: const TextStyle(fontSize: 12)),
                      onTap: () => onSelected(command),
                    ),
                ],
              ),
            ),
          );
        },
      );
}

/// Shows a normalized usage table, or the report exactly as the Worker printed
/// it when it cannot be normalized or the user asks for the original.
class AxWorkerUsagePanel extends StatelessWidget {
  const AxWorkerUsagePanel(
      {super.key, required this.controller, required this.onRefresh});

  final AxWorkerUsageController controller;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.visible) return const SizedBox.shrink();
          final colors = Theme.of(context).colorScheme;
          final report = controller.report;
          final message = controller.message;
          final text = report == null
              ? ''
              : report.isOk
                  ? report.displayText
                  : report.status == 'unavailable'
                      ? 'This Worker does not provide a usage report.'
                      : (report.errorMessage ?? 'Usage could not be read.');
          final parsed = report != null && report.isOk
              ? parseWorkerUsage(report.output, now: report.fetchedAt)
              : null;
          final showTable = parsed != null && !controller.showOriginal;
          return Container(
            key: const ValueKey('worker-usage-panel'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Icon(Icons.speed, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${controller.workerName ?? 'Worker'} usage',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (report?.fetchedAt != null && !controller.loading)
                    Text(
                      'as of ${TimeOfDay.fromDateTime(report!.fetchedAt!.toLocal()).format(context)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (parsed != null && !controller.loading)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Semantics(
                        link: true,
                        child: InkWell(
                          key: const ValueKey('worker-usage-toggle-original'),
                          onTap: controller.toggleOriginal,
                          mouseCursor: SystemMouseCursors.click,
                          child: Text(
                            controller.showOriginal ? 'Summary' : 'Original',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Refresh usage',
                    icon: const Icon(Icons.refresh, size: 16),
                    onPressed: controller.loading ? null : onRefresh,
                  ),
                  IconButton(
                    tooltip: 'Close usage',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: controller.dismiss,
                  ),
                ]),
                if (controller.loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  )
                else if (message != null)
                  Text(message, style: const TextStyle(fontSize: 12))
                else if (showTable)
                  AxLiveTicker(
                    active: parsed.windows.any((w) => w.resetsAt != null),
                    builder: (context, now) =>
                        _UsageTable(usage: parsed, now: now),
                  )
                else ...[
                  if (report != null && report.isOk)
                    Text(
                        controller.showOriginal
                            ? 'Original output'
                            : 'Could not summarize this report. Original '
                                'output:',
                        key: const ValueKey('worker-usage-unparsed'),
                        style: Theme.of(context).textTheme.bodySmall),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        text,
                        key: const ValueKey('worker-usage-text'),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: report != null && !report.isOk
                              ? colors.error
                              : null,
                        ),
                      ),
                    ),
                  ),
                ],
                if (report?.truncated ?? false)
                  Text('Output was shortened.',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          );
        },
      );
}

class _UsageTable extends StatelessWidget {
  const _UsageTable({required this.usage, required this.now});

  final AxParsedUsage usage;

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final dark = Theme.of(context).brightness == Brightness.dark;
    String? group;
    final children = <Widget>[];
    for (final window in usage.windows) {
      if (window.group != null && window.group != group) {
        group = window.group;
        children.add(Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(group!,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ));
      }
      children.add(Padding(
        key: ValueKey('worker-usage-row-${window.group ?? ''}-${window.label}'),
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
              width: 70,
              child: Text(window.label, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: LinearProgressIndicator(
                value: (window.usedPercent / 100).clamp(0.0, 1.0),
                color: ConclaveColors.primaryForeground(dark),
                backgroundColor: dark ? const Color(0xFF252525) : Colors.white,
                stopIndicatorColor: Colors.transparent,
                minHeight: 6,
                semanticsLabel: '${window.group ?? ''} ${window.label} usage',
                semanticsValue: '${window.usedPercent.round()}%'),
          ),
          SizedBox(
            width: 84,
            child: Text('${window.usedPercent.round()}% used',
                textAlign: TextAlign.end, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          Flexible(
              flex: 2,
              child: Text(usageResetLabel(window, now),
                  overflow: TextOverflow.ellipsis, style: small)),
        ]),
      ));
    }
    for (final note in usage.notes) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(note, style: small),
      ));
    }
    return Column(
        key: const ValueKey('worker-usage-table'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children);
  }
}

/// Keeps the parsed Markdown subtree stable while the surrounding Work card
/// receives activity/status updates. A changed source intentionally replaces
/// the child so selection handles cannot refer to stale response text.
class _MemoizedWorkMarkdown extends StatefulWidget {
  const _MemoizedWorkMarkdown({
    super.key,
    required this.data,
    this.fitContent = false,
  });

  final String data;
  final bool fitContent;

  @override
  State<_MemoizedWorkMarkdown> createState() => _MemoizedWorkMarkdownState();
}

class _MemoizedWorkMarkdownState extends State<_MemoizedWorkMarkdown> {
  late Widget _body;

  Widget _createBody() => ConclaveMarkdownBody(
        key: widget.key,
        data: widget.data,
        fitContent: widget.fitContent,
      );

  @override
  void initState() {
    super.initState();
    _body = _createBody();
  }

  @override
  void didUpdateWidget(covariant _MemoizedWorkMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.fitContent != widget.fitContent) {
      _body = _createBody();
    }
  }

  @override
  Widget build(BuildContext context) => _body;
}

String? _workResponseText(AxWorkRequest request) =>
    request.finalText?.trim().isNotEmpty == true
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

class _WorkTimelineCard extends StatelessWidget {
  const _WorkTimelineCard({
    this.responseAnchorKey,
    required this.request,
    required this.activities,
    required this.realtimeStatus,
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

  final GlobalKey? responseAnchorKey;
  final AxWorkRequest request;
  final List<AxWorkActivity> activities;
  final AxWorkRealtimeStatus realtimeStatus;
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
    final response = _workResponseText(request);
    // Cloud's phase of the step that currently matters. A terminal request
    // always wins, so a delayed step event can never show it as running.
    final requestIsTerminal =
        AxWorkProgress.terminalStatuses.contains(request.status);
    final activeSteps = request.steps
        .where((step) => !AxExecutionPhase.isTerminal(step.effectivePhase))
        .toList();
    final phaseStep = activeSteps
            .where((step) => step.effectivePhase == AxExecutionPhase.uncertain)
            .firstOrNull ??
        activeSteps
            .where((step) => step.effectivePhase == AxExecutionPhase.running)
            .firstOrNull ??
        activeSteps
            .where((step) => step.effectivePhase == AxExecutionPhase.starting)
            .firstOrNull ??
        activeSteps.firstOrNull;
    final executionPhase = requestIsTerminal
        ? request.status
        : (phaseStep?.effectivePhase ?? request.executionPhase);
    final rawError = request.error?.trim().isNotEmpty == true
        ? request.error!
        : failedStep?.errorMessage;
    final error = request.status == 'failed' || rawError?.isNotEmpty == true
        ? _publicFailureMessage(
            failedStep,
            _executionFailureMessage(
              failedStep?.errorCode,
              validationMessage: failedStep == null ? rawError : null,
            ),
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
          executionPhase: executionPhase,
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
    final hasWorkerIdentity =
        workerDisplayName?.isNotEmpty == true || workerType?.isNotEmpty == true;
    final isPreStart =
        const {'queued', 'starting', 'acknowledged'}.contains(request.status) ||
            (!requestIsTerminal &&
                AxExecutionPhase.isKnown(executionPhase) &&
                !AxExecutionPhase.isExecuting(executionPhase));
    final isWorkerResponse = !isError &&
        hasWorkerIdentity &&
        (isPreStart ||
            progress.isExecuting ||
            senderStep?.status == 'running' ||
            response?.isNotEmpty == true);
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
                    style: TextStyle(fontSize: 12, color: metaColor)),
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
                      CollapsibleOwnMessage(
                        key: ValueKey(request.id),
                        data: request.prompt,
                        enabled: isOwnRequest,
                        toggleColor: metaColor,
                        crossAxisAlignment: isOwnRequest
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        child: _MemoizedWorkMarkdown(
                          data: request.prompt,
                          fitContent: true,
                        ),
                        footerBuilder: (context, toggle) => _messageFooter(
                            toggle,
                            [
                              if (timeLabel.isNotEmpty) ...[
                                Text(
                                  timeLabel,
                                  style:
                                      TextStyle(fontSize: 11, color: metaColor),
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
                            ].orderedForMessage(isOwnRequest)),
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
                                active: progress.isTicking &&
                                    realtimeStatus !=
                                        AxWorkRealtimeStatus.checking,
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
                      if (activities.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _WorkActivityTrail(
                          activities: activities,
                          color: metaColor,
                          accentColor: colors.primary,
                        ),
                      ],
                      const SizedBox(height: 10),
                      Builder(builder: (context) {
                        // The body shows the Worker's live status while the
                        // request is unfinished and the real outcome at the end.
                        final String? message = realtimeStatus ==
                                    AxWorkRealtimeStatus.checking &&
                                !progress.isTerminal
                            ? 'Connection interrupted — checking execution status.'
                            : error?.isNotEmpty == true
                                ? error
                                : response?.isNotEmpty == true
                                    ? response
                                    : request.status == 'cancelled'
                                        ? 'Request cancelled.'
                                        : (progress.isExecuting
                                                ? null
                                                : progressText) ??
                                            switch (request.status) {
                                              'completed' =>
                                                'Request completed.',
                                              'failed' =>
                                                'Your request could not be completed.',
                                              'timed_out' =>
                                                'The worker took too long to respond. Please retry your request.',
                                              'lost' =>
                                                'The connection to the worker was lost. Please retry your request.',
                                              _ => null,
                                            };
                        final showLiveStatus = message == null &&
                            !progress.isTerminal &&
                            realtimeStatus != AxWorkRealtimeStatus.checking;
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
                                active: progress.isTicking &&
                                    realtimeStatus !=
                                        AxWorkRealtimeStatus.checking,
                                builder: (context, now) {
                                  final live = resolveProgress(now);
                                  final text = live.currentAction ?? '';
                                  // The label only adds information while
                                  // the request is waiting. Once the Worker
                                  // is starting or running, the action says
                                  // it ("Working…"), so repeating "Running ·"
                                  // would be noise.
                                  final labelled = AxExecutionPhase.isKnown(
                                              executionPhase) &&
                                          !live.isExecuting &&
                                          executionPhase !=
                                              AxExecutionPhase.starting
                                      ? '${live.statusLabel} · $text'
                                      : text;
                                  return AxSettledStatusText(
                                    key: const ValueKey('work-live-status'),
                                    text: live.isStale
                                        ? '$labelled · no recent updates'
                                        : labelled,
                                    // Pre-start phases change within a few
                                    // hundred milliseconds; settle them. A
                                    // running provider, new Worker activity
                                    // and recovery notices show at once.
                                    urgent: live.isExecuting || !isPreStart,
                                    style: ConclaveMessageTypography.fromTheme(
                                            Theme.of(context))
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
                              KeyedSubtree(
                                key: responseAnchorKey,
                                child: isError
                                    ? SelectableText(
                                        message,
                                        style:
                                            ConclaveMessageTypography.fromTheme(
                                                    Theme.of(context))
                                                .copyWith(color: colors.error),
                                      )
                                    : _MemoizedWorkMarkdown(
                                        key: ValueKey((request.id, message)),
                                        data: message,
                                      ),
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
                                    failedStep != null &&
                                    failedStep.retryAllowed &&
                                    onRetryStep != null)
                                  compactAction(
                                    tooltip: failedStep.errorCode ==
                                            'space_folder_exists'
                                        ? 'Use the existing folder and retry'
                                        : failedStep.retryRequiresConfirmation
                                            ? 'Retry anyway — the previous execution may already have made changes'
                                            : 'Retry',
                                    icon: Icons.refresh_rounded,
                                    onPressed: () =>
                                        onRetryStep!(request.id, failedStep),
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
/// "Ran a command · git status": the row title plus the short `summary` the
/// Worker attached (a file name, a search term, the start of a command).
String _activityLabel(AxWorkActivity activity) {
  final summary = activity.details['summary'];
  if (summary is! String || summary.trim().isEmpty) return activity.title;
  return '${activity.title} · ${summary.trim()}';
}

class _WorkActivityTrail extends StatelessWidget {
  const _WorkActivityTrail({
    required this.activities,
    required this.color,
    required this.accentColor,
  });

  final List<AxWorkActivity> activities;
  final Color color;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final active = activities.where((item) => !item.isFinished).lastOrNull;
    final completedAll = activities.where((item) => item.isFinished).toList();
    final completed = completedAll.length <= 4
        ? completedAll
        : completedAll.sublist(completedAll.length - 4);
    if (active == null && completed.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (active != null)
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: accentColor,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _activityLabel(active),
                    key: const ValueKey('work-active-activity'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          if (completed.isNotEmpty) ...[
            if (active != null) const SizedBox(height: 6),
            for (final item in completed)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(
                      item.isError
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 14,
                      color: item.isError ? Colors.redAccent : color,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _activityLabel(item),
                        key: ValueKey('work-completed-${item.eventId}'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: color),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Live status line that does not flicker through short-lived pre-start
/// phases. See [AxStatusSettler] for the rules. Errors, a running provider
/// and new Worker activity are passed with [urgent] and show immediately.
class AxSettledStatusText extends StatefulWidget {
  const AxSettledStatusText({
    super.key,
    required this.text,
    required this.urgent,
    this.style,
    this.clock,
    this.settleDelay = const Duration(milliseconds: 700),
    this.minDisplay = const Duration(milliseconds: 600),
  });

  final String text;
  final bool urgent;
  final TextStyle? style;

  /// Overrides the wall clock; used by tests.
  final DateTime Function()? clock;
  final Duration settleDelay;
  final Duration minDisplay;

  @override
  State<AxSettledStatusText> createState() => _AxSettledStatusTextState();
}

class _AxSettledStatusTextState extends State<AxSettledStatusText> {
  late final AxStatusSettler _settler = AxStatusSettler(
    settleDelay: widget.settleDelay,
    minDisplay: widget.minDisplay,
  );
  Timer? _timer;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _settler.update(widget.text, _now(), urgent: widget.urgent);
    _timer?.cancel();
    _timer = null;
    final wait = _settler.nextCheck;
    if (wait != null) {
      _timer = Timer(wait, () {
        if (mounted) setState(() {});
      });
    }
    return Text(shown ?? '', style: widget.style);
  }
}

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

bool _continuesDiscussionGroup(List<_DiscussionItem> items, int index) {
  if (index <= 0) return false;
  final item = items[index];
  final previous = items[index - 1];
  return continuesMessageGroup(
    authorId: item.authorId,
    previousAuthorId: previous.authorId,
    sentAt: item.date,
    previousSentAt: previous.date,
    confirmed: !item.id.startsWith('temp-'),
    previousConfirmed: !previous.id.startsWith('temp-'),
  );
}

class _DiscussionItem {
  const _DiscussionItem({
    required this.id,
    required this.author,
    required this.text,
    this.authorId,
    this.date,
    this.sentAt,
    this.editedAt,
    this.isMe = true,
  });

  final String id;
  final String author;
  final String? authorId;
  final DateTime? date;
  final String text;
  final String? sentAt;
  final String? editedAt;
  final bool isMe;
}

class _DiscussionMessageBubble extends StatefulWidget {
  const _DiscussionMessageBubble({
    required this.item,
    required this.onCopy,
    required this.onEdit,
    this.grouped = false,
    this.onDelete,
  });

  final _DiscussionItem item;
  final bool grouped;
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
                  if (!isMe && !widget.grouped) ...[
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
                    CollapsibleOwnMessage(
                      data: widget.item.text,
                      enabled: isMe,
                      toggleColor: metaColor,
                      footerGap: 8,
                      crossAxisAlignment: isMe
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      child: ConclaveMarkdownBody(
                        data: widget.item.text,
                        fitContent: true,
                      ),
                      footerBuilder: (context, toggle) => _messageFooter(
                          toggle,
                          [
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
                          ].orderedForMessage(isMe)),
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

/// Meta line under a message. With a Show more / Hide more [toggle] it spans the
/// bubble: toggle at the left edge, date/time and actions at the right edge.
Widget _messageFooter(Widget? toggle, List<Widget> meta) {
  final items = Wrap(
    alignment: toggle != null ? WrapAlignment.end : WrapAlignment.start,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: meta,
  );
  if (toggle == null) return items;
  return Row(children: [
    toggle,
    const SizedBox(width: 8),
    Expanded(child: items),
  ]);
}

part of '../projects_pages.dart';

Widget _workflowOption(
  BuildContext context,
  AxBuiltinWorkflow workflow,
) =>
    ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SizedBox(
        height: 54,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: workflow.name),
                const TextSpan(text: '  —  '),
                TextSpan(
                  text: workflow.description,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

class _WorkComposer extends StatelessWidget {
  const _WorkComposer({
    required this.requestController,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflow,
    required this.workflowCatalog,
    required this.loadingWorkflows,
    required this.workflowCatalogError,
    required this.canExecute,
    this.canConfigureWork = true,
    required this.workTimeline,
    required this.loadingTimeline,
    required this.timelineError,
    required this.submitError,
    required this.submitting,
    required this.attachments,
    required this.onAddFiles,
    required this.onAddReference,
    required this.onRemoveAttachment,
    required this.onRefresh,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
    required this.onWorkflowChanged,
    this.onOpenSettings,
    required this.onRun,
  });

  final TextEditingController requestController;
  final String? currentUserId;
  final String? currentUserName;
  final String workflow;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final bool loadingWorkflows;
  final String? workflowCatalogError;
  final bool canExecute;
  final bool canConfigureWork;
  final List<AxWorkRequest> workTimeline;
  final bool loadingTimeline;
  final String? timelineError;
  final String? submitError;
  final bool submitting;
  final List<Map<String, dynamic>> attachments;
  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddReference;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onRefresh;
  final ValueChanged<String>? onShowRunDetails;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;
  final ValueChanged<String> onWorkflowChanged;
  final VoidCallback? onOpenSettings;
  final Future<void> Function() onRun;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                  'Ask AI to do something for the team. Nothing runs until you press Run.',
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
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: workTimeline.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final request = workTimeline[index];
              return _WorkTimelineCard(
                key: ValueKey(request.id),
                request: request,
                currentUserId: currentUserId,
                currentUserName: currentUserName,
                workflowCatalog: workflowCatalog,
                onShowRunDetails: onShowRunDetails,
                onRetryStep: onRetryStep,
                onCancelRun: onCancelRun,
              );
            },
          ),
        const SizedBox(height: 16),
        _buildComposerInput(context, isDark, colors),
      ],
    );
  }

  Widget _buildComposerInput(
    BuildContext context,
    bool isDark,
    ColorScheme colors,
  ) {
    final borderColor =
        isDark ? const Color(0xff2d2b42) : const Color(0xffe5e3f0);

    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MarkdownComposer(
            controller: requestController,
            minLines: 2,
            maxLines: 6,
            enabled: canExecute && !submitting,
            labelText: 'What should Conclave do?',
            hintText:
                'Example: Investigate the login failure and propose a fix.',
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
          const SizedBox(height: 12),
          if (loadingWorkflows)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: LinearProgressIndicator(),
            )
          else if (workflowCatalogError != null)
            Text(workflowCatalogError!, style: TextStyle(color: colors.error))
          else ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    itemHeight: null,
                    initialValue: workflow.isEmpty ? null : workflow,
                    decoration: const InputDecoration(
                      labelText: 'Workflow',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    selectedItemBuilder: (context) => workflowCatalog
                        .map((definition) => Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                definition.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ))
                        .toList(),
                    items: workflowCatalog
                        .map((definition) => DropdownMenuItem(
                              value: definition.reference,
                              child: _workflowOption(context, definition),
                            ))
                        .toList(),
                    onChanged: canExecute
                        ? (value) {
                            if (value != null) onWorkflowChanged(value);
                          }
                        : null,
                  ),
                ),
                if (onOpenSettings != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Work settings',
                    icon: const Icon(Icons.tune_rounded, size: 20),
                    onPressed: onOpenSettings,
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: canExecute && !submitting ? onAddFiles : null,
                icon: const Icon(Icons.attach_file, size: 16),
                label: const Text('Add files'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: canExecute && !submitting ? onAddReference : null,
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Add link'),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh Work history',
                onPressed: () => onRefresh(),
                icon: const Icon(Icons.refresh, size: 18),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: canExecute &&
                        !submitting &&
                        !loadingWorkflows &&
                        workflowCatalogError == null
                    ? () => onRun()
                    : null,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run'),
              ),
            ],
          ),
          if (!canExecute)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Viewer access can read the workstream but cannot run Work.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (submitting) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            const Text(
              'Checking Engine, Profile, and Provider CLI before starting Work…',
              style: TextStyle(fontSize: 12),
            ),
          ],
          if (submitError != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: SelectableText(
                  submitError!,
                  style: TextStyle(color: colors.error, fontSize: 12.5),
                ),
              ),
              IconButton(
                tooltip: 'Copy Run error',
                icon: const Icon(Icons.copy_outlined, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: submitError!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Run error copied')),
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
    required this.currentUserId,
    required this.currentUserName,
    required this.workflowCatalog,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final AxWorkRequest request;
  final String? currentUserId;
  final String? currentUserName;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final ValueChanged<String>? onShowRunDetails;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;

  String get _workflowName =>
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
    final borderColor =
        isDark ? const Color(0xff2d2b42) : const Color(0xffe2e0ed);

    final timestamp = DateTime.tryParse(request.createdAt)?.toLocal();
    final timeLabel = timestamp == null
        ? ''
        : '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
            '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    final elapsed = _totalElapsed();
    final requesterInitials = request.requestedByName.isNotEmpty
        ? request.requestedByName
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';
    final normalizedRequesterName =
        request.requestedByName.trim().toLowerCase();
    final normalizedCurrentName = currentUserName?.trim().toLowerCase();
    final isOwnRequest = (currentUserId != null &&
            currentUserId!.isNotEmpty &&
            request.requestedByUserId == currentUserId) ||
        (normalizedCurrentName != null &&
            normalizedCurrentName.isNotEmpty &&
            normalizedRequesterName == normalizedCurrentName);
    final showRequesterIdentity =
        !isOwnRequest && request.requestedByUserId?.trim().isNotEmpty == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // User prompt bubble
        Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: borderColor, width: 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showRequesterIdentity) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 11,
                          backgroundColor: isDark
                              ? const Color(0xff3f3b61)
                              : const Color(0xffd8d2ff),
                          child: Text(
                            requesterInitials,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? Colors.white70
                                  : const Color(0xff4238a0),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          request.requestedByName,
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
                  ConclaveMarkdownBody(data: request.prompt),
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
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // AI Execution & response bubble
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: borderColor, width: 1),
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: isDark
                            ? const Color(0xff2a2940)
                            : const Color(0xffece9f8),
                        child: const Icon(
                          Icons.auto_awesome,
                          size: 12,
                          color: Color(0xff7c3aed),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Conclave',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '· $_workflowName${elapsed.isEmpty ? '' : ' · $elapsed'}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: metaColor),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Builder(builder: (context) {
                    final failedStep = request.steps
                        .where((step) => step.status == 'failed')
                        .firstOrNull;
                    final response =
                        request.finalText?.trim().isNotEmpty == true
                            ? request.finalText!
                            : request.steps
                                .map((step) => step.resultText)
                                .whereType<String>()
                                .where((text) => text.trim().isNotEmpty)
                                .firstOrNull;
                    final error = request.error?.trim().isNotEmpty == true
                        ? request.error!
                        : failedStep?.errorMessage;
                    final message = error?.isNotEmpty == true
                        ? error!
                        : response?.isNotEmpty == true
                            ? response!
                            : request.status == 'cancelled'
                                ? 'Run cancelled.'
                                : 'Preparing Worker assignment…';
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
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 1.45,
                              color: colors.error,
                            ),
                          )
                        else
                          ConclaveMarkdownBody(data: message),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (response?.isNotEmpty == true ||
                                error?.isNotEmpty == true)
                              compactAction(
                                tooltip:
                                    isError ? 'Copy error' : 'Copy Markdown',
                                icon: Icons.copy_outlined,
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(
                                    text: isError ? error! : response!,
                                  ));
                                },
                              ),
                            if (onShowRunDetails != null)
                              compactAction(
                                tooltip: 'View run details',
                                icon: Icons.info_outline,
                                onPressed: () => onShowRunDetails!(request.id),
                              ),
                            if (request.status == 'failed' &&
                                failedStep != null &&
                                onRetryStep != null)
                              compactAction(
                                tooltip: 'Retry failed Step',
                                icon: Icons.refresh,
                                onPressed: () =>
                                    onRetryStep!(request.id, failedStep),
                              ),
                            if ((request.status == 'queued' ||
                                    request.status == 'running') &&
                                onCancelRun != null)
                              compactAction(
                                tooltip: 'Cancel run',
                                icon: Icons.cancel_outlined,
                                onPressed: () => onCancelRun!(request.id),
                              ),
                            const Spacer(),
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

  String _stepName(String kind) => switch (kind) {
        'research' => 'Research',
        'plan' => 'Plan',
        'implement' => 'Implement',
        'test' => 'Test',
        'verify' => 'Verify',
        _ => kind,
      };

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
    final workflow = details.workflowName ?? details.workflowId ?? 'Workflow';
    final version = details.workflowVersion;
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
                  child: Text('Run details',
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
                  '$workflow${version == null ? '' : ' · v$version'} · ${details.status}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (details.requestedByName?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  Text('Requested by ${details.requestedByName}'),
                ],
                const SizedBox(height: 16),
                Text('Original request',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                ConclaveMarkdownBody(
                    data: details.originalRequest?.isNotEmpty == true
                        ? details.originalRequest!
                        : 'No request text was recorded.'),
                const SizedBox(height: 20),
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
                                child: Text(_stepName(step.kind),
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
                              _workerName(step),
                              if (step.engineVersion != null)
                                'Engine ${step.engineVersion}',
                              if (step.providerToolName != null &&
                                  step.providerToolVersion != null)
                                '${step.providerToolName} ${step.providerToolVersion}',
                              if (step.providerToolName != null &&
                                  step.providerToolVersion == null)
                                step.providerToolName!,
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
                              step.errorMessage ??
                                  'This Step did not produce a result.',
                              style: TextStyle(color: colors.error),
                            ),
                            if (details.status == 'failed') ...[
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () => onRetryStep(step),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry step'),
                              ),
                            ],
                          ],
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: EdgeInsets.zero,
                            title: const Text('Advanced technical details'),
                            children: [
                              if (step.assignmentId != null)
                                _detailValue(
                                    'Assignment ID', step.assignmentId!),
                              if (step.engineVersion != null)
                                _detailValue(
                                    'Engine version', step.engineVersion!),
                              if (step.profileDefinitionId != null)
                                _detailValue(
                                  'Tool Profile',
                                  '${step.profileDefinitionId}'
                                      '${step.profileReleaseVersion == null ? '' : '@${step.profileReleaseVersion}'}',
                                ),
                              if (step.providerToolVersion != null)
                                _detailValue(
                                    '${step.providerToolName ?? 'Provider tool'} version',
                                    step.providerToolVersion!),
                              if (step.model != null)
                                _detailValue('Model', step.model!),
                              if (step.sessionPolicy != null)
                                _detailValue(
                                  'Session mode',
                                  step.sessionPolicy == 'durable_session'
                                      ? 'Durable session'
                                      : 'Stateless',
                                ),
                              if (step.retrySessionStrategy != null)
                                _detailValue(
                                  'Last retry session',
                                  step.retrySessionStrategy == 'fresh'
                                      ? 'Started fresh'
                                      : 'Resumed previous session',
                                ),
                              if (step.errorCode != null)
                                _detailValue(
                                    'Stable error code', step.errorCode!),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (details.errorCode != null &&
                    details.steps.every((step) => step.errorCode == null))
                  SelectableText('Run error code: ${details.errorCode}'),
                if (details.status == 'failed' ||
                    details.status == 'queued' ||
                    details.status == 'running') ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onCancelRun,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel run'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailValue(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 180, child: Text(label)),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
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
    final borderColor =
        isDark ? const Color(0xff2d2b42) : const Color(0xffe2e0ed);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor,
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                      radius: 11,
                      backgroundColor: isDark
                          ? const Color(0xff3f3b61)
                          : const Color(0xffd8d2ff),
                      child: Text(
                        initials,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.white70 : const Color(0xff4238a0),
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
                ConclaveMarkdownBody(data: widget.item.text),
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
                    const SizedBox(width: 6),
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
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

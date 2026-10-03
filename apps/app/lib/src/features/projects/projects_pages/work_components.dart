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
    required this.workflow,
    required this.workflowCatalog,
    required this.loadingWorkflows,
    required this.workflowCatalogError,
    required this.canExecute,
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
    required this.onRun,
  });

  final TextEditingController requestController;
  final String workflow;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final bool loadingWorkflows;
  final String? workflowCatalogError;
  final bool canExecute;
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
  final Future<void> Function() onRun;

  @override
  Widget build(BuildContext context) => _ProjectPanel(
        title: 'Work',
        subtitle:
            'Ask AI to do something for the team. Nothing runs until you press Run.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: requestController,
            minLines: 3,
            maxLines: 6,
            enabled: canExecute && !submitting,
            decoration: const InputDecoration(
              labelText: 'What should Conclave do?',
              hintText:
                  'Example: Investigate the login failure and propose a fix.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: canExecute && !submitting ? onAddFiles : null,
                icon: const Icon(Icons.attach_file),
                label: const Text('Add files'),
              ),
              OutlinedButton.icon(
                onPressed: canExecute && !submitting ? onAddReference : null,
                icon: const Icon(Icons.link),
                label: const Text('Add link'),
              ),
              for (var i = 0; i < attachments.length; i++)
                InputChip(
                  avatar: Icon(attachments[i]['kind'] == 'url'
                      ? Icons.link
                      : Icons.insert_drive_file),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      (attachments[i]['name'] ?? 'Attachment').toString(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onDeleted: canExecute && !submitting
                      ? () => onRemoveAttachment(i)
                      : null,
                ),
            ],
          ),
          if (attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Up to 10 attachments. Files total 1 MB; links are passed as references.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          if (loadingWorkflows)
            const LinearProgressIndicator()
          else if (workflowCatalogError != null)
            Text(workflowCatalogError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))
          else ...[
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: workflow,
              decoration: const InputDecoration(labelText: 'Workflow'),
              selectedItemBuilder: (context) => workflowCatalog
                  .map((definition) => Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          definition.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
            const SizedBox(height: 4),
            Text(
              workflowCatalog
                      .where((definition) => definition.reference == workflow)
                      .map((definition) =>
                          '${definition.description}\n${definition.steps.map((step) => step.kind).join(' → ')}')
                      .firstOrNull ??
                  '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: canExecute &&
                    !submitting &&
                    !loadingWorkflows &&
                    workflowCatalogError == null
                ? () => onRun()
                : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run'),
          ),
          if (!canExecute)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'Viewer access can read the workstream but cannot run Work.'),
            ),
          if (submitting) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            const Text(
              'Checking Engine, Profile, and Provider CLI before starting Work…',
            ),
          ],
          if (submitError != null) ...[
            const SizedBox(height: 10),
            Text(submitError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: Text('Work history',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(
                tooltip: 'Refresh Work history',
                onPressed: () => onRefresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (loadingTimeline && workTimeline.isEmpty)
            const LinearProgressIndicator()
          else if (timelineError != null && workTimeline.isEmpty)
            Text('Could not load Work history: $timelineError',
                style: TextStyle(color: Theme.of(context).colorScheme.error))
          else if (workTimeline.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Submitted Work requests will appear here.'),
            )
          else ...[
            const SizedBox(height: 20),
            ...workTimeline.map((request) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _WorkTimelineCard(
                    request: request,
                    workflowCatalog: workflowCatalog,
                    onShowRunDetails: onShowRunDetails,
                    onRetryStep: onRetryStep,
                    onCancelRun: onCancelRun,
                  ),
                )),
          ],
        ]),
      );
}

class _WorkTimelineCard extends StatelessWidget {
  const _WorkTimelineCard({
    required this.request,
    required this.workflowCatalog,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final AxWorkRequest request;
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

  String _stepName(String kind) => switch (kind) {
        'implement' => 'Implement',
        'research' => 'Research',
        'plan' => 'Plan',
        'test' => 'Test',
        'verify' => 'Verify',
        _ => kind,
      };

  String _elapsed(int? milliseconds) {
    if (milliseconds == null) return '';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  IconData _statusIcon(String status) => switch (status) {
        'completed' => Icons.check_circle,
        'running' => Icons.circle,
        'failed' => Icons.error,
        'cancelled' => Icons.cancel,
        _ => Icons.circle_outlined,
      };

  String _stepStatusLabel(String status) => switch (status) {
        'completed' => 'done',
        'running' => 'running',
        'failed' => 'failed',
        'cancelled' => 'cancelled',
        _ => 'waiting',
      };

  String _workerName(AxWorkRequestStep step) =>
      step.workerDisplayName ??
      (step.workerId == null ? 'Worker pending' : 'Selected Worker');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final timestamp = DateTime.tryParse(request.createdAt)?.toLocal();
    final timeLabel = timestamp == null
        ? ''
        : '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
            '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    final cancelledSteps =
        request.steps.where((step) => step.status == 'cancelled').toList();
    final overall = request.status == 'cancelled'
        ? 'Cancelled${cancelledSteps.isEmpty ? '' : ' during ${_stepName(cancelledSteps.first.kind)}'}'
        : request.status[0].toUpperCase() + request.status.substring(1);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(request.requestedByName,
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              Text(timeLabel, style: Theme.of(context).textTheme.bodySmall),
            ]),
            const SizedBox(height: 8),
            SelectableText(request.prompt),
            const SizedBox(height: 14),
            Text('$_workflowName · $overall',
                style: Theme.of(context).textTheme.titleSmall),
            if (request.steps.isEmpty &&
                (request.status == 'queued' ||
                    request.status == 'running')) ...[
              const SizedBox(height: 8),
              const Text('Preparing Worker assignment…'),
            ],
            if (request.steps.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...request.steps.map((step) {
                final worker = _workerName(step);
                final details = [
                  worker,
                  if (step.engineVersion != null)
                    'Engine ${step.engineVersion}',
                  if (step.providerToolVersion != null)
                    step.providerToolVersion!,
                  if (_elapsed(step.elapsedMs).isNotEmpty)
                    _elapsed(step.elapsedMs),
                ].join(' · ');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(_statusIcon(step.status),
                            size: 17,
                            color: step.status == 'failed'
                                ? colors.error
                                : step.status == 'completed'
                                    ? colors.primary
                                    : colors.secondary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_stepName(step.kind))),
                        Text(_stepStatusLabel(step.status)),
                      ]),
                      if (step.status == 'running' ||
                          step.status == 'completed' ||
                          step.status == 'failed')
                        Padding(
                          padding: const EdgeInsets.only(left: 25, top: 2),
                          child: Text(details,
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      if (step.status == 'failed') ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 25, top: 6),
                          child: Text(
                            step.errorMessage ??
                                'This Step could not be completed.',
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                        if (request.status == 'failed' && onRetryStep != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 16),
                            child: TextButton.icon(
                              onPressed: () => onRetryStep!(request.id, step),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry step'),
                            ),
                          ),
                      ],
                    ],
                  ),
                );
              }),
            ],
            if (request.testSummary != null) ...[
              const SizedBox(height: 8),
              Text('Tests · ${request.testSummary}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if (request.finalText != null && request.finalText!.isNotEmpty) ...[
              const Divider(height: 24),
              Text('Conclave · $overall · $_workflowName',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              SelectableText(request.finalText!),
            ] else if (request.status == 'failed' && request.error != null) ...[
              const Divider(height: 24),
              Text('Conclave · Failed',
                  style: TextStyle(
                      color: colors.error, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SelectableText(request.error!),
            ],
            if ((request.status == 'queued' ||
                    request.status == 'running' ||
                    request.status == 'failed') &&
                onCancelRun != null) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () => onCancelRun!(request.id),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel run'),
              ),
            ],
            if (onShowRunDetails != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => onShowRunDetails!(request.id),
                icon: const Icon(Icons.subject),
                label: const Text('Run details'),
              ),
            ],
          ],
        ),
      ),
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
                SelectableText(details.originalRequest?.isNotEmpty == true
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
                            SelectableText(step.resultText!),
                          ] else if (step.status == 'failed') ...[
                            const Divider(height: 24),
                            Text(
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
                  Text('Run error code: ${details.errorCode}'),
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
    final text = _editController.text.trim();
    if (text.isNotEmpty) {
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

    final textColor = isDark ? Colors.white : const Color(0xff1f1d2b);
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
                TextField(
                  controller: _editController,
                  minLines: 1,
                  maxLines: 6,
                  autofocus: true,
                  style: TextStyle(fontSize: 13.5, color: textColor),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                  ),
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
                SelectableText(
                  widget.item.text,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: textColor,
                  ),
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
                    Tooltip(
                      message: 'Copy message',
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

class _DiscussionInputBox extends StatelessWidget {
  const _DiscussionInputBox({
    required this.controller,
    required this.onSend,
  });

  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            return KeyEventResult.ignored;
          } else {
            onSend();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 8,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: isDark ? const Color(0xff2d2b42) : const Color(0xffe5e3f0),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: isDark ? const Color(0xff2d2b42) : const Color(0xffe5e3f0),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
              color: Color(0xff7c3aed),
              width: 1.5,
            ),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          suffixIcon: IconButton(
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded, size: 18),
            tooltip: 'Send message',
            color: const Color(0xff7c3aed),
          ),
        ),
      ),
    );
  }
}
